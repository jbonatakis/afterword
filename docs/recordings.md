# Recordings

## Record a call

Capture and transcription run on your Mac. If you save recordings in a folder managed by a sync or backup service, that service can copy them.

1. Open the waveform icon in the menu bar and read the recording notices. **Settings → Recording** lets you choose the save destination, microphone, and keyboard shortcut. If a device has multiple possible input channels, select one explicitly.
2. Choose **Test audio**. Grant microphone and system-audio access when macOS asks. Speak and play audio in another app, then check the two meters independently. The test keeps audio in memory and stops after 60 seconds or when you close the panel. Reopen the panel if a permission prompt dismisses it.
3. Start from the menu bar, the library's **Record** button, or the global shortcut **Control–Option–Command–R**. Closing the panel or library window leaves recording running. The **Record microphone** toggle silences your microphone track in Afterword while system capture continues. Your meeting app has its own mute control. System audio includes playback from other apps and notifications.
4. Choose **Stop** and wait for **Saved mix + separate tracks**. Use **Show in Finder** to open the dated `Call-YYYY-MM-DD_HH-mm-ss` folder. It holds three aligned 48 kHz AAC files.

| File | Contents |
| --- | --- |
| `Microphone.m4a` | Selected microphone channel, mono |
| `System.m4a` | System playback, stereo |
| `Mixed.m4a` | Stereo listening mix of both sources |

**Balance voice volume in the saved mix** is on by default. It adjusts each source's level during export and limits peaks in the mix. The separate tracks keep their input levels. The balance setting applies to subsequent recordings.

For closed-lid recording on a Mac laptop, choose an external microphone and check the microphone meter while speaking. Headphones reduce playback leaking into the microphone. Get any required permission from participants before recording. [Apple's hardware microphone disconnect guide](https://support.apple.com/guide/security/hardware-microphone-disconnect-secbbd20b00b/web)

To review denied permissions, open **System Settings → Privacy & Security → Microphone** or **Screen & System Audio Recording**. The system-audio pane's name varies with macOS. Calendar access is requested separately when you connect a calendar. [Apple's system-audio permission guide](https://support.apple.com/guide/mac-help/mchl2844ecab/mac)

## Manage the library

The save destination appears in the library automatically. To include an existing folder, go to **Settings → Recording → Library folders → Add recordings folder…**. Afterword indexes call folders and standalone audio files directly inside the selected locations. A folder's menu can reveal it in Finder or remove it from the library. Removing a folder leaves its files on disk. Previous destinations stay in the library until removed, and the active save destination stays included.

Use the pencil in a call row to rename its display title. **Edit details** changes the title, tags, or description. Details are saved in `CallDetails.json` in the call folder, or `<audio filename>.call.json` for standalone audio. **Move to Trash** on a call includes its audio and associated sidecars. Use the transcript version's own menu to trash just that version.

Turn on **Personal recording** in the recording controls for a personal call. The next recording defaults to Work. For an existing call, use **Mark as Personal** or **Move to Work** in its context menu. **Recordings → Personal** has its own search and includes the call's audio, transcripts, and summaries.

## Transcribe and review speech

Choose a model in **Settings → Transcription**. Parakeet Unified and Whisper Base English are English models. Nemotron 3.5 and Whisper Large v3 Turbo support multiple languages. The model picker shows download sizes and model cards. Afterword can reuse compatible Handy or Hugging Face caches read-only. Downloads are verified and installed under `~/Library/Application Support/Afterword/Models/`. Removing an Afterword copy leaves shared models in place.

Select a call and choose **Transcribe** or **Transcribe again**. The menu-bar panel also offers **Transcribe recording** and **Choose recording…**. Automatic transcription starts after saving when the selected model is available. Starting a recording or audio test cancels active transcription. Each completed run saves a new `Transcripts/<date>-<model>-<id>/` directory beside the audio with `Transcript.txt` and `Transcript.json`.

The transcript merges the separate tracks by timestamp. Microphone speech is labeled **You**, system speech initially appears as **Other participants**, and older mixed-only recordings use **Mixed audio**. **Reduce speaker bleed** uses the system track as a reference when transcribing the microphone. It is on by default. Turn it off to use the original microphone signal. The audio files stay intact with either setting.

Click a paragraph timestamp to listen from that point. Switch between the mix and the source tracks to hear either side at the same position. The pencil opens inline editing. **Save** creates a transcript version and keeps the original. Choose a speaker on a passage to save an assignment immediately, or include it with an open text draft. **Copy** uses the readable paragraphs and current speaker labels. The library keeps unsaved drafts while you switch calls or close the window.

Use **Transcript → Speakers…** to hear samples and assign remote voices to participants. **Remember this clip** saves a local voice embedding for future calls. A **Suggested** label can be confirmed for the voice or for a single passage. In the sidebar's **People & groups**, use **All voice clips…** for the full collection or select a person and choose **Voice clips…**. The **Transcript passages** tab shows assigned passages. Use **Forget voice…** in speaker review to remove remembered examples.

## Summaries

Open a call's **Summary** tab to write Markdown, save with **Command–S**, or copy a saved version. **Recordings → Needs summary** lists transcribed work calls awaiting a summary. Afterword flags a summary for review when its source transcript or speaker assignments change. Current summaries participate in keyword search. The version picker preserves earlier summaries.

To have a connected agent write a summary, enable **Settings → Agent Access → Allow agents to save summaries** for an allowed folder and choose **Copy summary request** on the call. For a personal call, also enable **Allow agents to access personal calls**. Summary text and history live in `Summary.json`, or `<audio filename>.summary.json` for a standalone recording. [Summary permissions, limits, and revision handling](mcp.md#saving-and-reading-summaries)

## Upcoming calls and attendance

Open **Upcoming calls** in the sidebar or press **Command–2**. Choose **Connect macOS Calendar** and grant Calendar access. In **Settings → Calendar**, enable reminders, select calendars, and enter any email aliases you use for invitations. Afterword reads the calendars already synced on your Mac. It leaves calendar events unchanged.

Upcoming calls covers the next 48 hours and recognizes Google Meet, Zoom, and Teams links in the event URL, location, or notes. It combines shared copies and skips all-day, canceled, ended, and self-declined events. While Afterword is running, a reminder offers **Start recording**, **Join & record**, snooze, or dismiss. The default lead time is one minute. **Disconnect** stops calendar reads and reminders and keeps saved calls and people. macOS Calendar permission can also be revoked in System Settings.

In **People & groups**, set preferred names, email aliases, and group rosters. Classify rooms as resources and mailing lists as groups. A recording started from a meeting saves its title and expected guests. A known one-to-one invitation can supply a remote speaker name. For a group call, review who actually attended before assigning speech.

Open **Attendance…** on a call to add a person, link a guest to a directory entry, or mark someone **Didn’t attend**. Excluded people are removed from speaker choices and their passage labels are cleared. Restoring attendance makes the person available for assignment again. If just one person attended, explicitly choose **Only [name] attended — label unassigned speech** to apply that name to unassigned passages. The original transcript files and audio stay intact.

## Storage and recovery

In-progress audio lives under `~/Library/Application Support/Afterword/Sessions/<UUID>/`. Ten-second PCM chunks use about 2.07 GB per recording hour. The three finished AAC files target about 144 MB per hour combined. Starting requires 1 GB free on both the session and destination volumes. During capture, Afterword checks for a 256 MB reserve.

After an interruption, open the menu-bar controls and choose **Recover recording**. If the original destination is unavailable, use the recovery item’s **More** menu. Choose **Export to selected destination** to use the current save folder, or **Choose export folder…** if you have not set one. Recovery uses the continuous readable prefix and retains uncertain chunks for inspection. Failed exports keep the PCM for retry. If saving stalls at quit, **Quit and recover later** leaves the completed chunks available on relaunch. [File format and recovery design](ARCHITECTURE.md#files-and-recovery)

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Command–1 / Command–2 | Show library activity / upcoming calls |
| Control–Option–Command–R | Start or stop recording globally. Change or clear it in **Settings → Recording**. |
| Command–F | Focus library search |
| R / Command–I | Rename the selected call / edit its details |
| Delete or Backspace | Move the selected call to Trash after confirmation, with focus in the call list |
| Space / Option–Left / Option–Right | Play or pause / back 10 seconds / forward 10 seconds |
| E / Command–S / Escape | Edit the transcript / save edits / cancel editing |
| Command–Shift–C | Copy the displayed saved transcript |

**Help → Keyboard Shortcuts** opens the in-app reference. Closing the library window pauses playback. The menu-bar recorder continues running until you quit Afterword.
