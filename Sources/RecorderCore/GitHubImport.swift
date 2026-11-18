import Foundation

extension GitHubClient {
    static let header = "id number title url repository { id } author { login ... on User { id } }"
    static let actorFields = "id url body createdAt lastEditedAt author { ... on User { id } }"
    static let nodeQuery = """
        query($ids:[ID!]!) { nodes(ids:$ids) { __typename
        ... on Issue { \(header) issueState:state body createdAt lastEditedAt }
        ... on PullRequest { \(header) prState:state body createdAt lastEditedAt }
        ... on IssueComment { \(actorFields) issue { \(header) state } commentPR:pullRequest { \(header) state } }
        ... on PullRequestReview { \(actorFields) reviewState:state submittedAt pullRequest { \(header) state } }
        ... on PullRequestReviewComment { \(actorFields) inlineState:state publishedAt path originalLine pullRequest { \(header) state } }
        } }
        """
    static let searchQuery = """
        query($q:String!,$cursor:String) { search(type:ISSUE,query:$q,first:75,after:$cursor) {
          issueCount pageInfo { hasNextPage endCursor } nodes { __typename
          ... on Issue { id createdAt repository { id } author { ... on User { id } } }
          ... on PullRequest { id createdAt repository { id } author { ... on User { id } } } } } }
        """
    static let commentsQuery = """
        query($cursor:String) { viewer { id issueComments(first:100,after:$cursor,orderBy:{field:UPDATED_AT,direction:DESC}) {
          pageInfo { hasNextPage endCursor } nodes { id createdAt updatedAt repository { id } } } } }
        """
    static let reviewsQuery = """
        query($id:ID!,$login:String!,$cursor:String) { node(id:$id) { ... on PullRequest {
        repository { id } reviews(first:75,author:$login,after:$cursor) { pageInfo { hasNextPage endCursor }
        nodes { id state submittedAt author { ... on User { id } } } } } } }
        """
    static let inlineMetadata = "pageInfo { hasNextPage endCursor } nodes { id state publishedAt author { ... on User { id } } }"
    static let threadsQuery = """
        query($id:ID!,$cursor:String) { node(id:$id) { ... on PullRequest {
        repository { id } reviewThreads(first:25,after:$cursor) { pageInfo { hasNextPage endCursor }
        nodes { id comments(first:30) { \(inlineMetadata) } } } } } }
        """
    static let threadQuery = """
        query($id:ID!,$cursor:String!) { node(id:$id) { ... on PullRequestReviewThread {
        repository { id } comments(first:100,after:$cursor) { \(inlineMetadata) } } } }
        """
    static func stamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return try? AgentArguments(["date": value]).date("date")
    }
    private func connection(_ value: Any?, cursor: String?) throws -> ([Object], String?) {
        guard let object = value as? Object, let nodes = object["nodes"] as? [Object],
            let info = object["pageInfo"] as? Object, let more = info["hasNextPage"] as? Bool
        else { throw Self.invalid }
        let next = info["endCursor"] as? String
        if more && (next == nil || next == cursor) { throw Self.invalid }
        return (nodes, more ? next : nil)
    }
    private func entry(_ node: Object, viewer: String, repo: String) throws -> (GitHubItem, GitHubPassage)? {
        let kind: GitHubActionKind
        let parent: Object
        let type: String
        guard (node["author"] as? Object)?["id"] as? String == viewer else { return nil }
        switch node["__typename"] as? String {
        case "Issue", "PullRequest":
            kind = .opened
            parent = node
            type = node["__typename"] as? String == "Issue" ? "issue" : "pr"
        case "IssueComment":
            kind = .comment
            if let pr = node["commentPR"] as? Object {
                parent = pr
                type = "pr"
            } else if let issue = node["issue"] as? Object {
                parent = issue
                type = "issue"
            } else {
                throw Self.invalid
            }
        case "PullRequestReview", "PullRequestReviewComment":
            guard (node["reviewState"] ?? node["inlineState"]) as? String != "PENDING", let pr = node["pullRequest"] as? Object else {
                return nil
            }
            kind = node["__typename"] as? String == "PullRequestReview" ? .review : .inline
            parent = pr
            type = "pr"
        default: return nil
        }
        guard (parent["repository"] as? Object)?["id"] as? String == repo else { return nil }
        guard let number = parent["number"] as? Int, let title = parent["title"] as? String, let itemID = parent["id"] as? String,
            let state = (parent["issueState"] ?? parent["prState"] ?? parent["state"]) as? String,
            let itemURL = parent["url"] as? String, let id = node["id"] as? String,
            let url = node["url"] as? String, let body = node["body"] as? String,
            let date = Self.stamp(
                kind == .review
                    ? node["submittedAt"] : kind == .inline ? (node["publishedAt"] as? String ?? node["createdAt"]) : node["createdAt"]
            )
        else { throw Self.invalid }
        let item = GitHubItem(
            id: itemID, repositoryID: repo, type: type, title: title,
            author: (parent["author"] as? Object)?["login"] as? String ?? "Deleted user", state: state, url: itemURL, number: number)
        let action = GitHubPassage(
            id: id, actorID: viewer, text: body, url: url, kind: kind, date: date, edited: Self.stamp(node["lastEditedAt"]),
            verdict: kind == .review ? node["reviewState"] as? String : nil, path: node["path"] as? String,
            line: node["originalLine"] as? Int)
        return (item, action)
    }

    private func ownInline(_ comments: [Object], viewer: String, since: Int) throws -> [String] {
        try comments.compactMap { comment in
            guard (comment["author"] as? Object)?["id"] as? String == viewer,
                comment["state"] as? String != "PENDING"
            else { return nil }
            guard let date = Self.stamp(comment["publishedAt"]), let id = comment["id"] as? String else { throw Self.invalid }
            return date.timeIntervalSince1970 >= Double(since) ? id : nil
        }
    }

    public func importPage(_ job: GitHubJob, repo: GitHubRepository, viewer: GitHubIdentity, token: String) async throws -> GitHubPage
    {
        var page = GitHubPage()
        func fetch(_ ids: [String], since: Int) {
            for i in stride(from: 0, to: ids.count, by: 30) {
                page.next.append(.nodes(ids: Array(ids[i..<min(i + 30, ids.count)]), since: since))
            }
        }
        switch job {
        case .search(let qualifier, let since, let until, let cutoff, let cursor):
            let range =
                AgentJSON.date(Date(timeIntervalSince1970: Double(since))) + ".."
                + AgentJSON.date(Date(timeIntervalSince1970: Double(until)))
            let query = "repo:\(repo.name) \(qualifier) updated:\(range)"
            let data = try await graph(Self.searchQuery, ["q": query, "cursor": cursor as Any], token: token)
            guard let search = data["search"] as? Object, let count = search["issueCount"] as? Int else { throw Self.invalid }
            if count > 1000, since < until {
                let mid = since + (until - since) / 2
                page.next = [
                    .search(qualifier: qualifier, since: since, until: mid, cutoff: cutoff, cursor: nil),
                    .search(qualifier: qualifier, since: mid + 1, until: until, cutoff: cutoff, cursor: nil),
                ]
                return page
            }
            page.partial = count > 1000
            let (nodes, next) = try connection(search, cursor: cursor)
            let reviews = qualifier.contains("reviewed-by:") || qualifier.contains("commenter:")
            // The search window uses item update time; all split windows retain the
            // original action cutoff, supplied by the sync coordinator.
            var ids: [String] = []
            for node in nodes {
                guard (node["repository"] as? Object)?["id"] as? String == repo.id, let id = node["id"] as? String else { continue }
                if reviews {
                    page.next.append(.reviews(item: id, since: cutoff, cursor: nil))
                } else if (node["author"] as? Object)?["id"] as? String == viewer.id, let created = Self.stamp(node["createdAt"]),
                    created.timeIntervalSince1970 >= Double(cutoff)
                {
                    ids.append(id)
                }
            }
            fetch(ids, since: cutoff)
            if let next { page.next.append(.search(qualifier: qualifier, since: since, until: until, cutoff: cutoff, cursor: next)) }
        case .comments(let since, let cursor):
            let data = try await graph(Self.commentsQuery, ["cursor": cursor as Any], token: token)
            guard let user = data["viewer"] as? Object, user["id"] as? String == viewer.id else { throw Self.invalid }
            let (nodes, next) = try connection(user["issueComments"], cursor: cursor)
            var ids: [String] = []
            var past = false
            for node in nodes {
                guard let updated = Self.stamp(node["updatedAt"]), let created = Self.stamp(node["createdAt"]),
                    let id = node["id"] as? String
                else { throw Self.invalid }
                if updated.timeIntervalSince1970 < Double(since) {
                    past = true
                    break
                }
                if created.timeIntervalSince1970 >= Double(since), (node["repository"] as? Object)?["id"] as? String == repo.id {
                    ids.append(id)
                }
            }
            fetch(ids, since: since)
            if !past, let next { page.next.append(.comments(since: since, cursor: next)) }
        case .reviews(let id, let since, let cursor):
            let data = try await graph(Self.reviewsQuery, ["id": id, "login": viewer.login, "cursor": cursor as Any], token: token)
            guard let parent = data["node"] as? Object, (parent["repository"] as? Object)?["id"] as? String == repo.id else { break }
            let (nodes, next) = try connection(parent["reviews"], cursor: cursor)
            var ids: [String] = []
            for node in nodes where (node["author"] as? Object)?["id"] as? String == viewer.id && node["state"] as? String != "PENDING"
            {
                guard let id = node["id"] as? String, let submitted = Self.stamp(node["submittedAt"]) else { throw Self.invalid }
                if submitted.timeIntervalSince1970 >= Double(since) { ids.append(id) }

            }
            fetch(ids, since: since)
            if let next { page.next.append(.reviews(item: id, since: since, cursor: next)) }
            if cursor == nil { page.next.append(.threads(item: id, since: since, cursor: nil)) }
        case .threads(let id, let since, let cursor):
            let data = try await graph(Self.threadsQuery, ["id": id, "cursor": cursor as Any], token: token)
            guard let parent = data["node"] as? Object, (parent["repository"] as? Object)?["id"] as? String == repo.id else { break }
            let (threads, next) = try connection(parent["reviewThreads"], cursor: cursor)
            var ids: [String] = []
            for thread in threads {
                guard let id = thread["id"] as? String else { throw Self.invalid }
                let (comments, more) = try connection(thread["comments"], cursor: nil)
                ids += try ownInline(comments, viewer: viewer.id, since: since)
                if let more { page.next.append(.thread(id: id, since: since, cursor: more)) }
            }
            fetch(ids, since: since)
            if let next { page.next.append(.threads(item: id, since: since, cursor: next)) }
        case .thread(let id, let since, let cursor):
            let data = try await graph(Self.threadQuery, ["id": id, "cursor": cursor], token: token)
            guard let thread = data["node"] as? Object, (thread["repository"] as? Object)?["id"] as? String == repo.id else { break }
            let (comments, next) = try connection(thread["comments"], cursor: cursor)
            fetch(try ownInline(comments, viewer: viewer.id, since: since), since: since)
            if let next { page.next.append(.thread(id: id, since: since, cursor: next)) }
        case .nodes(let ids, let since):
            let data = try await graph(Self.nodeQuery, ["ids": ids], token: token, missingNodes: true)
            guard let nodes = data["nodes"] as? [Any], nodes.count == ids.count else { throw Self.invalid }
            for (id, value) in zip(ids, nodes) {
                if value is NSNull {
                    page.missing.append(id)
                    continue
                }
                guard let node = value as? Object, node["id"] as? String == id else { throw Self.invalid }
                if let pair = try entry(node, viewer: viewer.id, repo: repo.id) {
                    if pair.1.date.timeIntervalSince1970 >= Double(since) { page.entries.append(pair) }
                } else {
                    page.missing.append(id)
                }
            }
        }
        return page
    }
}
