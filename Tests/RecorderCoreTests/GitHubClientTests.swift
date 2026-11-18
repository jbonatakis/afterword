import Foundation

@testable import RecorderCore

#if canImport(XCTest)
    import XCTest
#endif

private final class GitHubStub: URLProtocol {
    typealias Payload = [String: Any]
    static var respond: ((URLRequest, Payload) throws -> (Int, [String: String], Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    body.append(contentsOf: buffer.prefix(n))
                }
            }
            let object = body.isEmpty ? [:] : try JSONSerialization.jsonObject(with: body) as? Payload ?? [:]
            guard let respond = Self.respond else { throw RecorderError.message("Unexpected GitHub request") }
            let (status, headers, payload) = try respond(request, object)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GitHubClientTests: XCTestCase {
    typealias Object = [String: Any]
    private func exercise(_ body: @escaping (GitHubClient) async throws -> Void) throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStub.self]
        let api = GitHubClient(session: URLSession(configuration: config))
        let done = DispatchSemaphore(value: 0)
        var outcome: Error?
        Task.detached {
            do { try await body(api) } catch { outcome = error }
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else { throw RecorderError.message("GitHub fixture timed out") }
        GitHubStub.respond = nil
        if let outcome { throw outcome }
    }
    func testIncompleteAccessAndGraphResponsesKeepCheckpoints() throws {
        let viewer = GitHubIdentity(id: "U", login: "fixture")
        let repo = GitHubRepository(id: "R", name: "samples/synthetic")
        GitHubStub.respond = { request, body in
            if request.url?.path == "/user/installations" {
                return (200, [:], ["total_count": 2, "installations": [["id": 1], ["id": 1]]])
            }
            let vars = body["variables"] as! Object
            if vars["ids"] != nil {
                let error: Object = ["type": "FORBIDDEN", "path": ["nodes", 0]]
                return (200, [:], ["errors": [error], "data": ["nodes": [NSNull()]]])
            }
            if (vars["q"] as? String)?.contains("author:") == true {
                return (200, [:], ["data": ["search": ["issueCount": 1001, "nodes": [], "pageInfo": ["hasNextPage": false]]]])
            }
            return (200, ["Retry-After": "180"], ["errors": [["type": "RATE_LIMITED"]]])
        }
        try exercise { api in
            do {
                _ = try await api.repositories(token: "fixture")
                throw RecorderError.message("Repeated installation ID accepted")
            } catch GitHubServiceError.response {}
            do {
                _ = try await api.importPage(.nodes(ids: ["saved"], since: 0), repo: repo, viewer: viewer, token: "fixture")
                throw RecorderError.message("A partial response authorized deleting a saved contribution")
            } catch GitHubServiceError.response {}
            let qualifier = "is:pr author:@me"
            let page = try await api.importPage(
                .search(qualifier: qualifier, since: 100, until: 103, cutoff: 0, cursor: nil),
                repo: repo, viewer: viewer, token: "fixture")
            XCTAssertEqual(
                page.next,
                [
                    .search(qualifier: qualifier, since: 100, until: 101, cutoff: 0, cursor: nil),
                    .search(qualifier: qualifier, since: 102, until: 103, cutoff: 0, cursor: nil),
                ])
            let capped = try await api.importPage(
                .search(qualifier: qualifier, since: 103, until: 103, cutoff: 0, cursor: nil),
                repo: repo, viewer: viewer, token: "fixture")
            XCTAssertTrue(capped.partial)
            do {
                _ = try await api.importPage(.comments(since: 0, cursor: nil), repo: repo, viewer: viewer, token: "fixture")
                throw RecorderError.message("GraphQL rate limit ignored")
            } catch GitHubServiceError.retry(let until) { XCTAssertGreaterThan(until.timeIntervalSinceNow, 175) }
        }
    }
    private static func repositoryAccess(_ id: String) -> Object {
        ["id": id, "nameWithOwner": "team/" + id, "issues": ["totalCount": 0], "pullRequests": ["totalCount": 0]]
    }
    func testPersonalTokenFindsPrivateOrganizationRepositoriesAndChecksSavedIDs() throws {
        var pages = 0
        GitHubStub.respond = { request, body in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            if request.url?.path == "/user/repos" {
                let url = try XCTUnwrap(request.url)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertTrue(query.contains(URLQueryItem(name: "visibility", value: "all")))
                XCTAssertTrue(query.contains(URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member")))
                pages += 1
                XCTAssertTrue(query.contains(URLQueryItem(name: "page", value: String(pages))))
                if pages == 1 {
                    return (200, ["Link": #"<https://api.github.com/user/repos?page=2>; rel="next""#], [["node_id": "public"]])
                }
                return (200, [:], [["node_id": "private", "private": true], ["node_id": "denied"]])
            }
            XCTAssertEqual(request.url?.path, "/graphql")
            let vars = try XCTUnwrap(body["variables"] as? Object)
            XCTAssertEqual(vars["ids"] as? [String], ["public", "private", "denied", "moved", "revoked"])
            let nodes: [Any] = [
                Self.repositoryAccess("public"), Self.repositoryAccess("private"), NSNull(), Self.repositoryAccess("moved"), NSNull(),
            ]
            let denied: Object = ["type": "FORBIDDEN", "path": ["nodes", 2, "pullRequests"]]
            let revoked: Object = ["type": "NOT_FOUND", "path": ["nodes", 4]]
            return (200, [:], ["data": ["viewer": ["id": "U"], "nodes": nodes], "errors": [denied, revoked]])
        }
        try exercise { api in
            let repos = try await api.personalRepositories(
                token: "fixture", viewer: .init(id: "U", login: "fixture"),
                selectedIDs: ["private", "revoked", "moved"])
            XCTAssertEqual(repos.map(\.name), ["team/moved", "team/private", "team/public"])
            XCTAssertEqual(pages, 2)
        }
    }
    func testIncompletePersonalTokenDiscoveryCannotAuthorizeRemovals() throws {
        let normal: Object = ["data": ["viewer": ["id": "U"], "nodes": [Self.repositoryAccess("R")]]]
        let list = [["node_id": "R"]]
        let fixtures: [(Any, [String: String], Object)] = [
            ([["name": "missing id"]], [:], normal), (list + list, [:], normal),
            (list, ["X-GitHub-SSO": "partial-results; organizations=123"], normal),
            ([], ["Link": #"<https://api.github.com/user/repos?page=2>; rel="next""#], normal),
            (list, [:], ["data": ["viewer": ["id": "U"], "nodes": []]]),
            (list, [:], ["data": ["viewer": ["id": "U"], "nodes": [NSNull()]]]),
            (list, [:], ["data": ["viewer": ["id": "U"], "nodes": [Self.repositoryAccess("wrong-id")]]]),
            (list, [:], ["data": ["viewer": ["id": "other"], "nodes": [Self.repositoryAccess("R")]]]),
            (list, [:], normal.merging(["errors": [["type": "INTERNAL", "path": ["nodes", 0]]]]) { _, new in new }),
            (list, [:], normal.merging(["errors": [["type": "FORBIDDEN", "path": ["viewer"]]]]) { _, new in new }),
            (list, [:], normal.merging(["errors": "malformed"]) { _, new in new }),
        ]
        for (rows, headers, graph) in fixtures {
            GitHubStub.respond = { request, _ in
                if request.url?.path == "/user/repos" { return (200, headers, rows) }
                return (200, [:], graph)
            }
            try exercise { api in
                do {
                    _ = try await api.personalRepositories(token: "fixture", viewer: .init(id: "U", login: "fixture"))
                    throw RecorderError.message("Incomplete permission data was accepted")
                } catch GitHubServiceError.response {}
            }
        }
    }
    func testDisabledDeviceFlowExplainsHowToEnableIt() throws {
        GitHubStub.respond = { _, _ in
            (400, [:], ["error": "device_flow_disabled", "error_description": "Device Flow must be explicitly enabled for this App"])
        }
        try exercise { api in
            do {
                _ = try await api.deviceCode(clientID: "public")
                throw RecorderError.message("Disabled device flow was accepted")
            } catch GitHubServiceError.response(let message) {
                XCTAssertTrue(message.contains("Enable Device Flow"))
                XCTAssertTrue(message.contains("Identifying and authorizing users"))
            }
        }
    }
    func testInstallationPagesDeviceRefreshAndRateLimit() throws {
        var pages: [String] = []
        var polls = 0
        GitHubStub.respond = { req, body in
            let path = req.url!.path
            pages.append(path)
            if path == "/login/device/code" {
                XCTAssertEqual(body["scope"] as? String, "offline_access")
                return (200, [:], ["user_code": "fixture", "device_code": "unused", "expires_in": 20, "interval": 1])
            }
            if path == "/login/oauth/access_token" {
                XCTAssertNil(body["client_secret"])
                if body["device_code"] != nil {
                    polls += 1
                    if polls == 1 { return (400, [:], ["error": "authorization_pending"]) }
                }
                if body["refresh_token"] as? String == "expired" { return (400, [:], ["error": "bad_refresh_token"]) }
                return (200, [:], ["access_token": "rotated", "refresh_token": "new", "expires_in": 28800])
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            switch path {
            case "/user/installations":
                return (
                    200, [:],
                    [
                        "total_count": 2,
                        "installations": [
                            ["id": 1, "permissions": ["issues": "read", "pull_requests": "read"]], ["id": 2, "suspended_at": "now"],
                        ],
                    ]
                )
            case "/user/installations/1/repositories":
                let first = req.url!.query!.contains("page=1") && !req.url!.query!.hasSuffix("page=2")
                let repos: [Object] = (first ? Array(0..<100) : [100]).map { ["node_id": "R\($0)", "full_name": "samples/r\($0)"] }
                return (200, [:], ["total_count": 101, "repositories": repos])
            default: return (429, ["Retry-After": "120"], ["message": "wait"])
            }
        }
        try exercise { api in
            let repos = try await api.repositories(token: "fixture")
            XCTAssertEqual(repos.count, 101)
            XCTAssertFalse(pages.contains("/user/installations/2/repositories"))
            let code = try await api.deviceCode(clientID: "public")
            let authorized = try await api.authorize(clientID: "public", code: code)
            XCTAssertEqual(authorized.refresh, "new")
            XCTAssertEqual(polls, 2)
            let renewed = try await api.renew(clientID: "public", refresh: "old")
            XCTAssertEqual(renewed.access, "rotated")
            do {
                _ = try await api.renew(clientID: "public", refresh: "expired")
                XCTAssertTrue(false)
            } catch GitHubServiceError.credentials {}
            do {
                _ = try await api.viewer(token: "fixture")
                XCTAssertTrue(false)
            } catch GitHubServiceError.retry(let date) { XCTAssertGreaterThan(date.timeIntervalSinceNow, 115) }
        }
    }
    func testPersonalDiscoveryAcrossPagesAndGraphQLReconciliation() throws {
        let viewer = GitHubIdentity(id: "U", login: "one")
        let repo = GitHubRepository(id: "R", name: "test/example")
        let stamp = "2026-05-10T12:00:00Z"
        let old = "2011-01-01T00:00:00Z"
        let header: Object = [
            "id": "P", "number": 7, "title": "An old PR", "state": "MERGED", "url": "https://github.com/test/example/pull/7",
            "repository": ["id": "R"], "author": ["id": "them", "login": "teammate"],
        ]
        func connection(_ nodes: [Object], _ cursor: String? = nil) -> Object {
            ["nodes": nodes, "pageInfo": ["hasNextPage": cursor != nil, "endCursor": cursor as Any]]
        }
        func metadata(_ id: String, _ actor: String = "U") -> Object {
            ["id": id, "author": ["id": actor], "repository": ["id": "R"], "createdAt": stamp, "updatedAt": stamp]
        }
        var contentRequested = Set<String>()
        var requestedCommentPages = 0
        GitHubStub.respond = { _, body in
            let query = body["query"] as! String
            let vars = body["variables"] as! Object
            var data: Object = [:]
            if query.contains("search(type:") {
                let reviewed = (vars["q"] as! String).contains("reviewed-by")
                var oldPR = metadata("P", "them")
                oldPR["createdAt"] = old
                var results = connection(reviewed ? [oldPR] : [metadata("authored"), metadata("mention", "them")])
                results["issueCount"] = 2
                data["search"] = results
            } else if query.contains("viewer { id issueComments") {
                requestedCommentPages += 1
                var outside = metadata("outside")
                outside["repository"] = ["id": "UNSELECTED"]
                var ancient = metadata("ancient")
                ancient["createdAt"] = old
                data["viewer"] = [
                    "id": "U",
                    "issueComments": vars["cursor"] is String
                        ? connection([ancient]) : connection([metadata("comment"), outside], "next"),
                ]
            } else if query.contains("reviews(first:") {
                var review = metadata("approval")
                review["submittedAt"] = stamp
                review["state"] = "APPROVED"
                var repeated = review
                repeated["id"] = "second"
                data["node"] = [
                    "repository": ["id": "R"], "reviews": connection([review, repeated, metadata("foreign-review", "them")]),
                ]
            } else if query.contains("reviewThreads(first:") {
                // The user's reply is on page two of a thread opened by a teammate.
                data["node"] = [
                    "repository": ["id": "R"],
                    "reviewThreads": connection([
                        ["id": "thread", "comments": connection([metadata("foreign-line", "them")], "next-line")]
                    ]),
                ]
            } else if query.contains("on PullRequestReviewThread") {
                var inline = metadata("inline")
                inline["state"] = "SUBMITTED"
                inline["publishedAt"] = stamp
                data["node"] = ["repository": ["id": "R"], "comments": connection([inline])]
            } else {
                let ids = vars["ids"] as! [String]
                contentRequested.formUnion(ids)
                data["nodes"] = ids.map { id -> Any in
                    if id == "deleted" { return NSNull() }
                    var n = metadata(id)
                    n["url"] = "https://github.com/test/example/pull/7#" + id
                    n["body"] = "my contribution"
                    switch id {
                    case "authored":
                        n["__typename"] = "Issue"
                        n["number"] = 1
                        n["title"] = "my issue"
                        n["issueState"] = "OPEN"
                    case "comment":
                        n["__typename"] = "IssueComment"
                        n["commentPR"] = header
                        n["lastEditedAt"] = stamp
                    case "inline":
                        n["__typename"] = "PullRequestReviewComment"
                        n["inlineState"] = "SUBMITTED"
                        n["publishedAt"] = stamp
                        n["pullRequest"] = header
                        n["originalLine"] = 6
                        n["path"] = "main.swift"
                    default:
                        n["__typename"] = "PullRequestReview"
                        n["submittedAt"] = stamp
                        n["reviewState"] = "APPROVED"
                        n["body"] = ""
                        n["pullRequest"] = header
                    }
                    return n
                }
            }
            return (200, [:], ["data": data])
        }
        try exercise { api in
            let start = 1_700_000_000
            var todo: [GitHubJob] = [
                .search(qualifier: "is:issue author:@me", since: start, until: 1_800_000_000, cutoff: start, cursor: nil),
                .search(qualifier: "is:pr reviewed-by:@me", since: start, until: 1_800_000_000, cutoff: start, cursor: nil),
                .comments(since: start, cursor: nil),
            ]
            var entries: [String: GitHubPassage] = [:]
            while !todo.isEmpty {
                let page = try await api.importPage(todo.removeFirst(), repo: repo, viewer: viewer, token: "fixture")
                todo += page.next
                for (item, action) in page.entries {
                    XCTAssertEqual(item.repositoryID, repo.id)
                    entries[action.id] = action
                }
            }
            XCTAssertEqual(contentRequested, Set(["authored", "comment", "approval", "second", "inline"]))
            XCTAssertEqual(requestedCommentPages, 2)
            XCTAssertEqual(entries["inline"]?.line, 6)
            XCTAssertEqual(entries["approval"]?.text, "")
            XCTAssertEqual(entries["comment"]?.kind, .comment)
            let checked = try await api.importPage(.nodes(ids: ["deleted"], since: 0), repo: repo, viewer: viewer, token: "fixture")
            XCTAssertEqual(checked.missing, ["deleted"])
        }
    }
}
