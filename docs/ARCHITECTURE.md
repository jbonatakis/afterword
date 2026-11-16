# Implementation decisions

## Editable call summaries (version 0.15)

`CallSummaryStore` owns one JSON document per call containing current Markdown and immutable previous versions. Native edits and `save_call_summary` use the same file lock, re-read the saved call, and reject a mismatched content revision. Publication uses a private temporary file and directory-relative atomic rename; symlink paths are rejected and MCP access is rechecked before publication. The app keeps failed drafts available instead of replacing them during refresh. Summary files and locks are included in whole-call Trash operations, including legacy single-file recordings.

Each summary records its source transcript run and a fingerprint of the transcript plus resolved speaker labels. The reader flags a changed/latest-missing source. Native prose edits preserve that provenance; the MCP tool requires an explicit source transcript version. Summaries are rendered with native SwiftUI text for common Markdown blocks, without loading HTML or remote resources. The Summary and Transcript tabs share playback and call information; saved history remains readable and copyable.

The FTS5 cache uses a new v2 filename and a separate summary column. Current summaries contribute to library and `list_calls` keyword results, with explicit summary evidence; transcript-only and speaker-filtered searches exclude that field. Historical summaries are not searched, and semantic chunks remain transcript passages. Saved summary changes participate in call revisions and durable change checkpoints. MCP tools remain client-agnostic; summary writes require a separate default-off capability in the existing allowed-folder configuration.

`LibrarySummaryMonitor` uses one recursive FSEvents stream for the library roots, filtering for `Summary.json` and legacy `.summary.json` files. Creation, atomic replacement, and deletion refresh the native library and current search without requiring app activation or a new MCP connection. Bursts are debounced; changes arriving during a scan or local save remain pending until it finishes. Dropped/root-change events request a rescan, changing the folder list replaces the watched roots, and shutdown stops the stream. In-memory summary/transcript drafts remain separate from refreshed saved snapshots and retain their optimistic save-conflict checks.

## Native recording library (version 0.6)

A retained `NSWindowController` hosts the three-column SwiftUI `NavigationSplitView`, with SwiftUI providing its toolbar and search field. The app is a regular Dock application; Settings remains a SwiftUI scene. The app delegate owns the recorder, library model, playback model, main window controller, and native status item independently of window visibility. Closing the window pauses review playback without touching capture. Dock reopen, the File menu, and the popover's Library button present the same window, including deminiaturizing and activating it. Window geometry is autosaved explicitly; scene restoration is not responsible for main-window lifetime. App termination keeps the existing stop/save confirmation.

`RecordingLibraryScanner` reads saved deliveries on a utility task. It supports split-track folders and legacy standalone audio, skips hidden staging directories, canonicalizes paths to avoid duplicate entries, and associates shared legacy transcript folders by recording name. All transcript versions remain available. Invalid JSON/version/timing produces a visible version error instead of silently replacing it with an older run. Scanning never changes source files. The model cancels superseded scans and checks a generation token before publishing results; save/transcript/destination notifications, app activation, and explicit refresh trigger scanning. Selected recording and additional source folders persist in app preferences. This initial index is in memory and has not been qualified for very large archives.

`TranscriptParagraph` forms reading blocks from consecutive same-source segments, splitting at source changes, pauses over three seconds, and paragraph duration/length limits (45 seconds / 650 characters). An individual long segment remains intact. Overlapping segments and their original timings are preserved. This is presentation formatting, not an LLM rewrite or individual remote diarization. Search covers all versions and uses these paragraphs so phrases spanning adjacent fragments remain searchable. Copy exports readable paragraphs while existing timestamped exports stay unchanged.

`RecordingPlayback` uses one `AVAudioPlayer` and a lightweight position timer. Switching tracks preserves position and playback intent. The recorder-state subscription pauses playback and prevents restarting it while preparing, capturing, testing, or finalizing. Window closure pauses only playback. Paragraph timestamps seek on the selected track; no source gain, capture configuration, or original audio is changed.

## Persistent native popover (version 0.5.4)

The app delegate owns the recording coordinator and a native `NSStatusItem`/`NSPopover` from launch. A single `NSHostingController<RecorderView>` stays attached to the popover as its contents change. `sizingOptions = [.preferredContentSize]` and `popover.animates = false` allow direct content-size updates without the SwiftUI `MenuBarExtra` window's resize/redraw behavior.

`RecorderView` uses `ViewThatFits` to choose natural-height content or a scrolling fallback under the screen-height cap. It no longer measures geometry into a separate height state. The transcription expansion binding lives above these alternatives so switching to scrolling does not reset it. The default is collapsed; changes remain nonanimated to match the native popover.

The transient popover closes on outside interaction. Its close delegate calls the existing preview-only `panelClosed()` path; ordinary recording continues. Settings remains the SwiftUI Settings scene, and its link works from the native host. Status text/image updates subscribe to the same coordinator, while app termination retains its normal stop/save confirmation and helper shutdown.

## Global recording shortcut (version 0.5)

`RecordingShortcut` registers the persisted `toggleCallRecording` name during coordinator initialization. The initial combination is Control–Option–Command–R; an explicit clear remains disabled on later launches. The native recorder control in Recording settings edits the same name, suspends hotkey delivery while assigning a combination, handles menu/system conflicts, and supports clearing/restoring. Failed global registration is visible in both Settings and the recorder panel.

The key-up callback invokes the same `RecordingCoordinator.start()`/`stop()` methods as the buttons, selected through `RecordingState.toggleAction`. Idle/error/permission/recovery states start; preparation/capture/preview states stop; finalization ignores the shortcut. Key-down repeats do not toggle recording. Device selection, capture permissions, export, transcription priority, and automatic transcription retain their existing behavior. The app delegate owns the coordinator from launch, including before the popover opens.

KeyboardShortcuts 3.1.0 is vendored at commit `772133d9dbe800fdac0473226822994c5c162c58` with its MIT license and upstream tests. Build adaptations replace an Xcode-only environment macro with equivalent code, gate design-time previews, and resolve the SwiftPM localization bundle from the signed app's Resources directory. These are documented in `Vendor/KeyboardShortcuts/UPSTREAM.md`. Both SwiftPM and the generated Xcode project use this same local package. Building requires Swift 6.2 and the macOS 26 SDK; the app's deployment target remains macOS 14.2.

## Speaker bleed reduction (version 0.4)

Speaker bleed reduction is enabled by default. The persisted `reduceSpeakerBleed` preference returns true only when absent or explicitly true; a saved false is respected. Both UI entry points edit the same setting, disabled during a job. The coordinator freezes its value when starting either a manual or automatic transcription.

`EchoStream` statically links the WebRTC AEC3 sources from pywebrtc-audio 0.2.0 at `1bc860a2051c2b9b3c10b8c778770794b9321d84`. Its DSP sequence follows the experiment's AudioProcessor: FloatS16 scaling, render/capture analysis, high-pass filtering, AEC, and conversion back to normalized Float32. No Python runtime, additional model, noise suppression, gain controller, or audio-device route is involved. The native stream's output matched the Python experiment sample-for-sample when fed the same decoded call PCM.

The worker reads the microphone as 16 kHz mono and the reference as 16 kHz stereo, averages reference channels, and advances only the reference by 640 samples (40 ms). A single AEC instance processes chronological 160-sample frames across all 30-second ASR windows. A small pending-output buffer bridges arbitrary decoder/ASR read sizes. The final frame is padded for DSP and truncated back to the actual microphone length. Duration mismatch, truncated input, nonfinite samples and cancellation fail explicitly. Reference look-ahead is a processing allowance, not a measurement of hardware latency or an automatic alignment guarantee.

The original M4A files are opened read-only; cleanup uses bounded in-memory buffers. System ASR reads the original system file afresh. Mixed-only inputs mark cleanup unavailable. The worker must explicitly confirm whether cleanup was applied and return engine/sample-rate/look-ahead metadata; missing/mismatched confirmation prevents publication. Transcript schema 2 stores this evidence and exposes the state in its text header. Optional fields retain decoding compatibility with schema 1. Cleanup failures never fall back silently. Cancellation continues to own and terminate just the transcription helper.

## Selectable local transcription (version 0.3)

Local model selection is optional. Recording and its real-time callback remain independent of the ASR implementation. A separate Objective-C++ executable statically links `transcribe.cpp` 0.4.2 at `275cd50d2c4104c204009a197ac091b9687668e5`, with its pinned GGML submodule, Apple Accelerate, and embedded Metal shader sources. No external dynamic libraries, runtime Python, or model weights are bundled. The helper and third-party licenses are copied/signed by both app build routes.

`SpeechModel` is a curated catalog with immutable Hugging Face revisions, sizes, filenames, and SHA-256 hashes. `ModelStore` discovers recorder-owned files and compatible Handy/HF caches (including symlinks to HF blobs). Shared files are never deleted or changed. Selection and optional auto-transcription persist in UserDefaults. Downloads use cancellable URLSession tasks, ephemeral sessions, HTTPS, private staging files, streaming SHA-256 verification, fsync, and atomic installation. A failed download never replaces an installed model. Every transcription verifies the chosen file before launching native code; network access is unnecessary after download.

`TranscriptionJob` validates the input, launches exactly one owned worker, reads JSON-lines progress/results, checks returned source identities/durations/timestamps, and publishes only after a successful exit and explicit completion event. Cancellation sends SIGTERM and then, if needed after three seconds, SIGKILL only to the still-running owned process. Model-loading and inference failures leave audio and prior transcripts untouched. A new recording or audio preview cancels transcription; the UI does not start another worker until cleanup completes. Quit cancels owned jobs/downloads after the normal recording-save decision.

The helper uses ExtAudioFile to decode mono/stereo M4A to 16 kHz Float32 mono, holding at most 30 seconds of PCM. It prefers a low-energy cut between 24 and 30 seconds, carries the remaining samples to the next decode, and offsets results by the exact number of consumed samples. No samples or leading/middle silence are removed from the timeline. Near-digital-silence windows are skipped; this is not a learned speech detector. Continuous speech across a window boundary can lose language context. Parakeet/Nemotron words are grouped into phrases; Whisper's available segment timestamps are preserved. Unsupported/absent finer timestamps are never invented: the JSON records word, segment, or chunk granularity.

New call folders always use the isolated mic and system files, never the mix as a third input. Labels represent tracks, not biometric speaker identification. Old audio receives the Mixed audio label. Mismatched/missing isolated tracks are rejected. Results are stably merged by starting timestamp, retaining overlaps, then saved as a private text/JSON pair in a new atomically published folder under `Transcripts/`. Re-running a model does not overwrite previous outputs. Stored JSON identifies the model, hash, engine version, source filenames, language policy, and segment timing.

Known limits: no remote-speaker diarization, learned VAD, automatic model updates, resumable downloads, or transcription recovery after app termination. First-load shader compilation can be slow. RAM for model inference is separate from the recorder's original steady-state target. Four real models and 75-second track fixtures have been checked on Apple silicon; multi-hour ASR, other languages, Intel inference, and actual meeting accuracy remain acceptance work.

## Separate tracks (version 0.2)

The split-track format supersedes the original mixed-only format. New sessions preserve the selected mono mic and stereo system playback, then export `Microphone.m4a`, `System.m4a`, and `Mixed.m4a` together in a dated folder. Source tracks retain full source gain; the playback mix retains the fixed half-gain formula. Capture selection and routing are unchanged. Version 1 recovery remains mixed-only; no source separation is inferred from old recordings.

## Native capture and availability

Deployment is macOS 14.2, checked against installed Apple SDK headers. `AudioHardwareCreateProcessTap`/`DestroyProcessTap` are annotated 14.2 in the 14.5 SDK. The current Apple sample is advertised for newer Xcode/macOS, so its newer convenience properties were not adopted. The project also builds against the 14.5 SDK.

The only capture backend is a private, unmuted global stereo process tap excluding the recorder's **Core Audio process object**, combined with the selected input in a private ordinary aggregate. No default-device, physical-device sample-rate, output-volume, exclusive-access, or meeting-app setting is written.

The microphone UID is the explicit main clock. Its subdevice drift correction is off; the tap's correction is on. Preparation checks the active subdevice/main clock and the aggregate's accepted tap composition. A subtap object can be unavailable before IO on the tested OS, so the implementation does not require querying its `drft` property before starting. This configuration is not proof of measured alignment: initial offset and two-hour drift remain hardware acceptance gates.

### Observed aggregate behavior on macOS 15.8.1

A non-recording probe with the MacBook Air's mono built-in input found:

| Composition | Active mic | Aggregate input buffers |
|---|---|---|
| `IsStacked = true` | absent | `[2]` (tap only) |
| `IsStacked = false` | present | `[1, 2]` (mic + tap) |

Therefore the shipped path uses `false`, checks the actual composition/channel coverage, and rejects mismatches. Adding an explicit channel-count key did not change that result. No separate backend was introduced.

The aggregate's ordered subdevice UID list and current source channel count determine source spans. Its stream starting-channel properties, complete non-overlapping coverage, packed Float32 frame format, supported rates, and AudioBufferList configuration are then validated. The callback's buffer/channel references are derived from that runtime layout; there is no model, manufacturer, name, or fixed-channel-count mapping.

With the 16 kHz C920 microphone as main clock and a drift-compensated 48 kHz tap, the aggregate reports 16 kHz while the tap's stream ASBD retains 48 kHz even after Start. Live callbacks deliver **512 frames per source every 32 ms**, advancing input sample time by 512. A signed-app check of a 997 Hz playback tone measured approximately 995 Hz using zero crossings on the aggregate's 16 kHz timeline (a coarse pitch check, not drift qualification). Thus HAL already converts the tap to the aggregate timeline on this configuration. Rejecting unequal stream metadata rates prevented a valid webcam recording from starting; independently resampling the tap using its reported 48 kHz rate would convert it twice. The worker converts all three source channels together from the aggregate timeline to 48 kHz. Diagnostics retain both the actual reported source rates and the aggregate IO rate. Runtime equal-buffer-length and timestamp-continuity checks remain enforced; unsupported layouts still stop instead of silently shortening audio.

Apple's sample registers the IOProc immediately before `AudioDeviceStart`. This implementation follows that sequence, after all other fallible preparation. An earlier command-line experiment registered before completing preparation; immediate failure teardown then stalled in `AudioDeviceDestroyIOProcID` on this host. IOProc registration is now outside preparation, so cancelling/failing preparation has no registered IO context. Three live webcam Start/Stop cycles pass; permission-denied/start-failure teardown still needs qualification. Native calls can block; the UI stays on the main thread and offers explicit quit/recovery if saving stalls.

## Threading and timeline

`RecordingCoordinator` is main-actor isolated and owns the lifecycle. `RecordingEngine` serializes audio control, processing, file IO, and export on one dedicated queue. Property callbacks are delivered to that queue. Default input changes while idle update the catalog; active sessions retain their resolved input. Output-route changes conservatively stop/save partial audio.

The C IOProc is allocation-, disk-, logging-, task-, and lock-free. It copies only selected mono microphone and two tap channels into a preallocated single-producer/single-consumer ring. Microphone enable is atomic and applies before those samples enter the queue. A short non-real-time lock protects ring-pointer lifetime during UI toggles; the callback never takes it. Output IOProc streams are disabled; no monitoring/output data is produced.

The ring contains 64 slots, each up to 8,192 frames × 3 Float32 channels (~6 MiB). Overflow or malformed layout latches a failure with first discontinuity sample time and dropped-frame counts. No queue growth or silent drop policy is used. Maximum queued audio is `64 × 8192 / sourceRate` seconds; actual callback sizes are generally smaller. An interrupted recording may lose the unfinished 10-second chunk plus queued frames.

A worker timer runs only while capture is active, at 10 ms with 2 ms leeway. UI levels are published at ~10 Hz. The audio timeline comes from input sample timestamps and frame counts, never UI timers. Timestamp gaps/overlaps stop the recording at the valid prefix instead of silently removing or duplicating time. Host timestamps, source formats, and reported device/stream latency are recorded; no unmeasured manual latency shift is applied.

The worker clamps invalid/out-of-range input safely, counts clipping/nonfinite samples, and meters each source. One `AVAudioConverter` continuously converts three discrete source channels to 48 kHz using its input-callback API and an identity channel map. An explicit `DiscreteInOrder` channel layout is required; the channels must not be interpreted as a surround layout or downmixed. Silence is written normally. Mic enable changes are enforced before queueing, then again at their converted-frame positions so converter tails cannot enter a muted interval. The half-gain stereo mix is derived during export; separate microphone and system files preserve their source gains.

## Files and recovery

PCM files are interleaved on disk, with planar Float32 worker buffers. Version 2 fixes channel order as microphone, system left, system right. A single three-channel chunk carries the sources through exactly the same write/checkpoint/recovery boundary, avoiding independently truncated source files. Version 1 requires two mixed channels. Complete chunks are closed, synced, renamed, then checkpointed. Recovery trusts neither manifest paths nor chunk ordering blindly: it bounds manifest size/counts, checks version/session identity, rejects traversal/symlinks, verifies channel count/format/frame counts, and reconciles sequential files. It never concatenates across an unknown gap. Uncertain tails and unexpected additional files are retained after prefix delivery.

Export uses bounded 32,768-frame reads and an independent AAC writer per output. The mic is mono at a 64 kbps target; system audio and mix are stereo at 128 kbps each. All writers begin at source frame zero and consume the same chunk prefix, preserving initial silence and mute intervals. M4A validation uses the decoder's frame count (which accounts for priming/padding metadata), a 4,800-frame/100 ms tolerance against PCM, channel/rate checks, and sample reads at three positions. All three decoded durations must also match within one sample. The validated/synced staging folder is published with one `RENAME_EXCL` rename. A failing encoder leaves no visible partial set and retains PCM for retry. Cleanup requires every expected track, a recorded delivered path, and a known session directory. A delivered session with a missing track can be re-exported from retained PCM without overwriting surviving files. Legacy sessions retain their original single-M4A export behavior.

## References

- [Apple Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple sample-rate conversion technical note](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)
- [Audio input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)
- Installed `AudioHardware.h`, `AudioHardwareBase.h`, `AudioHardwareTapping.h`, and `CATapDescription.h` in the macOS 14.5 and 26.2 SDKs.
