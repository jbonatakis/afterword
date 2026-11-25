# Afterword documentation

## Set up the library

On first launch, choose **Recordings**, **Coding sessions**, **GitHub**, **Task board**, or any combination. You can change the selection in **Settings → Sources**. Turning off a source stops its background work and hides its items from the library, search, and connected agents. Enabling it again restores its saved configuration and history.

| Source | Where to start |
| --- | --- |
| Recordings | Choose a save folder during setup or when you start your first recording. Manage that destination and folders of existing calls in **Settings → Recording**. [Recording guide](recordings.md) |
| Coding sessions | Enable Claude Code, Codex, Pi, or Google Antigravity and select project folders in **Settings → Coding**. |
| GitHub | Connect your account in **Settings → GitHub** and choose repositories. The library shows issues, pull requests, and reviews you contributed to. [GitHub setup and sync](github-history.md) |
| Task board | Choose **New ticket** to add a card. Use **Search tickets** to find related work by title, notes, or saved citation. Right-click **Task board** in the sidebar and choose **Open in New Window** to browse it independently. Click a card to read it in a pane over the right side of the board. Drag its left edge to resize it, or choose **Open in separate window** to keep the ticket visible while you work elsewhere. Click a source to read the cited passage. Choose **Edit** to make changes in the pane. You can switch cards and return to your draft while the board is open. **Save** or **Cancel** takes you back to reading. You can also drag cards between columns and swimlanes. Enable board management in **Settings → Agent Access** to share ticket titles and notes. Agents see citations only from shared sources. [Board tools](mcp.md#task-board) |

The release ZIP runs on Apple Silicon with macOS 14.2 or later. The release guide covers first launch, including how to approve a downloaded copy in macOS. [Releases and installation](releases.md)

## Search

Select **All activity** to search across enabled sources, or select a sidebar row to narrow the results. Words match the beginnings of words in any order. For example, `bellam` finds *Bellamy*. Put a word or phrase in double quotes for an exact match. Search ignores case and accents.

For calls, the library searches titles, descriptions, participants, tags, current summaries, and the latest saved transcripts. Use **Search options → Search previous transcript versions** to include older transcripts. A speaker filter narrows results to that person's speech. Opening a result takes you to the matching content and transcript version. For private calls, search within **Recordings → Personal**.

Keyword search works immediately. **Settings → Search** can add semantic matches using a model that runs on your Mac. [Local semantic search](semantic-search.md)

## Import and read coding sessions

In **Settings → Coding**, select individual projects or select a parent folder to include its existing and future descendants. A dash means only some descendants are selected. Choose **Apply** to import in the background. Removing projects from the selection asks for confirmation before their saved sessions are removed. Disabling a provider leaves its imported conversations available in **Coding sessions** and search.

Afterword uses Lookback to read local Claude Code projects, active or archived Codex threads (including user forks), Pi v3 sessions, and Google Antigravity CLI transcripts under `~/.gemini/antigravity-cli`. Codex discovery uses `$CODEX_HOME` or, by default, `~/.codex`. If several local Codex accounts have chats, select the account in Coding settings. [Lookback](https://github.com/jbonatakis/lookback)

Enable **Import Pi sessions** in **Settings → Coding** and select the projects to import. Automatic discovery uses `~/.pi/agent/sessions` and respects `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` in the app’s environment. Use **Pi session folder → Choose…** for a custom or shell-only location. Changing the store or pausing Pi keeps previously imported sessions. The transcript shows original turns on the selected branch across compaction. Search can also open replies from abandoned branches in recorded history.

At launch the library loads the most recent 200 saved sessions. Scroll for older sessions. Search and the provider, project, and Git branch filters cover the full saved archive. Afterword checks for new sessions every minute while running and when you refresh the library. Imported sessions survive source-log rotation in `~/Library/Application Support/Afterword/CodingSessions/`.

**Conversation** follows the current conversation branch and preserves replies across Codex context compactions. **Recorded history** also shows superseded branches and earlier model context. Tool groups list actions in first-seen order. Expand a group for project-relative paths, search patterns, commands, short edit or script excerpts, and reported test results. Codex scripts also show command and file-change completions recorded while a single script was in flight. Local keyword searches open the matching call or completion in either view. Unknown tools retain their original names. Older sessions gain details the next time their source is available for import.

## Connect an agent

In **Settings → Agent Access**, enable access, choose permitted recording folders, and use **Copy Server Path** to configure a stdio client. Personal calls, coding sessions, GitHub repositories, and summary writes have separate grants. The bundled helper can serve saved library data while the app is closed. [MCP setup, permissions, and tools](mcp.md)

## Development

- [Build, sign, and test Afterword](development.md)
- [Capture, storage, and recovery architecture](ARCHITECTURE.md)
- [Search quality benchmark](search-quality.md)
- [Publish a release](releases.md)
