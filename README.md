# Afterword

A native SwiftUI recorder for macOS 14.2+ with a searchable recording library and menu-bar controls, built from [the recording specification, version 1.1](docs/spec-v1.1.md), with separate source tracks and selectable local transcription added. Each recording folder contains **Microphone.m4a** (selected mono mic, 64 kbps target), **System.m4a** (stereo playback, 128 kbps), and **Mixed.m4a** (stereo playback mix, 128 kbps). All use 48 kHz AAC-LC and share the same start and duration. Capture and transcription run locally, with no virtual audio driver or audio uploads. Transcription uses a bundled, pinned build of Handy's [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp).

Transcription prepares speaker groups and caches them on this Mac. When clips from previous calls match a voice, its name appears inline with a **Suggested** label. Click the label to confirm or change the name for the whole voice, or use **This passage only** for an exception. Copied transcripts mark suggestions explicitly. Older transcripts that already have cached speaker groups also show suggestions. For older calls without groups, open speaker review to prepare them. In the library, open **Transcript → Speakers…** to review voices from the system track. Play an example and choose a participant to label that voice throughout the call. **Save speaker labels** saves changed assignments in a transcript version. Reopening **Speakers…** shows the names saved for that version and the remembered owner of each example. **Remember this clip** stores a local voice embedding for future meetings with that person, and **Forget voice…** removes their saved examples. Suggestions use recordings from other calls and require agreement across multiple clips. Open **People & groups → Voice clips…** to play, reassign, or forget individual remembered samples. The waveform beside a person opens their clips. The **Transcript passages** tab shows their assigned speech across the latest transcripts in the library. Reassigning or unassigning a passage saves an edited transcript version. New word-timed transcripts can split a phrase at a speaker change. Older phrases with ambiguous timing stay unassigned unless they already had a name.

**Qualification status:** 157 core audio/export/recovery/transcription/speaker/library/calendar/MCP tests pass, along with native echo-stream checks. The signed MCP helper passes an official-client integration check. Local transcription is exercised against real models, including separate-track fixtures and silent intervals. Forced termination recovery preserves separate sources. The 16 kHz webcam passes short live capture/cleanup checks. Broader real-call source separation, endurance, and timing qualification remain outstanding; see [the test report](docs/TEST-REPORT.md).

## Choose your sources

On first launch, select **Recordings**, **Coding sessions**, **GitHub**, or any combination. With one source enabled, the library opens directly to that source. For coding sessions, choose Claude Code or Codex and your projects in **Settings → Coding**. For GitHub, connect your account and select repositories in **Settings → GitHub**.

Change these choices in **Settings → Sources**. Turning off Recordings releases the global shortcut, removes recording controls, and stops watching recording folders and calendars. Turning off Coding sessions or GitHub stops that import. Disabled sources are hidden from search and MCP. Re-enabling a source restores its saved history, settings, and sharing grants. Upgrading from an existing library keeps all three sources available.

## Build and run

With Apple's Command Line Tools (Swift 6.2+ and the macOS 26 SDK), Git, [uv](https://docs.astral.sh/uv/), and Python 3.12 available to uv:

```sh
cd /path/to/afterword
./Scripts/setup-local-signing.sh # One-time setup on this Mac
./Scripts/build-app.sh
open 'build/Afterword.app'
```

The first build downloads pinned transcription sources and CMake 3.31.6 into `build/`, then builds a native helper with embedded Metal shaders. Subsequent builds reuse this cache. The finished app needs no Python, uv, compiler, or network connection to transcribe with an installed model. The script signs the helper and app with the hardened runtime; only the app receives the audio-input and Calendar entitlements. It is outside App Sandbox. Quit a previous running build before opening a new one. Apple silicon is the tested transcription platform; Intel's CPU path has not been qualified.

The package, app target, executable, and Xcode scheme are **Afterword**; the stdio server is **AfterwordMCP**. App and helper bundle identifiers use `io.local.afterword`, and support/cache folders use `Afterword`.

When upgrading from the original Call Recorder identity, quit the app and stop its MCP helpers, then run `python3 Scripts/migrate-afterword-data.py` before opening the new build. This moves the support/cache directories and copies preferences into the new domain while preserving old preferences for rollback. Models, people, calendar selections, agent settings, and session recovery files carry forward; recording folders stay where they are. The script refuses to merge two existing data directories. Regrant macOS permissions when prompted and update the MCP command to `build/Afterword.app/Contents/Helpers/AfterwordMCP` at the repository's new location. Old executable paths are no longer installed.

The existing signing certificate is still named **Call Recorder Local Development**; its subject is a credential name, not the app identity. It is reused to avoid replacing the private key. One-time setup creates a dedicated self-signed certificate in your login keychain, with a non-extractable private key and automatic key access restricted to `/usr/bin/codesign`. Trust is limited to code signing in your user account. macOS may ask you to authorize the keychain change. The certificate is reused on subsequent runs and survives cleaning `build/`; setup will not replace an existing unavailable identity. Keep this certificate and key to preserve the app’s identity across updates.

If you already have an Apple Development or Developer ID identity, you can skip local setup and consistently select that certificate instead:

```sh
SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' ./Scripts/build-app.sh
```

The bundle ID is `io.local.afterword`; the helper uses `io.local.afterword.transcription`. The default designated requirements bind each identifier to the signing certificate, so subsequent builds can satisfy the identity recorded with earlier permission grants. This follows [Apple’s documented update-identity mechanism](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/). Moving from the old ad-hoc build to certificate signing can require one more round of permission approvals. Selecting a different certificate later can require approval again.

Production builds stop before replacing the app if the signing identity is missing, ambiguous, or explicitly set to `-`; there is no ad-hoc fallback. Helper and app signatures are verified before installation. To verify two different signed builds without launching them, run `python3 Scripts/check-signing.py '/path/to/Previous.app' '/path/to/Updated.app'`. It checks mutual identity compatibility and rejects an ad-hoc copy with the same bundle ID. No build or setup script edits TCC records or resets permissions. Local self-signing does not provide Developer ID distribution or notarization; distribution beyond this Mac needs that separate setup.

With Xcode 26 or newer, open `Afterword.xcodeproj` and choose the shared **Afterword** scheme, or run:

```sh
xcodebuild -project Afterword.xcodeproj -scheme Afterword \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/xcode build
xcodebuild -project Afterword.xcodeproj -scheme Afterword \
  -destination 'platform=macOS' -derivedDataPath build/xcode test
```

The checked-in native project has app, core framework, C library, and XCTest targets, and defaults to the same local signing certificate. Override `CODE_SIGN_IDENTITY` consistently if using an Apple-issued certificate. Regenerate the project after adding/removing source or test files with `python3 Scripts/generate-project.py`. The Swift package provides the command-line build without Xcode project tooling.

## Recording library (version 0.8)

The app opens a regular Mac window and appears in the Dock and app switcher. During a recording, the toolbar’s **Record** button shows a red stop icon, **Stop**, and the elapsed time. Click it to stop and save the call. The menu-bar recorder and your configured global shortcut remain available. Closing the library pauses playback and keeps Afterword running; use **Quit Afterword** to exit. Reopen the library from the Dock, **File → Show Library** (Command–1), or **Library** in the menu-bar panel.

- Recordings in the configured save folder appear automatically, including older single-file recordings. **Recording folders → Add recordings folder…** adds other folders in place; removing a folder from the library does not delete its files. The current recording destination remains included. Previous destinations remain available until removed.
- Turn on **Personal recording** in Recording controls before or during a personal call. The next recording defaults to Work. For an existing call, right-click its library row and choose **Mark as Personal** or **Move to Work**.
- **Recordings → Personal** has its own search and includes the call’s audio, transcript versions, and summaries. Work activity, search, and transcription and summary queues exclude personal calls. Existing recordings default to Work.
- To summarize a personal call, enable **Settings → Agent Access → Allow agents to access personal calls**, select its recording folder, and enable **Allow agents to save summaries**. Open the call’s **Summary** tab, click **Copy summary request**, and paste it into your connected agent. The request identifies the exact call and scope.
- **Recordings → Needs summary** lists transcribed calls awaiting their first summary. Select a call to open its Summary tab. Saving a summary in Afterword or through MCP removes it from this list.
- Search titles, descriptions, participants, tags, and the **latest saved transcript**. Words match together in any order and match word beginnings as you type: `bellam` finds `Bellamy` without a wildcard. Quotes require exact words or phrases (`"bellam"` will not match `Bellamy`); phrases can span paragraph boundaries. An explicit trailing `*` remains supported. Matching ignores case and accents. Results rank by relevance, with matching snippets and highlighted words. The **Search options** toolbar menu enables **Search previous transcript versions**; opening a history result selects its matching version. Search runs off the main thread after a short typing pause. Optional **Settings → Search → Semantic search** adds locally computed semantic matches. Search options also provides an exact current-speaker filter. Quoted phrases remain literal constraints; fuzzy spelling correction is not provided. See [local semantic search](docs/semantic-search.md) for model choices, indexing, and evaluation.
- The reader groups adjacent fragments into paragraphs with source labels and a timestamp per block. Wording and underlying segment times remain intact. **Copy** copies this readable layout; existing saved text and JSON files are untouched. Older transcript versions remain selectable, including a visible error when a version cannot be read.
- Click a paragraph timestamp to listen from that point, or use the player and seek slider. Switch between mixed, microphone, and system audio while keeping your place. Playback pauses and is disabled during recording, audio tests, and saving.
- **Transcribe / Transcribe again** uses the selected model and speaker-bleed setting from Settings. Each run still saves a separate transcript version. Progress and cancellation appear in the sidebar.
- Click the **pencil in a library row** or choose **Rename** from its context menu to edit its title in place. Return or the checkmark saves; Escape or the × cancels. **Edit details** lets you change the title, tags, and description. **Manage attendees…** opens the call’s attendance sheet. Titles are display names: audio paths and transcript associations stay stable. Details are stored atomically in `CallDetails.json` inside the call folder, or `<audio filename>.call.json` for older single-file calls. Unreadable or newer metadata is reported and cannot be overwritten by the editor.
- The **transcript pencil** or a paragraph’s pencil makes the reader editable inline, with playback still available. **Save** (Command–S) preserves the original, marks the new version as edited, and records its parent version. **Cancel** or **Escape** exits editing, asking for confirmation if the draft has unsaved changes. Saving or exiting inline editing returns keyboard focus to the call list. Drafts stay in memory when switching calls or closing the library window, and quitting with unsaved changes asks whether to discard them. Unchanged segments retain their exact timing; changed paragraphs retain their source and start/end interval, with segment-level timing. Clear a paragraph to omit it from the new version. Edited versions remain searchable and selectable alongside ASR output; edits do not alter audio.
- Open **Attendance… → Add attendee…** on any recording to search People & groups by name or email alias. Choosing an invitee who was excluded restores them as attended. Enter a new guest’s name and optional email to save a person or keep the guest on this call only. Personal calls default to call-only guests. **Link to person…** connects an existing guest and their transcript labels to a saved person. **Save attendance** applies these edits to Afterword.
- Adding a second attendee clears the one-person default across transcript versions and preserves explicit speaker assignments. Excluding someone clears their labels. When only one attendee remains, you can explicitly label unassigned speech with their name. Click a passage’s speaker label to choose a participant, restore its automatic name, or leave it as **Other participants**. The dropdown saves immediately in reading mode without opening text editing; the previous transcript version remains available. When a text-editing draft is already open, speaker choices stay in that draft until **Save**. Assignments apply per passage and survive text edits; “Recorder” and mixed-only audio keep their track labels. Names appear in search, copied transcripts, and newly saved text/JSON versions. Use **Speakers…** to review and assign the voices found during transcription.
- The call’s **…** menu and list context menu offer **Move to Trash** with confirmation. Call folders move as a unit; single-file calls move with their details and only their own associated transcript versions. A failed multi-item move attempts to restore items already moved. The transcript version’s **…** menu can move just that version to Trash. Capture/transcription must finish first. Files remain recoverable through the Mac’s Trash; folders containing unrelated files must be reviewed in Finder.

The library refreshes after recording/transcription saves and edits, when the app becomes active, and with the toolbar refresh button. Agent-saved summaries also update automatically while the library is open, including search results, without replacing unsaved editor drafts. It indexes direct recording folders and audio files inside the chosen locations, not arbitrary nested folder trees. It uses a rebuildable SQLite FTS5 search index shared in implementation with MCP; JSON files remain the source of truth. Agents can save summaries through MCP; speaker review and voice samples are managed in the app.

Search caches live privately in `~/Library/Caches/Afterword/Search`, separated by folder scope and access mode. They contain derived transcript text and saved snapshots. Refresh checks file identity, size, modification and change times, rereading only changed calls; unchanged MCP requests do not decode/hash the whole library. Deleting this cache while the app and MCP helpers are closed rebuilds it next time without touching recordings. A corrupt database rebuilds automatically. UI refresh can still show available folders if another is offline; MCP requires a complete scan before reporting changes.

Call-details schema 4 adds meeting references, identity-linked attendance, and explicit inference policy. It also stores current automatic defaults and manual-name corrections per transcript version. Renames and removals update the library, search, copied text, and future edited versions while leaving original transcript files intact. Schema 1–3 call details remain readable; old stuck automatic names use the current sole participant on load. Newly generated or edited transcripts with participant information use transcript schema 3; versions 1 and 2 remain readable. A manual name is stored separately from the audio source; an explicitly unassigned passage overrides the automatic default. Original transcript files are not rewritten when participants are added.

## Call summaries (version 0.15)

Each call has **Summary** and **Transcript** tabs. Write or edit a summary as Markdown, use **⌘S** to save and **Escape** to cancel (with confirmation for unsaved changes), and copy it as Markdown. Headings, lists, emphasis, links, code blocks, and simple tables render in the native reader. Saved summaries retain their previous versions in the version picker. A call with a summary opens on that tab; search results open the matching content.

**Settings → Agent Access → Allow agents to save summaries** enables the client-agnostic `save_call_summary` tool for the selected recording folders. This setting defaults off, including for existing MCP connections. Agents read the transcript and existing summary before supplying the call ID, current call revision, source transcript version, and complete Markdown. Concurrent changes reject the write without overwriting a newer summary; a native draft stays available to copy or revise. Reconnect your MCP client after updating to discover the new tool.

Summaries record the source transcript and resolved speakers. A newer transcript or changed speaker assignments flag the summary for review. Editing only the prose preserves that provenance; writing a new summary from the current transcript refreshes it. `get_call` returns the summary and its history. Current summary text participates in library and `list_calls` keyword search, labeled **Summary**; speaker-filtered search and `search_transcripts` continue to search speech. Semantic embeddings currently cover transcript passages. Previous summaries are available for reading/copying but are not included in search.

Summaries and history are stored atomically in `Summary.json` beside a call's audio (or `<audio filename>.summary.json` for single-file calls), with a private lock file coordinating native and agent edits. Summary text is limited to 65,536 characters and history to 16 MiB. They move to Trash with the call. Audio, transcript files, and call details are never changed by the summary tool.

## Library keyboard controls (version 0.11)

The **Call** and **Playback** menus list the shortcuts. **Help → Keyboard Shortcuts** opens a quick reference.

| Shortcut | Action |
|---|---|
| R | Rename the selected call inline; Return saves and Escape cancels. |
| Delete / Backspace | Move the selected call to Trash when the call list has focus. Return confirms the dialog; Escape cancels. |
| Space | Play or pause the selected recording. |
| Option–Left / Right | Seek backward or forward 10 seconds. |
| Command–F | Focus and select the library search text. |
| Command–I | Edit the selected call’s details. |
| E | Edit the displayed transcript, focusing its first paragraph. |
| Command–S | Save an inline rename or transcript edit. |
| Command–Shift–C | Copy the displayed saved transcript in its readable format. |
| Escape | Exit inline rename or transcript editing and return focus to the call list. Unsaved transcript changes require confirmation; Escape in that dialog keeps editing. |

Letter, deletion, and playback shortcuts leave text inputs alone and are inactive while a dialog or another window is focused. Playback remains disabled during capture and saving. Command–1 (library), Command–2 (upcoming calls), and the configurable global recording shortcut remain available.

The calendar and library fixtures render offscreen by default. Use `Scripts/check-library.sh --interactive` for live scrolling, window reopening, and keyboard focus checks that require a foreground window. Run `Scripts/check-library.sh Tests/LibraryKeyboardHarness.swift` for the dedicated foreground keyboard check. It uses generated silent audio, temporary preferences, and a uniquely named fixture for the Trash confirmation.

## Balanced listening volume (version 0.10)

**Balance voice volume in the saved mix** is on by default in **Settings → Recording**. New recordings measure the microphone and system tracks independently after capture, bring their active audio to similar levels, and apply gentle stereo-linked compression and peak protection to **Mixed.m4a**. The library plays that saved mix normally. There is no extra playback cache or migration of existing calls.

**Microphone.m4a** and **System.m4a** keep their original levels, sample counts, mute intervals, and timing. Transcription and speaker-bleed reduction continue using those separate tracks. The recording level meters also show the original input levels. Disabling balancing restores the original half-gain mix for subsequent recordings; the setting is checkpointed in the session so recovery uses the same choice. Sessions from older versions keep their original mix behavior.

The balance measurement uses gated 100 ms RMS windows and a percentile reference so pauses and isolated bumps do not determine the whole call's gain. Gain is fixed per source for the call, with a maximum 36 dB boost and a guard against boosting steady low-level noise. A soft-knee compressor reduces remaining phrase-to-phrase differences, followed by a stereo-linked peak limiter. This is a listening treatment, not voice isolation: boosting a very quiet microphone can also make its background noise or speaker bleed more audible. No live microphone gain, system volume, or meeting-app setting is changed.

## Calendar calls and attendance (version 0.9)

Open **Upcoming calls** in the library sidebar (or File → Upcoming Calls, Command–2). Choose **Connect macOS Calendar** and grant the Calendar permission. macOS calls this “full access”; Afterword only reads events and never saves changes to them. In **Settings → Calendar**, enable suggestions and choose calendars already synced through macOS. Start with your own calendar so your invitation status is available. Add your email aliases if they are not learned from invitations.

- **Settings → Calendar → Disconnect** stops calendar reads and monitoring, closes reminders, and clears upcoming events. It stays disconnected after relaunch, even while macOS permission remains granted. Saved calls, people, email aliases, and calendar selections are kept; choose **Connect macOS Calendar** to reconnect. Disabling suggestions only pauses suggestions. To revoke the macOS permission too, use **Open System Settings…**, then **Privacy & Security → Calendars → Afterword**.
- The next 48 hours of events with recognized HTTPS Google Meet, Zoom, or Teams meeting links appear in Upcoming calls. Event URL, location, and notes are checked. All-day, canceled, ended, and self-declined events are excluded. Copies from shared calendars are combined by external event ID and occurrence date, preferring your own invitation.
- A native reminder appears **one minute before** by default; choose start time, 30 seconds, 1, 2, or 5 minutes in Settings. Choose **Start recording**, **Join & record**, **In 1 minute**, or **Dismiss**. Join & record also opens the meeting URL in its registered app/browser. The event is refreshed before starting; stale or changed invitations require review. No recording starts automatically.
- Keep Afterword running; closing its windows is fine. Reminders do not run after Quit or while the Mac sleeps. The app refreshes on calendar changes, wake, and every minute. It skips reminders more than five minutes late, suppresses them during capture/testing/saving, and remembers dismissals and snoozes across launches. Rescheduled and recurring occurrences are handled separately. These are app windows, not Notification Center notifications.
- **People & groups** remembers identities by normalized email and supports preferred names, additional email aliases, and person/group/resource classification. Classifications you set override future calendar imports. A mailing list such as `list@example.test` should be marked **Group / mailing list**, even if Calendar reports it as a person. Optional rosters are chosen from known people; co-invited guests are never silently added as group members. Rooms/resources can be ignored. Profiles are stored locally in `~/Library/Application Support/Afterword/People.json` (0600 inside a private directory).
- Starting from a meeting snapshots its title, reference, and expected guests into the recording. Your own emails and resources are excluded. Group members are suggestions; explicit declined guests remain excluded. A known one-to-one invitation can label remote speech using the person's preferred name. Any unresolved group or unavailable guest list blocks that inference. For group calls, voice matching compares the detected speakers with remembered clips from active participants. Changing a preferred name updates matching speaker labels in existing transcript versions, copied text, search, and MCP. Explicit per-call names take precedence. Roster changes apply to future meetings.
- Click **Attendance…** beside a call's participant list. Mark people **Attended** or **Didn’t attend**, use bulk actions, and restore excluded people later. Excluded names disappear from speaker choices and their labels are cleared across transcript versions in the reader, search, and copied text. Original transcript files and all audio stay intact. The calendar event and saved identity are untouched. Restoring a person makes them available again without reviving cleared assignments.
- Attendance changes never silently hand cleared speech to the remaining person. After reviewing individual attendees, exclude any group placeholders. If one person remains, explicitly choose **Only [name] attended — label unassigned speech** to apply their name to unassigned passages in the selected transcript and future transcriptions. An already-open text draft retains Save/Cancel; otherwise this creates an edited transcript version. Add or rename individual people using **Edit details**.

Meeting metadata is checkpointed with the recording session and published atomically with its audio before automatic transcription starts. Recovery retains PCM when the meeting details or any audio track are missing. No cloud model, Google OAuth connection, directory lookup, or calendar write operation is used by the implementation.

## Use

1. Open the waveform icon in the menu bar. Read the recording notices.
2. Leave **System default** selected or choose a specific microphone. The resolved device is shown. For a multichannel/ambiguous source, explicitly choose one channel and verify it with **Test audio**. Only that channel is saved in the mono microphone track and centered in the stereo mix.
3. Press **Test audio** and grant the separate microphone and system-audio prompts. Speak and play audio in another app. Preview saves no audio and stops on panel dismissal or after 60 seconds. A permission dialog may dismiss the panel; reopen it and test again after granting access.
4. Press **Start recording**. The menu-bar icon changes when valid capture buffers arrive, even if they contain silence. Closing the popover leaves recording running.
5. **Record microphone** controls both the microphone track and playback mix. Turning it off zeros the selected microphone before queueing; the worker also enforces silence over the corresponding converted-frame interval. System audio continues, and silent portions remain in place so all tracks stay aligned. It does not mute your meeting app.
6. Press **Stop recording**. Wait for **Saved mix + separate tracks**, then use **Show in Finder**. A dated `Call-YYYY-MM-DD_HH-mm-ss` folder in your selected destination contains all three files. The default destination is `~/Music/Call Recordings`; folder collisions get numeric suffixes.

**Global shortcut:** press **Control–Option–Command–R** (⌃⌥⌘R) to start or stop from any app while Afterword is running. Change it in **Settings → Recording → Keyboard shortcut** by clicking the field and pressing a new combination. Clear the field to disable it, or use **Restore default shortcut**. Your choice persists across launches. The action happens once when the keys are released. During preparation it cancels; during an audio test it ends the test; while saving it does nothing. Recording still uses the selected microphone, destination, and normal permission checks. A shortcut registration conflict is shown in Settings and the recorder panel.

Shortcuts use a pinned, vendored [KeyboardShortcuts 3.1.0](https://github.com/sindresorhus/KeyboardShortcuts) with documented build adaptations in [Vendor/KeyboardShortcuts/UPSTREAM.md](Vendor/KeyboardShortcuts/UPSTREAM.md). The app does not request Accessibility or Input Monitoring permission for its hotkey. Run `./Scripts/check-shortcut.sh` for the isolated integration check; synthetic-key tests run only if event posting is already authorized and never capture audio.

System audio includes other apps and notifications. Meeting-app mute does not mute this recorder. Use headphones to avoid acoustic duplication, and get any required permission before recording. The app never plays back or monitors its capture.

For closed-lid use, select an external microphone such as the webcam. Apple silicon and T2 Mac laptops disconnect their built-in microphone in hardware when the lid closes; system audio can still be captured. Seeing the system meter move or recording music does not prove the microphone is working. Verify the **Microphone** meter while speaking. [Apple's hardware microphone disconnect documentation](https://support.apple.com/guide/security/hardware-microphone-disconnect-secbbd20b00b/web).

Settings have Recording and Transcription tabs. Sources/destination lock during a session. A missing explicit device never falls back silently. System default is resolved afresh for each session and frozen while active.

## Coding sessions

In **Settings → Coding**, enable Claude Code, Codex, or both. Expand the project tree to select individual projects, or check a folder to include its existing and future descendants from every enabled source. A dash marks a partially selected folder. Clear a child to exclude its subtree. Removing a folder from import also removes its saved sessions from Afterword after confirmation. Selections from earlier versions keep their exact-path scope until you change them.

Afterword checks for new sessions every minute while running and when you refresh the library. Pausing a source keeps its saved sessions available.

Afterword uses Lookback to read Claude Code’s local projects and Codex’s active and archived local threads. Codex discovery uses `$CODEX_HOME` when set and otherwise opens `~/.codex`. It includes top-level sessions and user forks. Afterword includes account-scoped chats automatically when it finds one local Codex account. If several accounts have chats on this Mac, choose one in Coding settings. Account discovery reads local thread headers. [Lookback](https://github.com/jbonatakis/lookback)

Open **Coding sessions** for an individual project conversation or **All activity** to search across calls, coding sessions, and imported GitHub contributions. The conversation view follows the current branch. Recorded history includes earlier branches and pre-compaction messages. Search results open at the matching message and select the relevant view. Project and Git branch filters are in Search options. Tool names are available in collapsed disclosures. Afterword omits tool arguments and result payloads from the archive.

The durable archive lives in `~/Library/Application Support/Afterword/CodingSessions`. It retains imported sessions when the source rotates or deletes local transcripts. Search works immediately with keywords. The optional semantic model indexes session titles and coding passages locally, with prompt and response context and the existing recording priority rules.

MCP clients can use **search_activity** across their allowed calls. Separately enable **Settings → Agent Access → Share imported coding sessions** to include imported projects and allow **get_coding_session**. Existing grants default to calls only.

## GitHub history

**Settings → GitHub** connects your GitHub.com account with a fine-grained personal access token or an existing GitHub App. The default token setup opens GitHub with read permissions preselected. Choose your resource owner and repositories on GitHub, paste the token into Afterword, then pick the repositories to import. The **GitHub** sidebar shows issues and pull requests you opened, commented on, or reviewed. Each timeline contains your own contributions with links to the originals. Search by text, qualified item number, contribution type, or date. Repositories have separate controls for local import and sharing through MCP. [Setup, search, and sync](docs/github-history.md)

## Agent access (MCP)

**Settings → Agent Access** enables a bundled local MCP server and selects the recording folders clients may read, with a separate opt-in for saving summaries. **Copy Server Path** supplies the stdio command; no client-specific setup is included. The server provides call listing, transcript search, saved call/version retrieval, and independent change checkpoints. It uses the library's current saved speaker assignments and edits, works while the app is closed, and rechecks access on every request. Access starts disabled. See the [MCP interface and behavior](docs/mcp.md).

## Transcription

1. Open **Settings → Transcription** and select a model. The selection persists across launches. Parakeet Unified (English), Nemotron 3.5 (multilingual), Whisper Base English, and Whisper Large v3 Turbo (multilingual) are available in Q8 precision. The UI shows each download size and links to its model card.
2. Compatible Handy/Hugging Face cached models appear as **Available on this Mac · shared** and are reused read-only. Otherwise choose **Download**. Downloads have progress, cancellation, and full size/SHA-256 verification before installation. Recorder-owned models live under `~/Library/Application Support/Afterword/Models/`; Remove never deletes Handy's files. A shared model's More menu can download a separate copy.
3. After saving a recording, expand **Transcription** in the menu panel and click **Transcribe recording**. The section starts collapsed. **Choose recording…** also accepts an existing call folder or audio file. Optional automatic transcription starts after a successful save, using an available selected model; it never initiates a model download.
4. **Reduce speaker bleed** is on by default in the panel and Settings. It uses the system track to reduce playback leaking into the microphone before transcription, with every model. Your original audio files stay intact. Turn it off to transcribe the original microphone signal; the choice persists across launches. The setting is frozen while a job runs. Mixed-only recordings remain supported and skip cleanup because they have no separate reference.
5. **Open transcript** opens the text. Each run saves `Transcript.txt` and `Transcript.json` together inside a new `Transcripts/<date>-<model>-<id>/` folder beside the audio, preserving earlier runs. The header reports cleanup on/off/unavailable. JSON includes model identity/hash, ASR and echo engine versions, cleanup setting and reference look-ahead, source filenames, timestamps, and timing granularity. A cleanup failure stops the job with an error; it never silently publishes an unprocessed transcript as cleaned.

The app transcribes **Microphone.m4a** as **Recorder** and **System.m4a** as **Other participants**, then merges by timestamp, preserving overlaps. A folder's playback mix is not transcribed again. The system track includes remote participants, other applications, and notifications. Speaker review uses this track to distinguish remote voices. Headphones reduce playback leaking into the mic track. Old mixed-only recordings are labeled **Mixed audio**, without invented speaker identities. A broken source pair is rejected rather than silently switching to its mix.

Audio processing runs in a separate, low-priority helper process with one model loaded at a time. Cancel leaves audio and previous transcripts untouched. Starting a recording/audio test cancels transcription to give capture priority. Audio is decoded into at most 30-second windows, preferring quiet cuts near their end; original sample offsets preserve silence and timing. Continuous speech across a window boundary may lose recognition context. Parakeet/Nemotron provide word-derived timing; this Whisper engine provides segment timing. These are model estimates, not guaranteed word alignment. Digital silence is skipped; background noise or music can still cause recognition errors. Models need substantially more RAM than the recorder itself, and first-run Metal shader compilation may take longer.

Cleanup uses the same pinned WebRTC AEC3 path validated in the sample-call experiment, bundled natively without Python. It runs continuously in 10 ms frames across ASR chunk boundaries, with 40 ms of system-reference look-ahead and zero padding only at the end. Microphone timestamps and sample count stay intact; the system track is transcribed unchanged. No added noise suppressor or automatic gain controller is enabled. This can reduce duplication substantially, but may affect quiet words or overlapping speech. A synthetic overlap check passes; varied rooms, devices, and real simultaneous speakers still need validation.

## Permissions

Microphone access uses the public `AVCaptureDevice` authorization flow. System-audio access follows the process-tap/aggregate start flow; no undocumented authorization preflight or speculative Screen Recording request is used. Zero audio samples are valid silence, not evidence of denial.

For microphone denial, open **System Settings → Privacy & Security → Microphone**. For system-audio access, open **Privacy & Security** and locate the screen/system-audio recording controls; Apple documents **Screen & System Audio Recording**, including audio-only access. Labels vary across supported macOS versions. The button opens System Settings itself, with text navigation as fallback, rather than relying on an unverified pane deep link. [Apple's system-audio permission instructions](https://support.apple.com/guide/mac-help/mchl2844ecab/mac).

No camera, Accessibility, contacts, automation, launch-at-login, or background-service permission is requested. Calendar access is requested when you connect calendars.

## Durability and recovery

Sessions live under `~/Library/Application Support/Afterword/Sessions/<UUID>/`. The worker writes independently finalized 10-second Float32 PCM CAF chunks with three discrete channels: selected mic, system left, system right. A single converter and chunk sequence keep all sources aligned. Files are fsynced and checkpointed with a version 2 manifest. The manifest includes source selection/UID/channel, reported formats and latency, wall-clock/timezone and capture timestamp references, mute intervals, chunk order/frame counts, errors, and finalization state. It does not contain window titles or meeting contents. Version 1 stereo chunks are still recoverable.

Export reads chunks sequentially with bounded audio buffers and writes the three AAC files into a hidden staging folder on the destination volume. Each is reopened to check codec/channel count/rate/duration and decoded at beginning/middle/end; decoded durations must agree within one sample. After all files are synced, the whole folder is published with an exclusive/no-overwrite rename. A failed track prevents partial delivery, and PCM remains for retry. Cleanup requires all three delivered files to exist. New private session and recording directories/files use 0700/0600 permissions. Existing destination-folder permissions are not changed.

After interruption, **Recover recording** reconciles completed files missed by a checkpoint and attempts to use a readable unfinished CAF. A missing/corrupt middle chunk exports only the uninterrupted prefix; later/original files remain for inspection. An undecodable current chunk is never discarded. Failed exports can be retried, including to the current Settings destination. All recoverable sessions are reachable in the popover.

At 48 kHz with three Float32 channels, PCM uses 576,000 bytes/second (about 2.07 GB/hour). The three AAC files target about 144 MB/hour combined. Start checks require 1 GB free on spool and destination volumes; active checks protect a 256 MB reserve. Export reserves space for all three estimated AAC files. Disk checks do not eliminate write errors. No encryption-at-rest or secure-deletion claim is made; another service may sync or back up your chosen folder.

Sleep/shutdown checkpoints and stops best-effort. Recording never resumes automatically. Quit asks to stop/save or cancel; if saving/device teardown stalls, explicit **Quit and recover later** leaves completed PCM available.

## Verification

```sh
./Scripts/test.sh
./Scripts/check-library.sh # Isolated library/editing/deletion UI, silent playback, and layout checks
./Scripts/check-echo.sh         # Native AEC streaming, silence, overlap and failure checks
./Scripts/run-crash-test.sh
./Scripts/check-layout.sh       # List available inputs; no capture
./Scripts/check-layout.sh 1     # Explicit input index; prepare/teardown only
```

`test.sh` uses XCTest when full Xcode is installed. With Command Line Tools only, it runs the **same test bodies** through a small assertion adapter. This machine lacks XCTest, so the adapter is included rather than skipping tests. AAC encoding needs access to Apple's local audio codec service; a restrictive development sandbox can return `fmt?` even for a valid encoder configuration. Run these commands normally in Terminal if that happens. The commands above do not capture live microphone/system audio.

The optional calendar feasibility probe is a separate signed app with its own normal macOS calendar permission prompt. It does not change events, launch meeting links, capture audio, or alter the production app. List calendar IDs first, then explicitly select calendars and event/attendee search terms:

```sh
./Scripts/check-calendar.sh --list --output "$PWD/build/calendar-spike/calendars.json"
./Scripts/check-calendar.sh --scan --calendar '<selected-calendar-id>' --match '<person or group>' --output "$PWD/build/calendar-spike/events.json"
```

The default scan covers the previous 7 and next 14 days; `--days-before`/`--days-after` can change that up to 31 days. Multiple `--calendar` and `--match` options are supported. The JSON report's `status` indicates success or a permission/read error. It includes matching event titles, dates, attendee names/emails/types, self-identification, and meeting-link hosts/fields. It omits event notes, join paths/tokens, and raw event identifiers. Reports are private files under Git-ignored `build/calendar-spike/`; do not commit them. This is diagnostic code, not the calendar integration or a qualified meeting-link parser.

After building the app, exercise the actual downloader and ASR worker with a copy of the engine's public speech sample:

```sh
mkdir -p build/asr-smoke
cp build/vendor/transcribe.cpp/samples/jfk.wav build/asr-smoke/Test.wav
./Scripts/check-transcription.sh download whisper-base.en build/asr-models
./Scripts/check-transcription.sh run whisper-base.en build/asr-models build/asr-smoke/Test.wav
./Scripts/check-transcription.sh cancel whisper-base.en build/asr-models build/asr-smoke/Test.wav
```

The first command that downloads a model uses the network; recognition is local. Transcripts appear under `build/asr-smoke/Transcripts/`. `cancel` stops the real helper after loading and verifies that the job reports cancellation. The test model directory is separate from the app's installed models.

For an explicit live check, `./Scripts/check-capture.sh --preview 0` runs three 3-second previews with the chosen device's first channel, using the production capture and conversion pipeline. It builds a diagnostic app with its own `io.local.afterword.capturecheck` identity, using the same persistent signing certificate and separate macOS permission grants. It processes microphone/system audio in memory and saves only numeric diagnostics to `build/capture-check.log`. It does not change the recorder's source preference, reuse its privacy identity, or persist audio. Do not use this check during a call; use **Test audio** to verify a chosen channel interactively.

The crash test SIGKILLs only its own synthetic fixture writer, then checks all three recovered AAC files, matching durations, microphone frequency ordering and isolation, and system stereo. Artifacts are retained under `build/crash-fixture-*` for inspection. This proves synthetic source-track recovery, not live-capture crash behavior.

See [architecture and implementation decisions](docs/ARCHITECTURE.md) and [test results / outstanding hardware checks](docs/TEST-REPORT.md).
