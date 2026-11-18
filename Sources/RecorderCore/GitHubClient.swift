import Foundation

public enum GitHubServiceError: LocalizedError {
    case credentials, denied, expired
    case retry(Date)
    case response(String)
    public var errorDescription: String? {
        switch self {
        case .credentials: return "GitHub authorization expired. Reconnect your account."
        case .denied: return "GitHub authorization was declined."
        case .expired: return "The GitHub device code expired. Start the connection again."
        case .retry(let date): return "GitHub asked Afterword to wait until \(date.formatted())."
        case .response(let text): return text
        }
    }
}

public struct GitHubDeviceCode: Decodable, Sendable {
    public let device_code, user_code: String
    public let expires_in, interval: Int
}
public struct GitHubTokens: Codable, Sendable {
    public let access, refresh: String
    public let expires: Date
}

public struct GitHubClient: Sendable {
    typealias Object = [String: Any]
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 45
        self.session = session ?? URLSession(configuration: config)
    }
    private func request(_ url: URL, token: String? = nil, body: Data? = nil, acceptsOAuthErrors: Bool = false) async throws -> Object
    {
        let (json, _) = try await response(url, token: token, body: body, acceptsOAuthErrors: acceptsOAuthErrors)
        guard let object = json as? Object else { throw Self.invalid }
        return object
    }
    private func response(_ url: URL, token: String?, body: Data? = nil, acceptsOAuthErrors: Bool = false) async throws -> (
        Any, HTTPURLResponse
    ) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("Afterword", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GitHubServiceError.response("Invalid GitHub response.") }
        let payload = try? JSONSerialization.jsonObject(with: data)
        let json = payload as? Object
        let message = json?["message"] as? String ?? ""
        let limited = (json?["errors"] as? [Object])?.contains { $0["type"] as? String == "RATE_LIMITED" } == true
        if limited || http.statusCode == 429
            || (http.statusCode == 403
                && (http.value(forHTTPHeaderField: "Retry-After") != nil
                    || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                    || message.localizedCaseInsensitiveContains("rate limit")))
        {
            let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Date().addingTimeInterval($0) }
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            throw GitHubServiceError.retry(delay ?? reset ?? Date().addingTimeInterval(limited ? 900 : 60))
        }
        // GitHub reports OAuth protocol errors on both successful and 4xx HTTP responses.
        if acceptsOAuthErrors, (400..<500).contains(http.statusCode), let json, json["error"] is String { return (json, http) }
        if http.statusCode == 401 { throw GitHubServiceError.credentials }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubServiceError.response("GitHub returned HTTP \(http.statusCode). Check repository access and retry.")
        }
        guard let payload else { throw Self.invalid }
        return (payload, http)
    }
    private func oauth(_ path: String, _ values: [String: String]) async throws -> Object {
        let response = try await request(
            URL(string: "https://github.com/login/" + path)!, body: JSONEncoder().encode(values), acceptsOAuthErrors: true)
        switch response["error"] as? String {
        case nil, "authorization_pending", "slow_down": return response
        case "device_flow_disabled":
            throw GitHubServiceError.response(
                "In your GitHub App settings, under “Identifying and authorizing users”, select “Enable Device Flow” and save. Then click Connect GitHub again."
            )
        case "incorrect_client_credentials", "invalid_client":
            if values["grant_type"] == "refresh_token" { throw GitHubServiceError.credentials }
            throw GitHubServiceError.response(
                "Copy the Client ID from your GitHub App’s General settings into Afterword and try again.")
        case "bad_refresh_token", "invalid_grant": throw GitHubServiceError.credentials
        case "expired_token":
            if values["grant_type"] == "refresh_token" { throw GitHubServiceError.credentials }
            throw GitHubServiceError.expired
        case "access_denied": throw GitHubServiceError.denied
        default:
            throw GitHubServiceError.response("GitHub rejected the authorization request. Check your GitHub App settings and retry.")
        }
    }
    public func deviceCode(clientID: String) async throws -> GitHubDeviceCode {
        let json = try await oauth("device/code", ["client_id": clientID, "scope": "offline_access"])
        guard let code = try? JSONDecoder().decode(GitHubDeviceCode.self, from: AgentJSON.data(json)), code.interval > 0,
            code.expires_in > 0
        else {
            throw GitHubServiceError.response(
                "GitHub could not start device authorization. Check the client ID and enable device flow on the GitHub App.")
        }
        return code
    }
    private func tokens(_ response: Object) throws -> GitHubTokens {
        guard let access = response["access_token"] as? String, let refresh = response["refresh_token"] as? String,
            let lifetime = response["expires_in"] as? Int, !access.isEmpty, !refresh.isEmpty
        else {
            throw GitHubServiceError.response(
                "GitHub did not return rotating credentials. Enable expiring user tokens on the GitHub App.")
        }
        return .init(access: access, refresh: refresh, expires: Date().addingTimeInterval(Double(lifetime)))
    }
    public func authorize(clientID: String, code: GitHubDeviceCode) async throws -> GitHubTokens {
        let end = Date().addingTimeInterval(Double(code.expires_in))
        var interval = code.interval
        while Date() < end {
            try await Task.sleep(for: .seconds(interval))
            let json = try await oauth(
                "oauth/access_token",
                ["client_id": clientID, "device_code": code.device_code, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            switch json["error"] as? String {
            case nil: return try tokens(json)
            case "authorization_pending": continue
            case "slow_down": interval = max(interval + 5, json["interval"] as? Int ?? 0)
            default: throw GitHubServiceError.response("GitHub could not authorize this device.")
            }
        }
        throw GitHubServiceError.expired
    }
    public func renew(clientID: String, refresh: String) async throws -> GitHubTokens {
        let json = try await oauth(
            "oauth/access_token", ["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        return try tokens(json)
    }
    private func rest(_ path: String, token: String) async throws -> Object {
        try await request(URL(string: "https://api.github.com/" + path)!, token: token)
    }
    public func viewer(token: String) async throws -> GitHubIdentity {
        let user = try await rest("user", token: token)
        guard let id = user["node_id"] as? String, let login = user["login"] as? String else { throw Self.invalid }
        return .init(id: id, login: login)
    }
    private func pages(_ path: String, field: String, token: String) async throws -> [Object] {
        var page = 1
        var result: [Object] = []
        var ids = Set<String>()
        var expected: Int?
        while true {
            let json = try await rest(path + "?per_page=100&page=\(page)", token: token)
            guard let values = json[field] as? [Object], let total = json["total_count"] as? Int else { throw Self.invalid }
            guard expected == nil || expected == total else { throw Self.invalid }
            expected = total
            for value in values {
                let key = (value["node_id"] as? String) ?? (value["id"] as? Int).map(String.init)
                guard let key, ids.insert(key).inserted else { throw Self.invalid }
            }
            result += values
            if values.count < 100 {
                guard result.count == total else {
                    throw GitHubServiceError.response("GitHub’s installation list changed during pagination. Retry.")
                }
                return result
            }
            page += 1
        }
    }
    public func repositories(token: String) async throws -> [GitHubRepository] {
        var result: [GitHubRepository] = []
        for installation in try await pages("user/installations", field: "installations", token: token) {
            guard let id = installation["id"] as? Int else { throw Self.invalid }
            if installation["suspended_at"] is String { continue }
            guard let permissions = installation["permissions"] as? [String: String] else { throw Self.invalid }
            if !["issues", "pull_requests"].allSatisfy({ ["read", "write", "admin"].contains(permissions[$0] ?? "") }) {
                continue
            }
            for repo in try await pages("user/installations/\(id)/repositories", field: "repositories", token: token) {
                guard let id = repo["node_id"] as? String, let name = repo["full_name"] as? String else { throw Self.invalid }
                result.append(.init(id: id, name: name))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    // viewer.repositories can omit private organization repositories that the token can read.
    private func personalRepositoryIDs(token: String) async throws -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        var page = 1
        while true {
            let url = URL(
                string:
                    "https://api.github.com/user/repos?visibility=all&affiliation=owner,collaborator,organization_member&sort=full_name&direction=asc&per_page=100&page=\(page)"
            )!
            let (json, http) = try await response(url, token: token)
            guard http.statusCode == 200, let rows = json as? [Object] else { throw Self.invalid }
            if http.value(forHTTPHeaderField: "X-GitHub-SSO")?.localizedCaseInsensitiveContains("partial-results") == true {
                throw GitHubServiceError.response("GitHub returned a partial list. Check organization single sign-on and refresh.")
            }
            for row in rows {
                guard let id = row["node_id"] as? String, !id.isEmpty, seen.insert(id).inserted else { throw Self.invalid }
                ids.append(id)
            }
            guard http.value(forHTTPHeaderField: "Link")?.contains(#"rel="next""#) == true else { return ids }
            guard !rows.isEmpty else { throw Self.invalid }
            page += 1
        }
    }

    static let personalRepositoryAccessQuery = """
        query PersonalRepositoryAccess($ids:[ID!]!) {
          viewer { id }
          nodes(ids:$ids) { ... on Repository { id nameWithOwner issues(first:1) { totalCount } pullRequests(first:1) { totalCount } } }
        }
        """
    public func personalRepositories(token: String, viewer: GitHubIdentity, selectedIDs: [String] = []) async throws
        -> [GitHubRepository]
    {
        var ids = try await personalRepositoryIDs(token: token)
        let listed = Set(ids)
        // Check saved repositories by their stable ID even if discovery omits them or they moved.
        ids.append(contentsOf: Set(selectedIDs).subtracting(listed).sorted())
        var result: [GitHubRepository] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let json = try await graphResponse(Self.personalRepositoryAccessQuery, ["ids": batch], token: token)
            guard let data = json["data"] as? Object, (data["viewer"] as? Object)?["id"] as? String == viewer.id,
                let nodes = data["nodes"] as? [Any], nodes.count == batch.count,
                json["errors"] == nil || json["errors"] is [Object]
            else { throw Self.invalid }
            var denied = Set<Int>()
            for error in json["errors"] as? [Object] ?? [] {
                guard let path = error["path"] as? [Any], path.count >= 2, path[0] as? String == "nodes",
                    let index = path[1] as? Int, nodes.indices.contains(index)
                else { throw Self.invalid }
                switch (error["type"] as? String, path.count) {
                case ("NOT_FOUND", 2), ("FORBIDDEN", 2):
                    guard !listed.contains(batch[index]), nodes[index] is NSNull else { throw Self.invalid }
                case ("FORBIDDEN", 3), ("FORBIDDEN", 4):
                    guard let field = path[2] as? String, ["issues", "pullRequests"].contains(field),
                        path.count == 3 || path[3] as? String == "totalCount"
                    else { throw Self.invalid }
                default: throw Self.invalid
                }
                denied.insert(index)
            }
            for (index, node) in nodes.enumerated() where !denied.contains(index) {
                if node is NSNull && !listed.contains(batch[index]) { continue }
                guard let repo = node as? Object, repo["id"] as? String == batch[index], let name = repo["nameWithOwner"] as? String,
                    (repo["issues"] as? Object)?["totalCount"] is Int, (repo["pullRequests"] as? Object)?["totalCount"] is Int
                else { throw Self.invalid }
                result.append(.init(id: batch[index], name: name))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static var invalid: GitHubServiceError { .response("GitHub returned an incomplete page. Afterword kept the previous checkpoint.") }
    private func graphResponse(_ query: String, _ variables: Object, token: String) async throws -> Object {
        try await request(
            URL(string: "https://api.github.com/graphql")!, token: token,
            body: AgentJSON.data(["query": query, "variables": variables]))
    }
    func graph(_ query: String, _ variables: Object, token: String, missingNodes: Bool = false) async throws -> Object {
        let json = try await graphResponse(query, variables, token: token)
        if let errors = json["errors"] as? [Object], !errors.isEmpty {
            if !missingNodes
                || !errors.allSatisfy({ error in
                    let path = error["path"] as? [Any]
                    return error["type"] as? String == "NOT_FOUND" && path?.count == 2 && path?.first as? String == "nodes"
                        && path?.last is Int
                })
            {
                throw GitHubServiceError.response(
                    "GitHub could not complete the requested page. Check repository permissions and retry.")
            }
        }
        guard let data = json["data"] as? Object else { throw Self.invalid }
        return data
    }
}
