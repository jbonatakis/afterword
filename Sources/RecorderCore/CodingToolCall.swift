import Foundation
import Lookback

/// A bounded excerpt of a recorded invocation. Never execute or expand the supplied command or path.
public struct CodingToolCall: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case read, edit, write, search, command, test, script, other
    }

    public let name: String
    public private(set) var action: Action = .other
    public private(set) var subject: String?
    public private(set) var additionalPaths: [String]?
    public private(set) var preview: String?
    public private(set) var result: String?
    public private(set) var diagnostic: String?
    public private(set) var testOutcome: String?
    public internal(set) var events: [CodingToolCall]?

    public init(name: String) { self.name = name }

    public var hasDetails: Bool {
        subject != nil || preview != nil || result != nil || diagnostic != nil || testOutcome != nil || events?.isEmpty == false
    }

    public func nameLabel(count: Int) -> String { count == 1 ? name : "\(name) ×\(count)" }

    public func groupLabel(count: Int) -> String {
        let noun: String
        switch action {
        case .read: noun = "read"
        case .edit: noun = "edit"
        case .write: noun = "write"
        case .search: noun = count == 1 ? "search" : "searches"
        case .command: noun = "command"
        case .test: noun = "test run"
        case .script: noun = "script"
        case .other: return nameLabel(count: count)
        }
        return "\(count) \(noun)" + (count > 1 && action != .search ? "s" : "")
    }

    var searchText: String {
        [name, subject, additionalPaths?.joined(separator: "\n"), preview, result, diagnostic, testOutcome].compactMap { $0 }.joined(separator: "\n")
    }

    // Truncation is explicit in the saved value, in the disclosure, and in search.
    private static func excerpt(_ text: String?, characters: Int = 1200, lines: Int = 12, preserveWhitespace: Bool = false) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let prefix = text.prefix(characters + 1)
        let rows = prefix.prefix(characters).split(separator: "\n", maxSplits: lines, omittingEmptySubsequences: false)
        let joined = rows.prefix(lines).joined(separator: "\n")
        let value = preserveWhitespace ? joined : joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value + (prefix.count > characters || rows.count > lines ? "…" : "")
    }

    private static func json(_ data: Data?) -> Any? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
    }

    init(name: String, input: Data?, project: String, provider: String) {
        self.init(name: name)
        let tool = name.hasPrefix("functions.") ? String(name.dropFirst("functions.".count)) : name
        let value = Self.json(input)
        let fields = value as? [String: Any] ?? [:]
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { fields[$0] as? String }.first
        }
        func path(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let prefix = project.hasSuffix("/") ? project : project + "/"
            return Self.excerpt(raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw, characters: 400, lines: 1)
        }

        switch tool {
        case "Read", "read", "read_file", "view_file":
            action = .read
            subject = path(string("file_path", "path", "Path", "AbsolutePath"))
        case "Edit", "edit", "MultiEdit":
            action = .edit
            subject = path(string("file_path", "path"))
            let edits = fields["edits"] as? [[String: Any]] ?? [fields]
            let parts = edits.prefix(3).compactMap { edit -> String? in
                let before = edit["old_string"] as? String ?? edit["oldText"] as? String
                let after = edit["new_string"] as? String ?? edit["newText"] as? String
                guard before != nil || after != nil else { return nil }
                return [Self.diffLines(before, sign: "−"), Self.diffLines(after, sign: "+")].compactMap { $0 }.joined(separator: "\n")
            }
            preview = Self.excerpt(parts.joined(separator: "\n") + (edits.count > 3 ? "\n…" : ""), preserveWhitespace: true)
        case "Write", "write", "write_file", "write_to_file":
            action = .write
            subject = path(string("file_path", "path", "Path", "TargetFile"))
            preview = Self.diffLines(string("content", "Content", "CodeContent"), sign: "+")
        case "apply_patch":
            action = .edit
            if let patch = value as? String ?? string("patch") {
                var paths: [String] = [], changes: [String] = []
                var seen = Set<String>()
                patch.enumerateLines { line, _ in
                    if let prefix = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "].first(where: line.hasPrefix) {
                        let file = path(String(line.dropFirst(prefix.count))) ?? ""
                        if seen.insert(file).inserted { paths.append(file) }
                        if changes.count <= 12 { changes.append(file) }
                    } else if changes.count <= 12, line.hasPrefix("+") || line.hasPrefix("-") {
                        if let change = Self.excerpt(line, characters: 240, lines: 1, preserveWhitespace: true) { changes.append(change) }
                    }
                }
                subject = paths.first
                if paths.count > 1 { additionalPaths = Array(paths.dropFirst()) }
                preview = Self.excerpt(changes.joined(separator: "\n"))
            } else if let files = value as? [String: [String: Any]] {
                // Completed FileChange items carry a map, with no ordering between files.
                let names = files.keys.sorted()
                subject = path(names.first)
                if names.count > 1 { additionalPaths = names.dropFirst().compactMap(path) }
                let changes = names.prefix(8).flatMap { name -> [String] in
                    let diff = files[name]?["unified_diff"] as? String ?? files[name]?["content"] as? String
                    return [path(name), Self.excerpt(diff, preserveWhitespace: true)].compactMap { $0 }
                }
                preview = Self.excerpt(changes.joined(separator: "\n") + (names.count > 8 ? "\n…" : ""))
            }
        case "Grep", "grep", "Glob", "find", "web_search_call", "WebSearch":
            action = .search
            let queries = (fields["queries"] as? [String])?.prefix(4).joined(separator: " · ")
            subject = Self.excerpt(string("pattern", "query", "glob") ?? queries, characters: 400, lines: 1)
            preview = path(string("path"))
        case "exec_command", "shell_command", "local_shell_call", "Bash", "bash", "run_command":
            let command = string("cmd", "command", "CommandLine") ?? (value as? String)
            let argv = fields["command"] as? [String] ?? value as? [String]
            let shellText: String?
            if let argv, argv.count == 3, ["-c", "-lc"].contains(argv[1]) { shellText = argv[2] }
            else { shellText = command ?? argv?.joined(separator: " ") }
            subject = Self.excerpt(shellText, characters: 500, lines: 3)
            action = Self.commandAction(shellText ?? "")
            if let parts = fields["parsed_cmd"] as? [[String: Any]], parts.count == 1, let part = parts.first {
                switch part["type"] as? String {
                case "read":
                    action = .read
                    preview = subject
                    subject = path(part["path"] as? String ?? part["name"] as? String)
                case "search":
                    action = .search
                    preview = subject
                    subject = Self.excerpt(part["query"] as? String) ?? subject
                default: break
                }
            }
        case "exec" where provider == CodingProvider.codex.rawValue:
            action = .script
            if var script = value as? String ?? string("code") {
                if script.hasPrefix("// @exec:"), let newline = script.firstIndex(of: "\n") { script = String(script[script.index(after: newline)...]) }
                preview = Self.excerpt(script, preserveWhitespace: true)
            }
        case "Agent", "Monitor":
            subject = Self.excerpt(string("description"))
            preview = Self.excerpt(tool == "Monitor" ? string("command") : string("subagent_type"))
        case "write_stdin" where provider == CodingProvider.codex.rawValue:
            if let session = Self.scalar(fields["session_id"]), let chars = fields["chars"] as? String {
                subject = chars.isEmpty ? "Poll terminal session \(session)" : "Send input to terminal session \(session)"
            }
        case "update_plan" where provider == CodingProvider.codex.rawValue:
            subject = Self.excerpt(string("explanation"), characters: 240, lines: 2)
            if let steps = fields["plan"] as? [[String: Any]] {
                preview = Self.excerpt(steps.prefix(8).compactMap { item in
                    guard let step = Self.excerpt(item["step"] as? String, characters: 160, lines: 1) else { return nil }
                    return [Self.excerpt(item["status"] as? String, characters: 25, lines: 1), step].compactMap { $0 }.joined(separator: " · ")
                }.joined(separator: "\n") + (steps.count > 8 ? "\n…" : ""))
            }
        case "request_user_input", "request_user_input_async":
            if let questions = fields["questions"] as? [[String: Any]] {
                preview = Self.excerpt(questions.prefix(3).compactMap { Self.excerpt(($0["question"] ?? $0["title"]) as? String, characters: 300, lines: 2) }.joined(separator: "\n"))
            }
        case "call_mcp_tool" where provider == CodingProvider.antigravity.rawValue:
            subject = Self.excerpt([string("ServerName"), string("ToolName")].compactMap { $0 }.joined(separator: " / "), characters: 200, lines: 1)
            if let arguments = fields["Arguments"] as? [String: Any] { preview = Self.parameters(arguments) }
        default: break
        }
        if subject == nil && preview == nil { preview = Self.parameters(fields) }
    }

    private static func scalar(_ value: Any?) -> String? {
        if let string = value as? String { return excerpt(string, characters: 200, lines: 2) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    /// Identify a call using selected scalar fields. Bodies, environment variables, stdin and
    /// arbitrary nested payloads stay out of the archive. Structured operations retain their counts.
    private static func parameters(_ fields: [String: Any]) -> String? {
        let keys = ["subject", "title", "label", "query", "pattern", "file_path", "path", "DirectoryPath",
                    "Action", "Target", "toolSummary", "action", "status", "skill", "name", "format",
                    "taskId", "task_id", "cell_id", "session_id", "call_id", "message_id", "diagramId", "exportId",
                    "source", "scope", "from", "to", "duration_ms", "yield_time_ms", "offset", "limit"]
        var lines: [String] = []
        for key in keys {
            if let value = scalar(fields[key]) { lines.append("\(key) = \(value)") }
            if lines.count == 5 { break }
        }
        for key in ["operations", "actions", "writes"] {
            if let list = fields[key] as? [Any] { lines.append("\(key) ×\(list.count)") }
        }
        return excerpt(lines.joined(separator: "\n"), characters: 600, lines: 6)
    }

    private static func diffLines(_ text: String?, sign: String) -> String? {
        excerpt(text, characters: 540, lines: 5, preserveWhitespace: true)?.components(separatedBy: "\n").map { sign + " " + $0 }.joined(separator: "\n")
    }

    private static func commandAction(_ command: String) -> Action {
        // A pipeline, conditional or substitution has its own exit semantics.
        guard command.rangeOfCharacter(from: CharacterSet(charactersIn: "|;&\n`$<>()\\")) == nil else { return .command }
        let words = command.split(whereSeparator: \.isWhitespace)
        guard let executable = words.first else { return .command }
        if ["rg", "grep"].contains(executable) { return .search }
        if ["pytest", "cargo-nextest"].contains(executable) { return .test }
        if ["swift", "cargo", "go", "npm", "yarn", "pnpm"].contains(executable), words.dropFirst().first == "test" { return .test }
        if ["python", "python3"].contains(executable), words.dropFirst().starts(with: ["-m", "pytest"]) { return .test }
        return .command
    }

    init(event: SessionToolEvent, project: String, provider: String) {
        self.init(name: event.name, input: event.inputJSON, project: project, provider: provider)
        receive(output: event.outputJSON, isError: event.isError, reportedExit: event.exitCode)
    }

    mutating func receive(output: Data?, isError: Bool, reportedExit: Int? = nil) {
        guard action == .command || action == .test || action == .search else {
            result = reportedExit.map { "Exit \($0)" } ?? (isError ? "Tool reported an error" : nil)
            return
        }
        let value = Self.json(output)
        let fields = value as? [String: Any] ?? [:]
        let blocks = value as? [[String: Any]]
        let text = value as? String ?? fields["output"] as? String ?? blocks?.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String) else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        let metadata = fields["metadata"] as? [String: Any]
        var exitCode = reportedExit ?? fields["exit_code"] as? Int ?? metadata?["exit_code"] as? Int
        if exitCode == nil, let text, text.hasPrefix("Chunk ID:") || text.hasPrefix("Wall time:") {
            // Codex's envelope ends where command output starts. Output can itself contain these words.
            for line in text.prefix(600).split(separator: "\n").prefix(5) {
                if line.hasPrefix("Output:") || line.hasPrefix("Final output:") { break }
                if line.hasPrefix("Process exited with code ") { exitCode = Int(line.dropFirst("Process exited with code ".count)); break }
            }
        }
        var facts: [String] = []
        if let exitCode { facts.append("Exit \(exitCode)") }
        if isError && (exitCode == nil || exitCode == 0) { facts.append("Tool reported an error") }
        if action == .search {
            let summary = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let count = Self.searchCount(fields) { facts.append(count) }
            else if ["Grep", "Glob", "grep", "find"].contains(name), summary == "No matches found" || summary == "No files found" {
                facts.append(summary == "No files found" ? "0 files" : "0 matches")
            }
        }
        result = facts.isEmpty ? nil : facts.joined(separator: " · ")
        guard action == .test, let text else { return }
        readTestReport(text, canPass: !isError && (exitCode == nil || exitCode == 0))
    }

    private static func searchCount(_ fields: [String: Any]) -> String? {
        for (key, single, plural) in [("numMatches", "match", "matches"), ("numFiles", "file", "files"), ("numLines", "line", "lines")] {
            if let n = fields[key] as? Int, n >= 0 { return "\(n) \(n == 1 ? single : plural)" }
        }
        return nil
    }

    private mutating func readTestReport(_ output: String, canPass: Bool) {
        // Only runner-wide reports establish a test outcome. A successful shell exit alone cannot.
        let tail = String(output.suffix(24000)).replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
        let lines = tail.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var passed = false, failed = false
        for line in lines {
            if line.hasPrefix("Test Suite 'All tests' passed") || line.hasPrefix("Test Suite 'Selected tests' passed") || line.range(of: #"^✔ Test run with [1-9][0-9]* tests?.* passed"#, options: .regularExpression) != nil { passed = true }
            if line.hasPrefix("Test Suite 'All tests' failed") || line.hasPrefix("Test Suite 'Selected tests' failed") || line.hasPrefix("✘ Test run with ") { failed = true }
            if line.hasPrefix("test result: ok. "), line.range(of: #"\b[1-9][0-9]* passed\b"#, options: .regularExpression) != nil { passed = true }
            if line.hasPrefix("test result: FAILED.") { failed = true }
            if line.contains(" in "), line.range(of: #"^=*\s*\d+ (passed|failed|errors?|skipped|warnings?|xfailed|xpassed|deselected)\b.* in [\d.]+s\s*=*$"#, options: .regularExpression) != nil {
                passed = passed || line.range(of: #"\b[1-9][0-9]* passed\b"#, options: .regularExpression) != nil
                failed = failed || line.range(of: #"\b[1-9][0-9]* (failed|errors?)\b"#, options: .regularExpression) != nil
            }
            if diagnostic == nil, line.contains(": error: ") || line.hasPrefix("FAILED ") || line.hasPrefix("E   ") || line.contains(" panicked at ") {
                diagnostic = Self.excerpt(line, characters: 420, lines: 1)
            }
        }
        if failed { testOutcome = "failed" }
        else if passed && canPass { testOutcome = "passed" }
    }
}
