import Foundation
import Darwin
import RecorderCore

let arguments = Array(CommandLine.arguments.dropFirst())
let directory: URL
if arguments.isEmpty { directory = AgentAccessStore.directory }
else if arguments.count == 2, arguments[0] == "--state-directory", arguments[1].hasPrefix("/") {
    directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
} else {
    FileHandle.standardError.write(Data("Usage: AfterwordMCP [--state-directory /absolute/path]\nLocal MCP server over stdio. Access is configured in Afterword Settings.\n".utf8))
    exit(arguments == ["--help"] ? 0 : 2)
}
signal(SIGPIPE, SIG_IGN)
setpriority(PRIO_PROCESS, 0, 10)
let server = AgentRPCServer(directory: directory)
var pending = Data(), buffer = [UInt8](repeating: 0, count: 8192)
let maximumRequest = 1_048_576
func respond(_ line: Data) {
    guard let response = server.handle(line) else { return }
    do { try FileHandle.standardOutput.write(contentsOf: response + Data([10])) }
    catch { exit(0) }
}
while true {
    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
    if count == 0 { break }
    if count < 0 { if errno == EINTR { continue }; exit(1) }
    pending.append(contentsOf: buffer.prefix(count))
    while let newline = pending.firstIndex(of: 10) {
        guard pending.distance(from: pending.startIndex, to: newline) <= maximumRequest else { exit(2) }
        let line = Data(pending.prefix(upTo: newline))
        pending.removeSubrange(...newline)
        respond(line)
    }
    guard pending.count <= maximumRequest else { exit(2) }
}
if !pending.isEmpty { respond(pending) }
