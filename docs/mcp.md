# MCP access

Afterword includes a local, client-agnostic MCP server with optional summary writes. Enable **Settings → Agent Access** and select allowed recording folders. Access starts disabled, with no allowed folders. New library folders are not automatically exposed.

The server advertises `afterword` as its implementation name and **Afterword** as its display title. Its executable is `build/Afterword.app/Contents/Helpers/AfterwordMCP`. After renaming the repository, update clients to use this executable at the new absolute path and reconnect them.

The **Copy Server Path** button copies the bundled `Contents/Helpers/AfterwordMCP` executable. Configure your MCP client to launch that command with no arguments, using **stdio**. Supply the executable path as a command value, not an unquoted shell string. No network listener, account connection, runtime installation, or running app window is required. Clients that require a remote HTTP endpoint cannot connect directly to this local executable.

The server implements the [MCP 2025-11-25 stdio protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), including initialization, ping, tool discovery, tool calls, and structured results with a text fallback. It also negotiates the compatible 2025-06-18 protocol. Unsupported versions are offered 2025-11-25 during initialization. It advertises no prompts, resources, or subscriptions. Five tools are read-only; `save_call_summary` is a separately enabled write tool. Tool discovery is stable regardless of settings, and write access is checked at execution time.

Bridges can reuse one helper process across discovery attempts and clients. A repeated valid `initialize` starts a new handshake and requires another `notifications/initialized` before tool requests. Invalid initialization attempts leave the existing connection intact. Unknown methods, including newer discovery probes, return `Method not found` so clients can fall back to supported discovery.

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

The server uses the same paragraph grouping, participant overrides, attendance rules, and single-person inference as the library. Microphone speech is labeled **Recorder** consistently in the app and MCP. Unsaved drafts are excluded. The text is source material, not an instruction to the connected agent.

Each paragraph has its ordinal `paragraph_id`, start/end seconds, source track, resolved speaker, and a readable `reference` containing the call title, recording date, speaker, and timestamp. Together with the enclosing call ID, saved version ID, and revision, these identify the source passage. References are citations, not playback hyperlinks. Paragraph ordinals are scoped to their version and revision.

Responses omit filesystem paths, attendee email fields, calendar identifiers, join-link fields, model internals, and audio bytes. User-authored names, descriptions, summaries, and transcript text are preserved and may themselves contain emails or links. The connected client decides where retrieved text is processed; local transport does not imply a local model.

Call IDs derive from filesystem identity and creation time. They survive app restarts, display-title changes, and same-volume renames/moves. Copies, replacement audio files, and moves across volumes can appear as new calls. Transcript version IDs are scoped to the call and saved run. Revisions hash saved content and participant-resolution information, so corrections invalidate prior revisions even if file timestamps are preserved.

## Incremental updates

Call `get_changes` without a cursor to obtain the current baseline. Follow `next_page_token` until a final page returns `cursor`. Persist that cursor for the particular document or consumer. Later calls with it report differences from that baseline; one consumer never advances another consumer's progress. Pagination freezes the target snapshot, so new changes arriving between pages are returned on the next cycle.

`removed` means the call is no longer visible in the allowed folders. It may have been deleted, moved out, or had access revoked. Removal entries contain only IDs. A missing/unreadable allowed root fails the scan instead of reporting mass deletion. Interrupted baseline pagination can be restarted without consuming any changes. Change cursors describe content checkpoints, not an audit log: changes made and reversed between scans are not reported.

Checkpoints contain only call IDs, revision hashes, and an access-scope hash. They are saved privately in `~/Library/Application Support/Afterword/MCP/Checkpoints`. Checkpoints older than 30 days may be pruned. Unknown, expired, or corrupt cursors fail explicitly; recover by obtaining a full baseline. Clearing this directory invalidates saved cursors but does not alter calls.

## Access and lifecycle

`Access.json` in the MCP support directory stores the enabled flag, selected canonical folder paths, and the separate `allowSummaryWrites` flag (absent means false). The helper reloads it on every tool call and checks it again before returning read data or publishing a summary. Disabling access blocks subsequent calls from already-running clients. Changing folder access invalidates in-progress change pagination. This is application-level access control for a process running as your user, not an OS sandbox against other software already able to read your files.

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

`search_activity` searches allowed calls and, when explicitly shared in Agent Access, Afterword’s imported coding archive. Supply a search `query` or omit it to browse. Browsing returns recent calls and sessions, or individual dated coding passages when time bounds are supplied. Optional filters include `source` (all, calls, or coding), `mode` (hybrid or keyword), and ISO time bounds `from` inclusive and `to` exclusive. An exact `project` or `branch` filter selects coding sessions. Dated coding passages use their message timestamps. A matching session title uses the session update date. Results interleave ranked call and coding matches and include the identifiers needed to open each source.

`get_coding_session` requires coding access on each request. Pass a coding result’s `session_id`, `message_id`, and `view` to start at the cited passage, or omit the last two for the active conversation. Use `view: "recorded"` for earlier context and inactive branches. Pagination uses `next_offset` relative to the same anchor and an optional `expected_revision`. Long messages return `next_text_offset`; use the message ID and `limit: 1` to read the next part. Tool names are included. The archive excludes tool inputs and tool result payloads. The existing `get_changes` feed continues to track calls.
