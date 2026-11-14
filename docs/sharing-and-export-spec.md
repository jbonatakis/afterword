# Call Recorder sharing and export specification

**Status:** Proposed

**Date:** November 14, 2026

**Platform:** macOS 14.2 and later

**Scope:** Share or save one call from the recording library.

Add a Share button that prepares a readable transcript, optionally includes the mixed recording, and hands the result to macOS sharing services. The same flow supports saving an export and copying text. It should work with the existing transcripts and participant assignments, without depending on the future notes pipeline.

## User flow

1. Select a call and, if needed, a particular transcript version.
2. Click **Share** beside the call’s title. The row context menu and **Call → Share…** open the same flow. Use **Command–Shift–E** as the keyboard shortcut and add it to the shortcut reference.
3. A compact sharing panel shows the call title, selected transcript version, export options, and a preview. The first-use default is a **PDF transcript**, with **Include recording** off.
4. Choose **Share…**, **Save…**, or **Copy text**. Share opens the native macOS picker for the prepared content; Save opens the appropriate native save dialog.
5. Choose the destination and finish in that app. Call Recorder does not select recipients or channels, infer recipients from calendar guests, or automate Send.

The native picker provides the available destinations for the actual payload. Mail, Messages, AirDrop, Notes, and third-party services depend on system configuration and supported content. Do not hard-code a list of supposedly available destinations. [Apple documents this filtering behavior](https://support.apple.com/en-ca/guide/mac-help/mh40614/mac).

The sharing panel remains the place to choose content. The system picker remains the place to choose a native destination. Preparing the export must not hide or recreate the library window.

## Export options

| Option | Behavior |
|---|---|
| Transcript | Included by default when the displayed version is readable. Can be deselected to share audio alone. |
| Format | **PDF** by default; **Markdown** and **Plain text** alternatives. Remember the last format. |
| Include recording | Off each time the panel opens. Adds the existing mixed audio file, with its size shown before sharing. |
| Timestamps | On by default, once per speaker paragraph. Remember this formatting preference. |
| Include description | Off each time. Available when the call has a description. Shows the included description in the preview. |

At least one available content item must be selected. If there is no readable transcript, offer audio sharing with a clear audio-only preview, but require the user to enable Include recording before sharing or saving. Disable Copy text when no transcript is selected. If mixed audio is missing, disable that option while allowing transcript sharing. Do not silently substitute the microphone or system track.

PDF and Markdown are shared as files. Plain text without audio is shared as inline text so it can become a message or email body; the receiving app controls its final presentation. Plain text with audio is shared as a `.txt` attachment alongside the audio. Saving or dragging plain text always creates a `.txt` file. **Copy text** copies the readable transcript only, regardless of the chosen document format; it never copies or attaches audio.

## Readable content

The exported document contains the current saved call title, recording date and time with a timezone, duration when available, active participant names, and the chosen transcript. Include the description only when selected. Omit empty header fields.

Use the reader’s paragraph grouping and current resolved speaker names. Participant renames, removals, attendance changes, single-person inference, and manual speaker assignments must agree with the library. Unknown remote speech remains **Other participants**. Render the microphone speaker as **Recorder** in exports so the recipient does not misread **You** as referring to themselves. An unidentified mixed source remains **Mixed audio**.

Each speaker heading is followed by a normal paragraph, with whitespace between turns. Timestamps are optional annotations, not separate lines for every recognition segment. Do not add local playback URLs or imply timestamps will play audio on another computer.

PDF requirements: selectable text, readable typography, wrapping for long paragraphs and names, multi-page pagination, page numbers, and speaker headings kept with the start of their paragraphs. Markdown and plain text use the same content and order. Escape Markdown control characters in user-entered headings and speaker names so they cannot change the document structure. Preserve transcript wording across all formats.

Do not add model/debug metadata, source paths, device identifiers, raw JSON, attendee emails, calendar event identifiers, join links, or the full meeting invitation to the exported header. Existing words in the transcript are not silently redacted or rewritten.

Suggested filenames use a sanitized call title and recording date, for example `Planning review 2026-11-14.pdf` and `Planning review 2026-11-14.m4a`. Preserve useful Unicode, remove path separators and control characters, bound filename length, and resolve collisions without modifying source files. Audio is copied without re-encoding or changing its gain.

## Transcript versions and unsaved edits

Sharing uses the version currently displayed, including an older manually selected version. Search matches must not cause the exporter to quietly choose a different transcript. Show the selected version’s date and edited status in the preview.

For a context-menu action on a different row, select that call and show its most recent readable version in the sharing panel. The preview identifies it before any handoff. Never export the previously selected call by mistake.

If this call has an unsaved title or changed transcript draft, offer three choices before preparing the preview:

- **Save and Continue:** use the existing save operations, then export the saved result. A validation or save error keeps the edits and stops the export.
- **Use Saved Version:** leave the draft intact and export its saved base version with the saved title. Identify that choice in the preview.
- **Cancel:** return to the editor without changing it.

An unchanged open editor needs no extra prompt. Drafts belonging to other calls do not block sharing this call. While a relevant edit is saving, wait for completion before taking the export snapshot.

Freeze the selected call, version, resolved names, and included metadata when preparing the preview. A new transcription, navigation change, or external edit must not silently change material already offered to a sharing service. Content changes require a fresh preview and payload.

## Slack support

The installed Slack 4.51.180 app has no bundled share extension or declared native services. Native Slack sharing therefore cannot be the only Slack path for this release. If a compatible Slack service becomes available, macOS can offer it in the native picker.

Provide these explicit alternatives in the sharing panel:

- **Copy text and open Slack**, when Slack is installed and a transcript is selected without audio. Copy the readable text, then open the installed Slack application. Display **Copied. Choose a channel or person in Slack and paste.** If opening Slack fails, leave the copied text available and explain that it can be pasted manually. This action does not post a message.
- A draggable file preview for PDF, Markdown, text-file, and audio exports. When more than one file is selected, dragging the preview supplies all selected files. This supports dropping attachments into a Slack conversation; **Save…** is also available for attaching them later. Slack documents adding files by dragging them into the message field and sending from the destination conversation. [Slack file-sharing instructions](https://slack.com/help/articles/201330736-Add-files-to-Slack).

Use the explicit copy-and-open label, rather than a generic **Send to Slack** button that implies direct delivery. Do not add Slack credentials, workspace/channel discovery, OAuth, or a network upload client for this release. Long text is never silently truncated; users can choose a file if a destination rejects an inline message.

## Native sharing and file lifetime

Use AppKit `NSSharingServicePicker` from the existing native library window. It supports text and file URL items, and file URLs share the file contents. Its delegate supports destination selection and service callbacks. Keep the standard service list authoritative and use the supported picker API rather than the deprecated service-enumeration method. [Apple picker documentation](https://developer.apple.com/documentation/appkit/nssharingservicepicker), [supported item types](https://developer.apple.com/documentation/appkit/nssharingservicepicker/init(items:)).

Prepare an immutable export snapshot, render it, and hand its payload to the sharing coordinator. Reuse `LibraryRecording.speakerLabel(for:version:)` and the existing participant-resolution rules. Pass the displayed version explicitly from the detail view; do not substitute `latestTranscript` inside the exporter. A small typed export model should carry the selected content and formatting options, with rendering separated from native UI.

The sharing coordinator owns the picker, delegates, payloads, and anchor for the whole operation. Generate files before enabling Share; keep the anchor alive while transferring from the options panel to the native picker. Cancel preparation safely if the user closes the panel. Large audio copies run off the main thread, with progress and cancellation, and must not interfere with recording.

Create snapshot files in a dedicated local cache directory, with a unique subdirectory per operation and private permissions. Hand off copies rather than original library files, so renaming, editing, or moving a call later does not change the shared payload. Do not delete files merely because the picker disappears: choosing a destination can dismiss it before the receiving app has finished reading. Retain files through service completion; retain interrupted handoffs across app exit. On startup, remove inactive export directories older than seven days. A cancelled operation with no handoff can be removed immediately. Active exports must not be swept.

For one saved file, use `NSSavePanel`. For transcript plus audio, let the user choose a destination folder and create a uniquely named subfolder containing the selected files. Reject destinations that would overwrite the call’s source audio, metadata, or transcript files. User-saved copies are not part of cache cleanup.

## Interaction and failure behavior

Sharing a completed call remains available while another call is recording. The active, unfinished recording is unavailable for export. Save/export work must not stop capture, trigger transcription, or alter gain settings.

Escape closes the current sharing UI without falling through to rename/transcript cancellation. On cancellation, restore the originating library focus; return to the editor when cancelling the unsaved-edit choice. Once the user switches to a destination app, do not reactivate Call Recorder to show a completion message. Block library letter and deletion shortcuts while a sharing panel or picker owns keyboard focus.

Report file-generation and handoff errors with a retry path that preserves the selected options. If a source disappears during preparation, stop and identify the missing item rather than silently exporting less content. Show selected file sizes; let the destination report its own attachment limits. Cancelling a picker or destination composer is not an error.

Use precise status messages: **Copied**, **Saved to…**, or **Opened in…** when those actions are known to have happened. A sharing-service callback does not establish that the recipient read or received a message. Do not show **Delivered** or maintain a misleading delivery history.

## Acceptance criteria

1. PDF, Markdown, and text contain the same chosen transcript, names, and included metadata, with readable paragraph layout. Inspect a long multi-page PDF, Unicode names, long titles, and an empty transcript.
2. Sharing an older selected version exports that version. Selecting Share on another row exports the intended call. Each unsaved-edit choice behaves as specified, including failed saves and drafts on other calls.
3. Participant rename/removal, attendance exclusions, automatic single-person assignment, and explicit unassigned passages match the reader. Microphone speech is labeled Recorder in exported content.
4. Audio is off on each new sharing flow. Audio-only and combined exports work, preserve source bytes, and never substitute a separate track when the mix is unavailable.
5. On a configured Mac, the native picker offers compatible services for text, a PDF, and PDF plus audio. Validate Mail and Messages attachment/composer behavior where available; mark unavailable services accurately. Specifying these destinations does not imply they are configured on every Mac.
6. Slack copy-and-open preserves the full text and does not send. Dragging the prepared files into a Slack composer attaches the intended files; the user chooses the conversation and sends. No real messages are sent during automated verification.
7. Cancellation, destination failure, app quit/reopen, and slow attachment reads do not prematurely remove files. Cache cleanup touches only expired inactive export directories. Source files remain unchanged.
8. Repeated Share → Escape → keyboard navigation works without tests forcibly reactivating or refocusing the app between keys. Sharing does not recreate the library window or interrupt a recording.
9. Export preparation and saving work offline. Any network use belongs to the explicitly chosen destination app; Call Recorder adds no upload service or new account connection.

## Follow-up scope

Notes and highlighted passages can become optional content blocks when those features exist. Bulk export, raw JSON packages, separate source-track export, audio excerpts, hosted share links, and direct Slack posting are separate follow-ups. No empty notes section or unavailable notes control appears in this release.
