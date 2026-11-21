# Implementation decisions

## Editable call summaries

`CallSummaryStore` owns one JSON document per call containing current Markdown and immutable previous versions. Native edits and `save_call_summary` use the same file lock, re-read the saved call, and reject a mismatched content revision. Publication uses a private temporary file and directory-relative atomic rename; symlink paths are rejected and MCP access is rechecked before publication. The app keeps failed drafts available instead of replacing them during refresh. Summary files and locks are included in whole-call Trash operations, including legacy single-file recordings.

Each summary records its source transcript run and a fingerprint of the transcript plus resolved speaker labels. The reader flags a changed/latest-missing source. Native prose edits preserve that provenance; the MCP tool requires an explicit source transcript version. Summaries are rendered with native SwiftUI text for common Markdown blocks, without loading HTML or remote resources. The Summary and Transcript tabs share playback and call information; saved history remains readable and copyable.

The FTS5 cache indexes current summary text in a separate column. Library search and `list_calls` label summary matches. Speaker-filtered and transcript-only searches look at speech. Saved summary changes participate in call revisions and durable change checkpoints. Summary writes require a separate, default-off MCP grant.

`LibrarySummaryMonitor` uses one recursive FSEvents stream for the library roots, filtering for `Summary.json` and legacy `.summary.json` files. Creation, atomic replacement, and deletion refresh the native library and current search without requiring app activation or a new MCP connection. Bursts are debounced; changes arriving during a scan or local save remain pending until it finishes. Dropped/root-change events request a rescan, changing the folder list replaces the watched roots, and shutdown stops the stream. In-memory summary/transcript drafts remain separate from refreshed saved snapshots and retain their optimistic save-conflict checks.

## Native recording library

A retained `NSWindowController` hosts the SwiftUI library. A `NavigationSplitView` provides the sidebar, and an `HSplitView` holds the activity list and selected item. Upcoming calls and People & groups open in the same window. The activity panes stay mounted, and the window controller restores native scroll positions after the columns return to their reading dimensions. The app delegate owns capture independently of window visibility. Closing the library pauses playback, and reopening from the Dock, File menu, or popover presents the same window.

The library scans split-track call folders and standalone audio on a utility task. It skips hidden staging directories, canonicalizes paths, and associates shared legacy transcript folders by recording name. The model checks a generation token before publishing results so a superseded scan cannot replace a newer one. The selected recording and additional source folders persist in preferences.

The rebuildable SQLite search index lives under `~/Library/Caches/Afterword/Search/`, scoped by folders and access mode. It stores derived text and snapshots. Refresh compares file identity, size, and timestamps before rereading a call. Closing the app and MCP helpers and deleting the cache triggers a rebuild on next use. Source audio, call details, transcript versions, and summaries live outside this cache.

`TranscriptParagraph` groups consecutive same-source segments, splitting at source changes, pauses over three seconds, and paragraph duration or length limits (45 seconds or 650 characters). An individual long segment remains intact. Search can match phrases across adjacent fragments and defaults to the latest saved transcript. A history result identifies its source version and passage.

`RecordingPlayback` uses one `AVAudioPlayer` and a lightweight position timer. Switching tracks preserves position and playback intent. The recorder-state subscription pauses playback and prevents restarting it while preparing, capturing, testing, or finalizing. Window closure pauses only playback. Paragraph timestamps seek on the selected track; no source gain, capture configuration, or original audio is changed.

## Persistent native popover

Enabling Recordings creates an `NSStatusItem` with a transient `NSPopover`. A single `NSHostingController<RecorderView>` stays attached as the content changes. Preferred-content sizing and disabled popover animation keep resizing synchronous with the controls.

`RecorderView` uses `ViewThatFits` to switch between natural-height content and a scrolling layout on smaller screens. The transcription expansion binding lives above both layouts so resizing preserves its state.

The transient popover closes on outside interaction. Its close delegate calls the existing preview-only `panelClosed()` path; ordinary recording continues. Settings remains the SwiftUI Settings scene, and its link works from the native host. Status text/image updates subscribe to the same coordinator, while app termination retains its normal stop/save confirmation and helper shutdown.

## Global recording shortcut

The recording source owns the global `toggleCallRecording` shortcut. Enabling the source registers the saved combination. Disabling it releases the registration. The default is Control–Option–Command–R. The recorder control in Settings suspends delivery during reassignment and persists an explicitly cleared shortcut.

The key-up callback invokes the same `RecordingCoordinator.start()`/`stop()` methods as the buttons, selected through `RecordingState.toggleAction`. Idle/error/permission/recovery states start; preparation/capture/preview states stop; finalization ignores the shortcut. Key-down repeats do not toggle recording. Device selection, capture permissions, export, transcription priority, and automatic transcription retain their existing behavior. The app delegate owns the coordinator from launch, including before the popover opens.

The Swift package and Xcode project share the vendored KeyboardShortcuts library. Its upstream revision, license, and build adaptations are recorded with the source. [KeyboardShortcuts provenance](../Vendor/KeyboardShortcuts/UPSTREAM.md)

## Speaker bleed reduction

Speaker bleed reduction is enabled by default. The persisted `reduceSpeakerBleed` preference returns true only when absent or explicitly true; a saved false is respected. Both UI entry points edit the same setting, disabled during a job. The coordinator freezes its value when starting either a manual or automatic transcription.

`EchoStream` statically links WebRTC AEC3 from pywebrtc-audio. The stream converts samples to FloatS16 scale for render and capture analysis, high-pass filtering, and echo cancellation, then returns normalized Float32.

The worker reads the microphone as 16 kHz mono and the reference as 16 kHz stereo, averages reference channels, and advances only the reference by 640 samples (40 ms). A single AEC instance processes chronological 160-sample frames across all 30-second ASR windows. A small pending-output buffer bridges arbitrary decoder/ASR read sizes. The final frame is padded for DSP and truncated back to the actual microphone length. Duration mismatch, truncated input, nonfinite samples and cancellation fail explicitly. Reference look-ahead is a processing allowance, not a measurement of hardware latency or an automatic alignment guarantee.

The original M4A files are opened read-only; cleanup uses bounded in-memory buffers. System ASR reads the original system file afresh. Mixed-only inputs mark cleanup unavailable. The worker must explicitly confirm whether cleanup was applied and return engine/sample-rate/look-ahead metadata; missing/mismatched confirmation prevents publication. Transcript schema 2 stores this evidence and exposes the state in its text header. Optional fields retain decoding compatibility with schema 1. Cleanup failures never fall back silently. Cancellation continues to own and terminate just the transcription helper.

## Selectable local transcription

The transcription helper is a separate Objective-C++ executable linked with transcribe.cpp, its pinned GGML submodule, Apple Accelerate, and embedded Metal shaders. The build packages a separate speaker-analysis worker and Core ML models. Speech recognition model weights are installed or discovered at runtime. [Transcription engine](https://github.com/handy-computer/transcribe.cpp) · [Speaker model provenance](../NativeDiarization/MODEL-CARD.md)

`SpeechModel` is a curated catalog with immutable Hugging Face revisions, sizes, filenames, and SHA-256 hashes. `ModelStore` discovers recorder-owned files and compatible Handy/HF caches (including symlinks to HF blobs). Shared files are never deleted or changed. Selection and optional auto-transcription persist in UserDefaults. Downloads use cancellable URLSession tasks, ephemeral sessions, HTTPS, private staging files, streaming SHA-256 verification, fsync, and atomic installation. A failed download never replaces an installed model. Every transcription verifies the chosen file before launching native code; network access is unnecessary after download.

`TranscriptionJob` validates the input, launches exactly one owned worker, reads JSON-lines progress/results, checks returned source identities/durations/timestamps, and publishes only after a successful exit and explicit completion event. Cancellation sends SIGTERM and then, if needed after three seconds, SIGKILL only to the still-running owned process. Model-loading and inference failures leave audio and prior transcripts untouched. A new recording or audio preview cancels transcription; the UI does not start another worker until cleanup completes. Quit cancels owned jobs/downloads after the normal recording-save decision.

The helper uses ExtAudioFile to decode mono/stereo M4A to 16 kHz Float32 mono, holding at most 30 seconds of PCM. It prefers a low-energy cut between 24 and 30 seconds, carries the remaining samples to the next decode, and offsets results by the exact number of consumed samples. No samples or leading/middle silence are removed from the timeline. Near-digital-silence windows are skipped; this is not a learned speech detector. Continuous speech across a window boundary can lose language context. Parakeet/Nemotron words are grouped into phrases; Whisper's available segment timestamps are preserved. Unsupported/absent finer timestamps are never invented: the JSON records word, segment, or chunk granularity.

Separate microphone and system inputs are transcribed independently. Results are merged by timestamp, retaining overlaps. A missing or mismatched source pair is an error. A standalone mixed recording is labeled Mixed audio. The speaker worker groups voices from the system track for review and comparison with remembered clips. Each completed transcription publishes a private text/JSON pair to a new directory under `Transcripts/`. The JSON records the model, hash, engine, sources, language policy, and segment timing.

First-load shader compilation can take time, and model inference uses memory in addition to the recorder. A cancelled or interrupted transcription can be run again from the saved audio.

## Separate tracks

New sessions preserve the selected mono microphone and stereo system playback. Export writes `Microphone.m4a`, `System.m4a`, and `Mixed.m4a` together. Voice balancing is enabled by default for the mix. Export measures the sources separately, applies bounded gain, stereo-linked compression, and peak limiting, and preserves the source files at their original levels. Disabling balancing selects the half-gain mix. Recovery uses the mix setting captured with the session. Version 1 sessions recover as mixed-only audio.

## Native capture and availability

The macOS 14.2 deployment target follows the availability of the Core Audio process tap API. Build tools and SDK requirements are documented in the [development guide](development.md).

The only capture backend is a private, unmuted global stereo process tap excluding the recorder's **Core Audio process object**, combined with the selected input in a private ordinary aggregate. No default-device, physical-device sample-rate, output-volume, exclusive-access, or meeting-app setting is written.

The microphone UID is the explicit main clock. Its subdevice drift correction is off; the tap's correction is on. Preparation checks the active subdevice/main clock and the aggregate's accepted tap composition. A subtap object can be unavailable before IO on the tested OS, so the implementation does not require querying its `drft` property before starting. This configuration is not proof of measured alignment: initial offset and two-hour drift remain hardware acceptance gates.

### Aggregate layout and sample rates

On macOS 15.8.1, `IsStacked` changed which input buffers the aggregate exposed for a mono built-in microphone.

| Composition | Active mic | Aggregate input buffers |
|---|---|---|
| `IsStacked = true` | absent | `[2]` (tap only) |
| `IsStacked = false` | present | `[1, 2]` (mic + tap) |

The recorder uses `IsStacked = false` and checks the actual composition and channel coverage before capture.

The aggregate's ordered subdevice UID list and current source channel count determine source spans. Its stream starting-channel properties, complete non-overlapping coverage, packed Float32 frame format, supported rates, and AudioBufferList configuration are then validated. The callback's buffer/channel references are derived from that runtime layout; there is no model, manufacturer, name, or fixed-channel-count mapping.

A 16 kHz microphone can supply the aggregate clock while the tap's stream metadata still reports 48 kHz. On this configuration the HAL delivers both inputs on the aggregate timeline. Resampling the tap at its metadata rate would convert it twice. The worker converts the three channels together from the aggregate rate to 48 kHz and checks equal buffer lengths and timestamp continuity. Diagnostics preserve both the source rates and the aggregate IO rate.

Register the IOProc immediately before `AudioDeviceStart`, after other fallible preparation. Cancelling preparation then has no registered IO context to tear down. Native calls can block, so the UI offers quit and recovery if saving stalls.

## Threading and timeline

`RecordingCoordinator` is main-actor isolated and owns the lifecycle. `RecordingEngine` serializes audio control, processing, file IO, and export on one dedicated queue. Property callbacks are delivered to that queue. Default input changes while idle update the catalog; active sessions retain their resolved input. Output-route changes conservatively stop/save partial audio.

The C IOProc is allocation-, disk-, logging-, task-, and lock-free. It copies only selected mono microphone and two tap channels into a preallocated single-producer/single-consumer ring. Microphone enable is atomic and applies before those samples enter the queue. A short non-real-time lock protects ring-pointer lifetime during UI toggles; the callback never takes it. Output IOProc streams are disabled; no monitoring/output data is produced.

The ring contains 64 slots, each up to 8,192 frames × 3 Float32 channels (~6 MiB). Overflow or malformed layout latches a failure with first discontinuity sample time and dropped-frame counts. No queue growth or silent drop policy is used. Maximum queued audio is `64 × 8192 / sourceRate` seconds; actual callback sizes are generally smaller. An interrupted recording may lose the unfinished 10-second chunk plus queued frames.

A worker timer runs only while capture is active, at 10 ms with 2 ms leeway. UI levels are published at ~10 Hz. The audio timeline comes from input sample timestamps and frame counts, never UI timers. Timestamp gaps/overlaps stop the recording at the valid prefix instead of silently removing or duplicating time. Host timestamps, source formats, and reported device/stream latency are recorded; no unmeasured manual latency shift is applied.

The worker clamps invalid/out-of-range input safely, counts clipping/nonfinite samples, and meters each source. One `AVAudioConverter` continuously converts three discrete source channels to 48 kHz using its input-callback API and an identity channel map. An explicit `DiscreteInOrder` channel layout is required; the channels must not be interpreted as a surround layout or downmixed. Silence is written normally. Mic enable changes are enforced before queueing, then again at their converted-frame positions so converter tails cannot enter a muted interval. Export derives the listening mix from the preserved source channels.

## Files and recovery

PCM files are interleaved on disk, with planar Float32 worker buffers. Version 2 fixes channel order as microphone, system left, system right. A single three-channel chunk carries the sources through exactly the same write/checkpoint/recovery boundary, avoiding independently truncated source files. Version 1 requires two mixed channels. Complete chunks are closed, synced, renamed, then checkpointed. Recovery trusts neither manifest paths nor chunk ordering blindly: it bounds manifest size/counts, checks version/session identity, rejects traversal/symlinks, verifies channel count/format/frame counts, and reconciles sequential files. It never concatenates across an unknown gap. Uncertain tails and unexpected additional files are retained after prefix delivery.

Export uses bounded 32,768-frame reads and an independent AAC writer per output. The mic is mono at a 64 kbps target; system audio and mix are stereo at 128 kbps each. All writers begin at source frame zero and consume the same chunk prefix, preserving initial silence and mute intervals. M4A validation uses the decoder's frame count (which accounts for priming/padding metadata), a 4,800-frame/100 ms tolerance against PCM, channel/rate checks, and sample reads at three positions. All three decoded durations must also match within one sample. The validated/synced staging folder is published with one `RENAME_EXCL` rename. A failing encoder leaves no visible partial set and retains PCM for retry. Cleanup requires every expected track, a recorded delivered path, and a known session directory. A delivered session with a missing track can be re-exported from retained PCM without overwriting surviving files. Legacy sessions retain their original single-M4A export behavior.

## References

- [Apple Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple sample-rate conversion technical note](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)
- [Audio input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)
- Installed `AudioHardware.h`, `AudioHardwareBase.h`, `AudioHardwareTapping.h`, and `CATapDescription.h` in the macOS 14.5 and 26.2 SDKs.
