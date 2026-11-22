# MCP access

Afterword includes a local, client-agnostic MCP server with optional summary writes and task board management. Enable **Settings → Agent Access** and select allowed recording folders. Access starts disabled, with no allowed folders. New library folders are not automatically exposed.

The server advertises `afterword` as its implementation name and **Afterword** as its display title. Its executable is `build/Afterword.app/Contents/Helpers/AfterwordMCP`. After renaming the repository, update clients to use this executable at the new absolute path and reconnect them.

The **Copy Server Path** button copies the bundled `Contents/Helpers/AfterwordMCP` executable. Configure your MCP client to launch that command with no arguments, using **stdio**. Supply the executable path as a command value, not an unquoted shell string. No network listener, account connection, runtime installation, or running app window is required. Clients that require a remote HTTP endpoint cannot connect directly to this local executable.

The server implements the [MCP 2025-11-25 stdio protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), including initialization, ping, tool discovery, tool calls, and structured results with a text fallback. It also negotiates the compatible 2025-06-18 protocol. Unsupported versions are offered 2025-11-25 during initialization. It advertises no prompts, resources, or subscriptions. The activity tools are always discoverable and check their grants at execution time. Board tools appear only when both the board source and its agent grant are enabled. Connected clients receive `notifications/tools/list_changed` when board availability changes.

Bridges can reuse one helper process across discovery attempts and clients. A repeated valid `initialize` starts a new handshake and requires another `notifications/initialized` before tool requests. Invalid initialization attempts leave the existing connection intact. Unknown methods, including newer discovery probes, return `Method not found` so clients can fall back to supported discovery.

## Task board

Enable **Settings → Sources → Task board**, then **Settings → Agent Access → Enable agent access → Allow agents to manage the task board**. In this experiment, point your client at the helper inside the experiment’s app bundle. The board can be used by itself. With another source enabled, choose **Create follow-up ticket…** in the context menu of a work call, session, or GitHub item to start a ticket with a citation. Board access shares all ticket titles, notes, and layout. Text you enter in a title or notes stays shared when you revoke source access. Follow-ups put excerpts in citations. Each MCP request checks the current recording folder and call scope, imported coding session access, or GitHub repository grant before exposing any part of a citation. The native app retains the saved citation.

For example, ask an agent “Read yesterday’s work activity. Add a ticket for each open action I agreed to take, cite the passage, and skip anything already tracked.” The connected agent runs this workflow when invoked. Enabling the board alone does not start an extractor.

1. Use `search_activity` and the corresponding call, session, or GitHub read tool to verify each action.
2. Read `get_board` for the revision and group IDs. Use `list_board_tickets` to check for existing work. With no query, it browses in stored order. A `query` ranks titles, notes, and saved citation text and returns a `match` with its field and excerpt. Search supports word prefixes, inflections, and reordered words. To find tickets citing the same activity, pass `source` and `item_id`, optionally narrowed by `anchor` and `version_id`. The result includes the `matched_reference`. Column, swimlane, and origin key filters work with both browsing and search. Add supporting evidence to an existing ticket or use `create_board_ticket` for a new one. Use an opaque UUID as the stable `origin_key` for each distinct action to deduplicate retries. Legacy free-form keys remain local because they can embed source IDs. Multiple tickets may cite the same source.
3. Attach evidence with `add_board_reference`. Supply `ticket_id`, `source` (call, coding, or github), and the shared `item_id`. Use `anchor` for a paragraph, message, or contribution and `version_id` for a specific transcript. An optional `quote` must occur verbatim in the cited evidence. Afterword resolves the title from the source and returns an opaque `reference_id`. Use that ID with `remove_board_reference`.
4. Use `get_board_ticket`, `update_board_ticket`, and `delete_board_ticket` to manage tickets. Omit `references` on ordinary edits. A supplied list replaces only currently visible citations. Include the returned `reference_id` to modify a visible citation. Deleting a ticket deletes the whole card and its attachments. The board and group tools manage the ordered columns and swimlanes.
5. Pass the latest opaque string `revision` as `expected_revision` on writes and subsequent search pages. The token covers the shared board view. A private citation edit leaves that token valid. Revocation takes effect on the next request, including searches, filters, excerpts and totals. Re-sharing restores citations whose evidence still exists. Saved quotations that can no longer be verified stay local.

Open the updated app to upgrade an existing experiment board. The upgrade preserves its tickets and assigns stable citation IDs. Earlier experiment helpers cannot read the upgraded format. Reconnect clients using the updated helper to discover the reference tools and revision schema.

### Work and personal calls

Call tools and `search_activity` default to `scope: "work"`. Ordinary searches, recaps, transcript results, and change feeds cover work calls. To act on an explicit request about personal calls, pass `scope: "personal"` on discovery, reads, and summary writes. Personal activity searches cover recordings only. Keep a separate change cursor for each scope. Reclassifying a call removes it from one feed and adds it to the other.

Personal access requires **Settings → Agent Access → Allow agents to access personal calls** and an allowed recording folder. This grants access to personal calls in those folders. Saving a summary also requires **Allow agents to save summaries**. A user can copy a request from the call’s Summary tab to identify it by ID. The copied request contains no transcript text. Reconnect MCP clients after upgrading to discover the scope parameter. Older helpers reject the upgraded access file.

### Connecting through a tunnel

A stdio-capable tunnel can connect remote clients to the same bundled helper. For OpenAI's `tunnel-client`, configure the helper as the main MCP command and enable `mcp.stdio_send_initialized_notification: true` in the tunnel profile. This supplies the lifecycle notification after each successful initialization when the remote caller omits it. Keep API keys in private files referenced by the profile rather than in command-line arguments.

With a configured profile named `afterword`, run the tunnel in the foreground:

```sh
tunnel-client run --profile afterword --log.file stdout
```

Keep that process running while the remote client connects; Ctrl+C stops it. The tunnel is managed separately from the Afterword app. After updating the helper, restart the tunnel so it launches the new executable. See the [Secure MCP Tunnel setup guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) for tunnel creation and account access.

## Tools

| Tool | Inputs | Result |
|---|---|---|
| `search_activity` | Optional query, source, mode, date bounds, source filters, paging | Ranked calls, coding sessions and GitHub items with source-specific citations |
| `get_coding_session` | Required `session_id`; optional message anchor, view, revision, paging | Imported coding conversation and message citations |
| `get_github_item` | Required `item_id`; optional passage anchor, revision, paging | Shared issue or PR and the user’s own contributions |
| `list_calls` | Optional `query`, `mode`, `speaker`, `all_versions`, `participant`, `tag`, `from`, `to`, paging | Saved call metadata, summary availability, latest transcript version, and `library_revision` |
| `search_transcripts` | Required `query`; optional `mode`, `speaker`, participant/tag/date filters, `all_versions`, paging | Ranked passage windows with merged context, source references, and `library_revision` |
| `get_call` | Required `call_id`; optional `expected_revision`, `summary_revision_id`, `summary_offset`, `summary_limit` | Call information, saved transcript versions, current or selected summary, and summary history |
| `get_transcript` | Required `call_id`; optional `version_id`, `start_seconds`, `end_seconds`, paging | Resolved speaker paragraphs, source track, times, source references, call revision and version |
| `save_call_summary` | Required `call_id`, `expected_revision`, `source_version_id`, `markdown` | New call revision and saved summary; prior summaries retained |
| `get_changes` | Optional `cursor` or `page_token`; optional `limit` | Added, updated, and removed call IDs with revisions and a new checkpoint |

Dates use ISO 8601 with an explicit timezone. `from` is inclusive; `to` is exclusive. Participant matching is a case/diacritic-insensitive substring; tag matching is exact, case-insensitive. Text search uses the same SQLite FTS5 index and query parser as the library: unquoted words are ANDed in any order and match prefixes automatically (`bellam` finds `Bellamy`, as does `bellam*`). Quotes require exact words or phrases (`"bellam"` does not find `Bellamy`). Matching ignores case and accents. There are no Boolean operators or fuzzy spelling correction; `OR` is an ordinary word. Phrases may span reading paragraphs. Separate words may occur in different paragraphs or searchable fields. `list_calls` searches metadata, the current summary, transcript text, and speakers; `search_transcripts` searches text and speakers only. Both default to the latest saved transcript; `all_versions: true` opts into history. Results are ranked by relevance (title matches receive extra weight); equal scores prefer newer calls. Listing without a query remains newest first. Default transcript retrieval uses the latest saved version. Unreadable versions are reported, never silently replaced by an older version.

When local semantic search is enabled in **Settings → Search**, the default `mode: "hybrid"` adds passages with related meanings and combines lexical and semantic ranks. `mode: "keyword"` forces the literal-prefix behavior above. Quoted phrases remain hard constraints. `speaker` is an exact, case/accent-insensitive current speaker label and restricts matching speech; `participant` filters calls by their active participant lists. Context may include other speakers. With a speaker filter, keyword terms must occur in that speaker's speech or label.

Both list and search responses include `search_status`: `enabled`, `model`, `state`, `mode` (actual `keyword` or `hybrid`), `indexed`, `total`, `coverage_complete`, and a readable `message`. Counts describe chunks for the current allowed library and latest/history selection. Disabled, missing, paused, busy, or failed inference uses keyword search. Partial semantic coverage is explicitly reported; absence from an incomplete result is not evidence that the topic never occurred. Search pagination revisions include semantic coverage and actual mode, so indexing or fallback can require restarting pagination. Call revisions and change checkpoints describe saved content, including summaries; embedding progress does not alter call revisions. See [local semantic search](semantic-search.md).

Pagination uses `offset` (default 0), `limit` (default 40, maximum 100), and `next_offset`. Preserve filters and pass the returned `library_revision` as `expected_revision` for subsequent list/search pages. For transcript pages, use `call.revision`. A mismatch requires restarting retrieval. `get_changes` uses its own frozen page tokens instead of offsets. Results over 1 MiB fail with an instruction to narrow the request. Incoming messages are limited to 1 MiB; oversized messages terminate the connection.

Search results contain `matches` for all contributing paragraphs in a window, `match` for the first (compatibility), and `context` with at most eight paragraphs. Overlapping neighbor windows are merged and long windows split into disjoint chunks, avoiding repeated context. `total`, `offset`, and `next_offset` count these windows. For multiword keyword searches, a window can provide only part of the evidence; the enclosing version satisfies the full query.

## Saving and reading summaries

Enable **Allow agents to save summaries** under **Settings → Agent Access**. Existing settings migrate with writes off. All writes remain confined to explicitly allowed calls; no arbitrary path argument is accepted. Audio, transcripts, attendance, and call details remain read-only.

Read `get_call` for any current summary, then `get_transcript` for the source. Pass `call.revision` (or the equivalent `get_call.revision`) as required `expected_revision`, the transcript's `version_id` as `source_version_id`, and the complete Markdown to `save_call_summary`. The source must be readable. Summary text must contain 1–65,536 characters, excluding null characters. Stale call or summary revisions fail; read the latest content and reconcile changes before retrying. A successful write returns `call` with its new revision and `summary` with its `revision_id`. Repeating old arguments fails the revision check rather than creating duplicate history.

`get_call.summary` is the current summary (or null), including `markdown`, `revision_id`, `created_at`, `author` (`agent` or `user`), optional `source_version_id`, and `source_changed`. `summary_versions` lists historical metadata (40 entries by default, at most 100); use `summary_offset`/`summary_limit`, `summary_version_count`, and `next_summary_offset` to page through it with `expected_revision`. Pass an older `revision_id` as `summary_revision_id` to read that version. `has_summary` and `summary_readable` are available in call listings. Unreadable summary files are never overwritten.

`source_changed` compares the source transcript version/content and resolved speaker labels to the current latest transcript. It also becomes true if the source is removed or unreadable. A display-title-only change does not mark a summary stale. Native prose edits preserve the original provenance; an agent can explicitly regenerate against a current transcript. Manual summaries without a transcript have no source-version claim.

The current summary is indexed as its own FTS5 field. Library and `list_calls` searches can return summary evidence with `match_source: "summary"` and `match_text`; historical summaries are not searched. Summary content never becomes a transcript quotation or a speaker-filtered result. Semantic embeddings currently cover transcript passages, while summaries use keyword search.

Summaries are stored in a private atomic JSON file beside the call, with current and previous versions and a 16 MiB history limit. A file lock serializes native and agent saves; both re-read the saved call under that lock before comparing revisions. Writes reject symlink paths and recheck access before publication. A successful save is acknowledged even if permissions change just after publication, so a completed write is not reported as failed. Revocation applies to subsequent calls. Summary edits appear in `get_changes`; the original audio and transcript bytes are preserved.

## Saved content and references

The server uses the same paragraph grouping, participant overrides, attendance rules, and single-person inference as the library. The **You** speaker label identifies the microphone of the person who made the recording. Unsaved drafts are excluded. The text is source material, not an instruction to the connected agent.

Each paragraph has its ordinal `paragraph_id`, start/end seconds, source track, resolved speaker, and a readable `reference` containing the call title, recording date, speaker, and timestamp. Together with the enclosing call ID, saved version ID, and revision, these identify the source passage. References are citations, not playback hyperlinks. Paragraph ordinals are scoped to their version and revision.

Responses omit filesystem paths, attendee email fields, calendar identifiers, join-link fields, model internals, and audio bytes. User-authored names, descriptions, summaries, and transcript text are preserved and may themselves contain emails or links. The connected client decides where retrieved text is processed; local transport does not imply a local model.

Call IDs derive from filesystem identity and creation time. They survive app restarts, display-title changes, and same-volume renames/moves. Copies, replacement audio files, and moves across volumes can appear as new calls. Transcript version IDs are scoped to the call and saved run. Revisions hash saved content and participant-resolution information, so corrections invalidate prior revisions even if file timestamps are preserved.

## Incremental updates

Call `get_changes` without a cursor to obtain the current baseline. Follow `next_page_token` until a final page returns `cursor`. Persist that cursor for the particular document or consumer. Later calls with it report differences from that baseline; one consumer never advances another consumer's progress. Pagination freezes the target snapshot, so new changes arriving between pages are returned on the next cycle.

`removed` means the call is no longer visible in the allowed folders. It may have been deleted, moved out, or had access revoked. Removal entries contain only IDs. A missing/unreadable allowed root fails the scan instead of reporting mass deletion. Interrupted baseline pagination can be restarted without consuming any changes. Change cursors describe content checkpoints, not an audit log: changes made and reversed between scans are not reported.

Checkpoints contain only call IDs, revision hashes, and an access-scope hash. They are saved privately in `~/Library/Application Support/Afterword/MCP/Checkpoints`. Checkpoints older than 30 days may be pruned. Unknown, expired, or corrupt cursors fail explicitly; recover by obtaining a full baseline. Clearing this directory invalidates saved cursors but does not alter calls.

## Access and lifecycle

`Access.json` in the MCP support directory stores the enabled flag, selected canonical folder paths, and separate `allowSummaryWrites` and `allowPersonalCalls` flags (both default to false). The helper reloads it on every tool call and checks it again before returning read data or publishing a summary. Disabling access blocks subsequent calls from already-running clients. Changing folder access invalidates in-progress change pagination. This is application-level access control for a process running as your user, not an OS sandbox against other software already able to read your files.

The helper scans only published library entries and does not follow symlinked call folders or transcript directories. It accepts opaque call/version IDs, never client-supplied recording paths. Hidden staging directories stay excluded. Folder scans fail on oversized transcript JSON (16 MiB) or call metadata (1 MiB), rather than loading unbounded input. There is no source-file polling, recording control, transcription trigger, automatic source refresh schedule, or write operation beyond explicitly enabled summaries. When enabled, local embedding work can continue in bounded background batches after a request.

The app and server maintain rebuildable, scope-specific search databases in `~/Library/Caches/Afterword/Search`. These caches contain derived text and saved call snapshots; they never override JSON source files or grant access to a revoked folder. Each request checks allowed sources using file identity, size, mtime, and ctime, then decodes/indexes/hashes only changed calls. Same-size edits preserving mtime are detected through ctime. An unavailable allowed folder fails the request rather than serving stale results. SQLite transactions coordinate writers; searches reject a snapshot that another helper replaced mid-request. Clearing the cache with readers closed rebuilds it on the next request. A custom `--state-directory` keeps its text cache under `Search` and isolates semantic settings/models/vectors under `Embeddings` there.

Independent helper processes can share the private checkpoint store; a file lock and atomic writes coordinate access. Closing the MCP client's stdin exits the helper. Diagnostic output belongs on stderr; stdout contains only protocol messages. For isolated testing or a separate explicitly configured library, `--state-directory /absolute/path` selects another settings/checkpoint directory, still disabled until its access file enables it.

## Verification

`./Scripts/check-search.sh` benchmarks 10/50/100 synthetic calls with 1,800 word segments each, using temporary audio and cache folders. It measures initial/incremental indexing separately from warm searches; it never reads user recordings.

`./Scripts/test.sh` covers incremental indexing, phrase/prefix matching, latest/history semantics, same-size preserved-mtime edits, merged result pagination, cache recovery, access revocation, speaker resolution, saved versions, bounded inputs, stable IDs, pagination, corrupt transcripts, symlink confinement, unavailable folders, independent change checkpoints, and protocol errors alongside the existing recorder tests.

The process check uses the official MCP Python client against synthetic audio and temporary settings:

```sh
uv run --with mcp==1.28.1 Scripts/check-mcp.py 'build/Afterword.app/Contents/Helpers/AfterwordMCP'
```

The bundled helper is signed with the persistent app signing certificate under its own `io.local.afterword.mcp` identifier.


## Coding activity

`search_activity` returns one result per allowed call, coding session, or GitHub item. Supply a `query` to search titles and passages. Coding results identify their provider in `source` (`claude-code` or `codex`) and include the best matching excerpt when available, with up to two additional citations in `more_passages`. Each citation has its own `message_id` and `view` for opening the source. A title-only match opens the session. Set `source` to `all`, `calls`, `coding`, or `github`, and `mode` to `hybrid` or `keyword`. An exact `project` or `branch` filter selects coding sessions.

Omit `query` to browse recent activity. With ISO time bounds (`from` inclusive, `to` exclusive), each active coding session shows conversation excerpts from that period and a `tool_only_message_count`. A session with only tool activity in the period still appears. Results sort by the most recent in-range activity (`last_activity_at` for coding sessions). An excerpt’s `date` is its message timestamp. For topic searches, date filters apply to each passage or to the session update date for a title match.

`get_coding_session` requires coding access on each request. Pass a coding result’s `session_id`, `message_id`, and `view` to start at the cited passage, or omit the last two for the active conversation. Use `view: "recorded"` for earlier context and inactive branches. Pagination uses `next_offset` relative to the same anchor and an optional `expected_revision`. Long messages return `next_text_offset`; use the message ID and `limit: 1` to read the next part. Tool names are included. The archive excludes tool inputs and tool result payloads. The existing `get_changes` feed continues to track calls.


## GitHub activity

Enable Agent Access and share each imported repository in Afterword. Both tools work from the last verified local snapshot. The native app handles authorization and sync.

To find a review on an older PR, filter by the date of the contribution:

```json
{"source":"github","repository":"sample/garden","action":"review","from":"2026-01-05T00:00:00Z","to":"2026-01-12T00:00:00Z"}
```

Pass this object to `search_activity`. Other action values are `opened`, `comment`, and `inline`. Use `item_type` with `issue` or `pr`. A GitHub filter scopes a search to GitHub. To resolve an exact number, pass `{"query":"sample/garden#42","source":"github"}`; a bare `#42` also requires `repository`. An empty query reports `browse` mode, and a GitHub-only exact lookup reports `reference` mode.

Each result includes `kind: "github"`, `item_id`, repository, number, item type, title, author, state, URL and up to three citations. Each citation includes an action, date, permalink and stable `passage_id`. Submitted reviews carry a verdict, including approvals with empty text. File citations can include `path` and `original_line`.

Pass the returned `item_id` to `get_github_item` for a chronological timeline. Include a `passage_id` to begin at that contribution. Page forward with the same anchor, `next_offset`, and the returned `revision` as `expected_revision`. For long text, use the cited passage, `limit: 1`, and `text_offset` equal to its `next_text_offset`.

A call summary or coding message containing an explicit qualified reference may include `related_github_items`. Only currently shared repositories can appear in those links or be opened by ID. The existing `get_changes` feed covers calls. [Connection and archive behavior](github-history.md)
