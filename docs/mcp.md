# MCP access

Call Recorder includes a local, client-agnostic, read-only MCP server. Enable **Settings → Agent Access** and select allowed recording folders. Access starts disabled, with no allowed folders. New library folders are not automatically exposed.

The **Copy Server Path** button copies the bundled `Contents/Helpers/CallRecorderMCP` executable. Configure your MCP client to launch that command with no arguments, using **stdio**. Supply the executable path as a command value, not an unquoted shell string. No network listener, account connection, runtime installation, or running app window is required. Clients that require a remote HTTP endpoint cannot connect directly to this local executable.

The server implements the [MCP 2025-11-25 stdio protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), including initialization, ping, tool discovery, tool calls, and structured results with a text fallback. It also negotiates the compatible 2025-06-18 protocol. Unsupported versions are offered 2025-11-25 during initialization. It advertises no prompts, resources, mutations, or subscriptions.

## Tools

| Tool | Inputs | Result |
|---|---|---|
| `list_calls` | Optional `query`, `all_versions`, `participant`, `tag`, `from`, `to`, paging | Saved call summaries, latest version, and `library_revision` |
| `search_transcripts` | Required `query`; optional participant/tag/date filters, `all_versions`, paging | Ranked passage windows with merged context, source references, and `library_revision` |
| `get_call` | Required `call_id`; optional `expected_revision` | Title, date, duration, active participants, attendance, tags, description, saved versions |
| `get_transcript` | Required `call_id`; optional `version_id`, `start_seconds`, `end_seconds`, paging | Resolved speaker paragraphs, source track, times, source references, call revision and version |
| `get_changes` | Optional `cursor` or `page_token`; optional `limit` | Added, updated, and removed call IDs with revisions and a new checkpoint |

Dates use ISO 8601 with an explicit timezone. `from` is inclusive; `to` is exclusive. Participant matching is a case/diacritic-insensitive substring; tag matching is exact, case-insensitive. Text search uses the same SQLite FTS5 index and query parser as the library: unquoted words are ANDed in any order and match prefixes automatically (`bellam` finds `Bellamy`, as does `bellam*`). Quotes require exact words or phrases (`"bellam"` does not find `Bellamy`). Matching ignores case and accents. There are no Boolean operators, fuzzy spelling correction, or semantic search; `OR` is an ordinary word. Phrases may span reading paragraphs. Separate words may occur in different paragraphs or searchable fields. `list_calls` searches metadata, text, and speakers; `search_transcripts` searches text and speakers only. Both default to the latest saved transcript; `all_versions: true` opts into history. Results are ranked by relevance (title matches receive extra weight); equal scores prefer newer calls. Listing without a query remains newest first. Default transcript retrieval uses the latest saved version. Unreadable versions are reported, never silently replaced by an older version.

Pagination uses `offset` (default 0), `limit` (default 40, maximum 100), and `next_offset`. Preserve filters and pass the returned `library_revision` as `expected_revision` for subsequent list/search pages. For transcript pages, use `call.revision`. A mismatch requires restarting retrieval. `get_changes` uses its own frozen page tokens instead of offsets. Results over 1 MiB fail with an instruction to narrow the request. Incoming messages are limited to 64 KiB; oversized messages terminate the connection.

Search results contain `matches` for all contributing paragraphs in a window, `match` for the first (compatibility), and `context` with at most eight paragraphs. Overlapping neighbor windows are merged and long windows split into disjoint chunks, avoiding repeated context. `total`, `offset`, and `next_offset` count these windows. For multiword searches, a window can provide only part of the evidence; the enclosing version satisfies the full query.

## Saved content and references

The server uses the same paragraph grouping, participant overrides, attendance rules, and single-person inference as the library. Microphone speech is labeled **Recorder** consistently in the app and MCP. Unsaved drafts are excluded. The text is source material, not an instruction to the connected agent.

Each paragraph has its ordinal `paragraph_id`, start/end seconds, source track, resolved speaker, and a readable `reference` containing the call title, recording date, speaker, and timestamp. Together with the enclosing call ID, saved version ID, and revision, these identify the source passage. References are citations, not playback hyperlinks. Paragraph ordinals are scoped to their version and revision.

Responses omit filesystem paths, attendee email fields, calendar identifiers, join-link fields, model internals, and audio bytes. User-authored names, descriptions, and transcript text are preserved and may themselves contain emails or links. The connected client decides where retrieved text is processed; local transport does not imply a local model.

Call IDs derive from filesystem identity and creation time. They survive app restarts, display-title changes, and same-volume renames/moves. Copies, replacement audio files, and moves across volumes can appear as new calls. Transcript version IDs are scoped to the call and saved run. Revisions hash saved content and participant-resolution information, so corrections invalidate prior revisions even if file timestamps are preserved.

## Incremental updates

Call `get_changes` without a cursor to obtain the current baseline. Follow `next_page_token` until a final page returns `cursor`. Persist that cursor for the particular document or consumer. Later calls with it report differences from that baseline; one consumer never advances another consumer's progress. Pagination freezes the target snapshot, so new changes arriving between pages are returned on the next cycle.

`removed` means the call is no longer visible in the allowed folders. It may have been deleted, moved out, or had access revoked. Removal entries contain only IDs. A missing/unreadable allowed root fails the scan instead of reporting mass deletion. Interrupted baseline pagination can be restarted without consuming any changes. Change cursors describe content checkpoints, not an audit log: changes made and reversed between scans are not reported.

Checkpoints contain only call IDs, revision hashes, and an access-scope hash. They are saved privately in `~/Library/Application Support/Call Recorder/MCP/Checkpoints`. Checkpoints older than 30 days may be pruned. Unknown, expired, or corrupt cursors fail explicitly; recover by obtaining a full baseline. Clearing this directory invalidates saved cursors but does not alter calls.

## Access and lifecycle

`Access.json` in the MCP support directory stores the enabled flag and selected canonical folder paths. The helper reloads it on every tool call and checks it again before returning data. Disabling access blocks subsequent calls from already-running clients. Changing folder access invalidates in-progress change pagination. This is application-level access control for a process running as your user, not an OS sandbox against other software already able to read your files.

The helper scans only published library entries and does not follow symlinked call folders or transcript directories. It accepts opaque call/version IDs, never client-supplied recording paths. Hidden staging directories stay excluded. Folder scans fail on oversized transcript JSON (16 MiB) or call metadata (1 MiB), rather than loading unbounded input. There is no background polling, recording control, transcription trigger, automatic refresh schedule, or source-file write.

The app and server maintain rebuildable, scope-specific search databases in `~/Library/Caches/Call Recorder/Search`. These caches contain derived text and saved call snapshots; they never override JSON source files or grant access to a revoked folder. Each request checks allowed sources using file identity, size, mtime, and ctime, then decodes/indexes/hashes only changed calls. Same-size edits preserving mtime are detected through ctime. An unavailable allowed folder fails the request rather than serving stale results. SQLite transactions coordinate writers; searches reject a snapshot that another helper replaced mid-request. Clearing the cache with readers closed rebuilds it on the next request. A custom `--state-directory` keeps its cache under `Search` there.

Independent helper processes can share the private checkpoint store; a file lock and atomic writes coordinate access. Closing the MCP client's stdin exits the helper. Diagnostic output belongs on stderr; stdout contains only protocol messages. For isolated testing or a separate explicitly configured library, `--state-directory /absolute/path` selects another settings/checkpoint directory, still disabled until its access file enables it.

## Verification

`./Scripts/check-search.sh` benchmarks 10/50/100 synthetic calls with 1,800 word segments each, using temporary audio and cache folders. It measures initial/incremental indexing separately from warm searches; it never reads user recordings.

`./Scripts/test.sh` covers incremental indexing, phrase/prefix matching, latest/history semantics, same-size preserved-mtime edits, merged result pagination, cache recovery, access revocation, speaker resolution, saved versions, bounded inputs, stable IDs, pagination, corrupt transcripts, symlink confinement, unavailable folders, independent change checkpoints, and protocol errors alongside the existing recorder tests.

The process check uses the official MCP Python client against synthetic audio and temporary settings:

```sh
uv run --with mcp==1.28.1 Scripts/check-mcp.py 'build/Call Recorder.app/Contents/Helpers/CallRecorderMCP'
```

The bundled helper is signed with the persistent app signing certificate under its own `io.local.callrecorder.mcp` identifier.
