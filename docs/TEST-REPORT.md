# Verification report — November 13, 2026

## Environment and scope

- Host: Apple silicon, macOS 15.8.1 (24H32), built-in device reported as **MacBook Air Microphone**.
- Compiler: Apple Swift 6.2.3, Command Line Tools. Current build SDK: macOS 26.2. Version 0.4 also compiled against 14.5; version 0.5 requires the newer SDK for Swift 6.2 isolated deinitialization in the shortcut library. Deployment target remains 14.2; macOS 14.2 runtime has not been qualified.
- Full Xcode/XCTest is not installed. Native app and core compiled with SwiftPM; the checked-in Xcode project/plists parse successfully. The shared Xcode scheme has **not** been built or tested with `xcodebuild` on this host.
- No audio interface was attached for the built-in-input layout checks. Available optional input: **HD Pro Webcam C920**, two channels, current nominal rate 16 kHz, current system default. It was discovered by capability, not special-cased in the implementation.
- Signed-app diagnostics exercised webcam capture without saving audio.
- Version 0.2 adds separate microphone/system tracks. This updates the original spec's mixed-only output requirement. Current build and recovery checks include the three-channel source spool and all three AAC outputs.
- Version 0.3 adds selectable local transcription, a pinned native helper, verified model downloads, and text/JSON delivery. Capture and the original audio tests are retained.
- Version 0.4 applies speaker bleed reduction before microphone transcription using the system track as the echo reference.

## Passed

| Check | Result/evidence |
|---|---|
| Debug/release native build | SwiftPM builds a native arm64 executable and the build script produces `build/Call Recorder.app`. |
| Build SDK compatibility | Version 0.5 builds with Swift 6.2 and the macOS 26.2 SDK. The old 14.5 SDK lacks `swift_task_deinitOnExecutor` required by the shortcut dependency and is no longer supported for building. Older runtime qualification remains outstanding. |
| App signing/configuration | Ad-hoc hardened-runtime signature verified; both usage strings, stable bundle ID, `LSUIElement`, and audio-input entitlement present. App Sandbox is not enabled. |
| Deterministic suite | **44 tests, zero failures**, running the same bodies used by the XCTest target through the included CLT assertion adapter. Includes corrupted/incomplete/cancelled model verification, shared HF symlink discovery and non-deletion, track-pair selection and mismatch rejection, old-recording labels, stable overlapping merge, output collisions/private permissions, invalid timestamp rejection, default-on/persisted-off cleanup, cleanup confirmation, and transcript metadata compatibility. |
| Mixing/privacy | Mono centering, fixed half-gain mix, pre-queue microphone muting, chosen channel only, interleaved/planar layouts, finite-value handling, and persisted mute-frame intervals. The full pipeline's saved three-channel PCM values are checked. Mute is also enforced after conversion; every mic sample after the fixture's off boundary is exactly zero in the source spool. |
| Timing/conversion | 44.1→48 kHz stereo sine conversion; silent duration at 8/16/32/48/96/192 kHz; explicit timestamp-gap rejection; silence is retained. A full 16 kHz aggregate fixture verifies saved 48 kHz PCM duration, microphone/system tone frequencies and gains, unselected-channel exclusion, and the mute boundary at frame 24,000. |
| Queue behavior | Exact accepted/dropped frame counts, overflow position, fail latch, and malformed buffer rejection. |
| Device semantics | Default re-resolution and frozen session input, explicit UID persistence through rename, duplicate names, missing-device rejection, per-UID channel settings, layout invalidation, ambiguous virtual input confirmation. These are deterministic catalog fixtures. |
| State transitions | Duplicate Start/Stop rejection, preview state, Stop during preparation, no late transition to Recording after cancellation. |
| PCM persistence/recovery | 10-second three-channel chunk boundaries, order and actual sample contents, 0600 permissions, checkpoint reconciliation, malformed/path-traversal rejection, missing-middle-prefix behavior, retained undecodable/unknown files, empty-session cleanup safety. Version 1 stereo sessions still recover/export as a single mix. Wrong channel counts for either manifest version are rejected without discarding originals. |
| AAC delivery | Real Apple AAC encoding at 48 kHz: mic mono/64 kbps target, system and mix stereo/128 kbps each. Reopen/codec/duration/three-position decode validation; complete-folder collision protection; encoder failure/retry; unavailable destination and replacement. No encoder mock is used for successful export tests. |
| Separate-track isolation and synchronization | Decoded microphone output contains the fixture's 440 Hz source and excludes 880/1320 Hz system sources. System output preserves the separate left/right tones and excludes microphone speech. Mix contains the expected half-gain components centered/stereo. All three files have exactly matching 96,000-frame decoded durations, preserve leading/trailing silence, and retain mute intervals. An entirely disabled microphone still exports a silent track of full duration. |
| Delivery failure and compatibility | Injected failure on the third encoder publishes no files, retains PCM, and successfully retries all tracks. A missing delivered mic file prevents PCM cleanup and can be rebuilt without overwriting surviving files. Old mixed-only recordings remain recoverable and are never labeled as isolated sources. |
| Forced termination, synthetic source PCM | SIGKILL of a separate fixture writer with two completed chunks and one open chunk. Recovered **1,055,570 frames / 21.991042 seconds** from 22 seconds offered. All three AAC files validated; microphone 440 Hz then 880 Hz ordering and system exclusion checked; system stereo and equal source durations verified. About 9 ms of unfinished tail was unavailable in this run; this is not a guaranteed loss bound. Originals are retained when the tail is uncertain. |
| Built-in aggregate layout | Unstacked private mic+tap aggregate reported `[1, 2]` Float32 input buffers at 48 kHz; main clock/active input and configured tap drift compensation verified. No IOProc registered/started for this check. |
| Preparation cleanup | Five injected failure boundaries (tap, aggregate, layout, ring, observations) and **50 preparation/teardown cycles each** with built-in and webcam input. Device/tap lists returned to baseline; mic nominal rate and system-default input were unchanged. This does not substitute for 50 live Start/Stop cycles. |
| Webcam mixed-rate live timing and pitch | Mic/aggregate report 16 kHz; tap stream reports 48 kHz. Live buffers contain 512 frames per source every 32 ms, on a continuous aggregate sample timeline. A signed diagnostic app captured a 997 Hz system playback tone at approximately 995 Hz by zero crossing count over one second, confirming expected pitch rather than a 3× rate error. Captured samples were analyzed in memory only. Hardware rate/default input unchanged; teardown returned success. |
| Webcam production pipeline Start/Stop | Repeated after the version 0.2 changes: `Scripts/check-capture.sh --preview 0` ran three 3-second no-save cycles through `CoreAudioCapture` and the three-channel `AudioPipeline`, with 94/93/93 callbacks and 144,384/142,848/142,848 converted frames. Zero dropped/invalid buffers; timestamp checks and cleanup passed. Mic peaks were approximately 0.048/0.054/0.043; this is not a speech intelligibility test. System playback was quiet in this check (tone verified separately on the earlier capture path). Device/tap lists returned to baseline, and mic rate/default input/default output remained unchanged. |

Generated crash-recovery fixtures are stored under the Git-ignored build directory.

### Speaker bleed reduction checks (version 0.4)

Engine: native WebRTC AEC3 from pywebrtc-audio 0.2.0, pinned at `1bc860a2051c2b9b3c10b8c778770794b9321d84`. No Python runtime is needed by the app. The microphone remains on its original timeline; only the system reference advances 40 ms. Noise suppression and automatic gain control are disabled.

- Native streaming output matched the offline reference implementation sample for sample.
- **Off and legacy paths:** turning cleanup off reproduced the original sample's entire segment array exactly. Mixed-only recordings still transcribe, with cleanup marked unavailable. JSON schema version 2 records whether cleanup ran and the actual engine/reference parameters; old schema version 1 remains readable. A helper cannot silently ignore a requested cleanup setting and still publish a transcript.
- **Bounded streaming and overlap fixture:** native tests cover short and non-frame-aligned files, silence, arbitrary decoder/output read boundaries, nonfinite samples, truncated references, mismatched durations, and cancellation. A synthetic delayed-echo fixture achieved 23.28 dB echo reduction and retained 90.95% of the independent near-end tone amplitude during overlap. This is a synthetic signal check, not a real simultaneous-speaker speech evaluation.
- Cancellation during cleanup prevented publication. Source audio and existing transcripts passed integrity checks.
- **Coordinator integration:** an isolated signed test app verified default-on behavior, persisted off/on choices, automatic transcription applying cleanup, manual transcription honoring off, and a running job retaining its original choice even if the preference changes. Recording-priority cancellation, queued automatic transcription, model persistence, and stale-transcript clearing still pass.
- The signed app worker completed a cleanup-enabled Whisper Base English job.
- **Build and packaging:** the release app and native worker build and pass strict signature verification. Swift also builds with warnings treated as errors against the macOS 14.5 SDK. The worker links only system dynamic libraries; echo cancellation and recognition libraries are statically bundled, with third-party notices included. The actual Settings view was rendered and inspected with the cleanup toggle on.

Quiet speech, changes in room acoustics, music, and simultaneous speakers require further validation.

### Global recording shortcut checks (version 0.5)

- The default is Control–Option–Command–R. The handler registers during coordinator initialization, so opening Settings or the recorder panel is not required. The app delegate now owns the coordinator from launch, retaining normal stop-and-save behavior for recordings begun through the shortcut.
- **44 core regression tests pass.** The new lifecycle check covers start, stop, cancellation during preparation, ending a preview, ignoring saving, and restarting from error/permission/recoverable states.
- **Actual global delivery passed** in an isolated signed test app with another application focused, using an unused test combination. Synthetic held/repeated key-downs caused no action until release, which triggered exactly once. Successive presses started and stopped a fake recording lifecycle; another press during saving did nothing. This test never creates an audio engine.
- **Settings interaction passed:** synthetic keys were captured by the actual native shortcut recorder control without triggering recording. The new shortcut worked globally and the old shortcut stopped working. Clear disabled the shortcut, a fresh child process confirmed it stayed cleared, restore-default re-registered it, and shutdown removed the registration.
- **Conflict reporting passed:** a deliberately occupied Carbon hotkey was rejected, and the app wrapper displayed an issue instead of reporting it as working. Settings also uses the dependency's menu/system conflict checks.
- The new SwiftUI Settings section was rendered and inspected. The signed release bundle includes the localization resource bundle in `Contents/Resources` and the MIT license. Full Xcode execution, other keyboard layouts, and physical-key acceptance on other macOS versions remain untested.

### Collapsible transcription panel (version 0.5.2)

The menu panel's content-height preference now has a neutral zero default and combines measured heights with `max`; zero measurements are ignored. Content is measured at its natural vertical size, with the existing screen-height cap retained. In the running app, the collapsed panel measured 461 points high, expanded to 561, and returned to 461, with approximately 20 points below the Settings footer in both states. The prior fixed 600-point window left about 159 points below the collapsed footer. Verification used accessibility geometry and the actual disclosure control; no recording or transcription was started.

Version 0.5.3 removed the measured footer/resize mismatch: the disclosure binding, panel layout, and measured-height update use nonanimated transactions, matching the immediate MenuBarExtra window resize. The height update also rounds and ignores unchanged values. Before this fix, sampled collapse frames placed the footer up to 73.71 points beyond the window bottom while it continued to animate. Afterward, all 62 sampled frames over 1.2 seconds retained exactly 20 points of bottom padding, with the window's top edge stationary. This measures intermediate layout rather than only the settled expanded/collapsed states.

### Native popover replacement (version 0.5.4)

The popover uses a persistent native `NSPopover` with animations disabled to avoid flashing during resize.

- The native popover grows and shrinks with its contents: outer bounds measured 426×487 collapsed and 426×587 expanded, including AppKit's popover chrome. No fixed empty region remains below the content.
- Settings opens from the actual popover and the popover dismisses when focus moves to Settings. These checks did not start recording or transcription.
- The earlier geometry trace proved only footer alignment, not the absence of visual flashing. Screen capture was not authorized, so no screen-video validation is claimed.

### Native recording library (version 0.6)

- **51 core tests pass.** New cases cover mixed and split-track discovery, duplicate locations, hidden staging directories, legacy transcript ownership, searchable older versions, corrupt transcript visibility, unsupported versions/invalid timestamps, missing folders, removed recordings, and original-file preservation. Paragraph tests cover joins, source changes, overlap, silence gaps, and bounded long turns. The codec-dependent suite requires normal macOS audio-service access; the restricted shell's AAC failures disappeared when run with that access.
- **Isolated native UI/playback harness passes.** Generated silent fixtures exercise loading, position-preserving track changes, seek bounds, replay, and blocking playback for every active recording state. The actual library model is checked for async initial loading, selection, transcript search, and filters. The retained native window controller is checked for playback pause on close and successful reopening. The actual views are rendered in light mode and compact dark mode using their own NSView drawing, without screen capture or live audio capture.
- Accessibility inspection verified the library search field, source picker, player, transcript paragraphs, and recording controls.
- **Window lifecycle checks pass.** Closing the main window leaves the app running and pauses playback. The File menu, native popover's Library button, and application reopen restore it. Settings opens from the library. Three isolated cold-launch/close/quit cycles also pass, polling for macOS foreground activation before accessibility inspection. Fixed-delay external probes were unreliable during foreground transitions. The configured shortcut was preserved, and the release bundle passes deep, strict code-signature verification. No capture, transcription, or playback was started by the window checks.
- This release does not requalify live capture or recognition accuracy. Very large archives, externally moved source folders, and long-duration playback need broader hands-on qualification. Xcode execution remains unavailable; SwiftPM and the generated Xcode project are the supported build artifacts checked here.

### Call management and transcript editing (version 0.7, November 14)

- **60 core tests pass.** Nine new cases cover normalized/searchable call details without renaming audio, corrupt/newer metadata protection, versioned transcript edits with original bytes preserved, source/timing/provenance retention, stale edits, same-basename legacy ownership, multi-item Trash rollback, individual-version deletion, full-call restoration, unrelated files, linked transcript directories, and edits to removed calls. Rapid versions use file modification time to break equal JSON timestamps.
- **The expanded isolated library harness passes.** It exercises metadata saving and search, new transcript versions, transcription exclusion during file mutation, async refresh after call/version deletion, protection of the recording destination, playback unloading, and removal of stale recent-recording references. Its Trash implementation moves only generated fixture files into a private test directory. The call and transcript editors render successfully, alongside the existing light and compact dark library checks.
- **Native macOS Trash round trip passes.** A newly generated test folder was moved with `FileManager.trashItem`, restored using the returned URL, checked for unchanged content, and removed. Existing user recordings were not edited or deleted by these checks.
- Transcript edits retain paragraph audio intervals, not inferred word timings. This release does not requalify recognition accuracy or live capture. Xcode execution remains unavailable on this host.

### Inline editing (version 0.7.1, November 14)

- The library row now supports inline title editing, with Return/checkmark to save and Escape/× to cancel. The isolated native harness verifies real text-field focus, text insertion, Return-to-save, empty-title validation, cancellation, and preservation of other call details.
- Transcript editing now uses the existing reader and player. The harness verifies draft retention through selection/search/refresh changes, saving a new version without changing the original, cancellation without a write, and clean draft state after saving. The reader and title field were rendered and inspected at normal and minimum window widths; no desktop capture was used.
- The 60 core tests and the expanded native library harness pass. Drafts are retained in memory while the app runs; quitting with unsaved edits requires an explicit discard choice. Production recording files were not edited during verification.

### Participant assignments (version 0.8, November 14)

- **69 core tests pass.** Nine new cases cover one-person inference for new and existing transcripts, preserving that assignment when a second person is added, migration from old call details, independent passage assignments, unchanged timing/source/text for speaker-only edits, explicit unassigned passages, preservation across text edits, grouping boundaries between named speakers, name search, and legacy shared-folder ownership. Microphone and mixed-source labels are not inferred as remote people.
- The isolated native harness adds a participant while a transcript draft is open, verifies the original automatic assignment, assigns a system passage to the new name, saves, and checks the named readable text. Updated light/dark reader and details-editor rendering passes alongside existing navigation, playback, editing, and deletion checks. Tests use only generated fixtures.
- Call details schema 2 stores frozen defaults per transcript version; annotated transcripts use schema 3. Older files remain readable. Named labels are manual assignments or one-person assumptions, not voice recognition or diarization.
- During relaunch, the older production build again became unresponsive at 100% CPU. Both sampled hangs stayed in SwiftUI’s lazy paragraph placement. The reader now uses stable eager paragraph layout; an 80-paragraph resize/search/silent-playback stress check passes. This removes that lazy-layout path; very large transcripts still need broader performance qualification.

### Participant renaming and removal (version 0.8.1, November 14)

- **75 core tests pass.** Regression cases cover replacing/removing a sole participant with embedded or frozen defaults, repairing stale schema-2 defaults on read, independent manual renames, copy/search labels, original-file preservation, explicit unassigned passages, deleting then reusing a name, simultaneous name swaps, reordered lists, chained renames, and saving an edit after all participants are removed.
- Participant rows distinguish a rename from adding/removing someone. Schema 3 call details apply corrections per transcript version without changing its original JSON/TXT. Removed manual assignments stay unassigned even if the old name is later reused. Automatic sections follow the current sole participant; adding more people retains that assignment.
- The isolated native harness checks renaming a manually assigned participant while text edits are open, saving the updated name, removing/replacing participants while an unchanged draft is open, and keeping draft text and dirty state correct. The reader and participant rows are rendered from their own views; no desktop capture or user-recording mutation is used.

### Immediate speaker assignment (version 0.8.2, November 14)

- In reading mode, choosing a speaker saves a new transcript version without creating a text-editing draft. The reader shows a small saving indicator on the passage and an inline error on failure. Selecting the already assigned name is a no-op. Search and playback position are retained.
- The native fixture verifies persisted assignments, no editor or unsaved draft, original-file/text/timestamp preservation, unchanged search/selection/playback, no duplicate version for a repeated choice, and recovery after a deliberately missing fixture file prevents saving. Existing text drafts retain their Save/Cancel behavior and do not publish text when their speaker dropdown is used.
- The existing title-field focus check needed reruns before passing; this change does not claim to resolve that intermittent fixture-focus issue. The completed harness also passes participant rename/removal, text editing, playback, reader stress, and fixture deletion checks.

### Read-only calendar feasibility spike (November 14)

The read-only EventKit probe requires the calendar entitlement. Meeting URLs can appear outside the dedicated URL field. Calendar copies and recurring events need occurrence-level deduplication. Attendee metadata can be incomplete, so group membership and speaker identity require confirmation. The probe stores diagnostics locally in the ignored build directory.

## Failed / limitations observed

### Local transcription checks (version 0.3)

Engine: transcribe.cpp 0.4.2, pinned at `275cd50d2c4104c204009a197ac091b9687668e5`, native static helper with Metal and Accelerate. Model test artifacts and logs are under `build/native/`; test transcription outputs were written under the test output directory.

- End-to-end jobs with Parakeet Unified, Nemotron, Whisper Base English, and Whisper Large v3 Turbo completed successfully.
- **Actual download code passed** for Whisper Base (84,886,208 bytes) and Turbo (886,381,728 bytes), including the pinned SHA-256 comparison. Shared cache discovery was verified read-only. A real download cancellation left no installed model or staging file in its isolated test directory. An initial HF symlink discovery bug was fixed and covered by regression.
- **75-second two-track AAC fixture passed:** public JFK speech inserted on the mic track at 2 and 43 seconds and on the system track at 18 and 60 seconds. All 12 returned phrases were assigned to the expected source and original time window, including after chunk boundaries. The merged transcript is sorted by time. A separate fixture with an entirely silent system track yielded only microphone phrases, with silence and offsets preserved. These are structural checks, not a real two-person call.
- **Inference cancellation passed after model load:** the worker reached the microphone track, received cancellation, exited, and published nothing. An injected helper failure after its loading event also produced no partial transcript and left the prior transcript intact. Signature verification and an end-to-end run using the helper inside the signed app bundle passed (20.69 s on that first signed-helper run).
- **Coordinator/UI/build checks:** an isolated test app verified persisted model selection, recording-priority cancellation, pending automatic transcription after a rapid recording transition, manual mode, preventing transcription while capture is active, and clearing the old transcript when a new recording is selected. The actual SwiftUI model settings were rendered and inspected, showing cache and download states. The menu content was rendered for layout. Both current and macOS 14.5 SDK Swift builds passed with warnings treated as errors where checked. The native Xcode project/plist parses; Xcode execution remains untested. Hands-on UI/accessibility and app-termination acceptance testing remain separate from these coordinator checks.

ASR limitations: no multilingual accuracy study, multi-hour transcription stress test, individual remote diarization, learned VAD, or Intel inference test. Timing is model-derived (word/segment/chunk granularity is stored explicitly). Continuous speech crossing a 30-second window can lose recognition context, and noise/music can cause hallucinated text. First-load Metal shader compilation can substantially exceed warmed timings.

### Earlier recording findings

1. **Resolved webcam startup rejection:** validation previously required each stream's reported rate to match the aggregate. The live checks above demonstrate that HAL already delivers the drift-compensated tap on the aggregate timeline. Removed that equality requirement, retained Float32/layout/rate bounds and live timing checks, and preserved actual metadata rates in diagnostics. No hardware rate was changed.
2. **Early IOProc teardown probe:** the initial design registered an IOProc before finishing preparation. Injected failure immediately after registration stalled inside `AudioDeviceDestroyIOProcID` → HAL stream-usage IPC. The current implementation registers immediately before Start, following Apple's sample, so preparation failures/cancellation no longer take that path. Three successful live Start/Stop cycles now pass; native permission-denied/start-failure teardown remains **unverified**.
3. **Stacked aggregate experiment:** `IsStacked = true` omitted the built-in microphone (`[2]` tap-only buffers). Corrected to `false`, verified as `[1,2]`. The app rejects an unexpected composition instead of recording only system audio.
4. **Sandbox-only AAC failures:** restrictive tool sandbox runs returned `fmt?` when creating even a minimal synthetic AAC encoder. The same check and full suite passed outside that sandbox with Apple's local codec service accessible. The app itself is intentionally outside App Sandbox.
5. **Command-line tone diagnostics:** unbundled diagnostic processes received silent tap buffers, including with the built-in input. The same tone check launched as a signed app captured the expected tone. Silence alone was not treated as proof of permission denial or a device fault; no TCC state was edited.
6. **Clamshell built-in microphone:** Apple documents hardware disconnection when Apple silicon/T2 laptop lids close. The app now explains this when a built-in input is selected. System audio can continue; an external mic is needed for speech in closed-lid use. [Apple reference](https://support.apple.com/guide/security/hardware-microphone-disconnect-secbbd20b00b/web).

## Not run — required before claiming the spec's definition of done

| Hardware/product acceptance test | Outstanding work |
|---|---|
| Built-in mic + ordinary playback, no interface | Validate intelligible microphone speech with the lid open, both audible sources, mic centering, and unselected-source exclusion. |
| Built-in mic + headphones and real calls | At least one Google Meet browser call and one Zoom/Teams call; record exact app versions/output routes and verify unchanged call routing, volume, and mute. |
| Actual microphone toggle privacy | Verify local speech disappears in the saved file while system audio continues; meeting-app mute must remain independent. Synthetic equivalent passes. |
| Real-call separate-track delivery | Validate varied routes, headphones, audible quality, and simultaneous speech. |
| System audio permission lifecycle | Grant/deny/revoke separately from microphone; verify actual OS status/prompt/settings behavior on macOS 14.2 and 15.8.1. Silence must never be diagnosed as denied permission. |
| Hardware disappearance/format/route changes | Unplug/switch input/output during capture; confirm visible partial-save behavior and no silent source substitution. |
| Real default-input and rename/duplicate devices | Change default between sessions and during a session; rename/restart explicit choices; confirm the frozen active source. Deterministic equivalents pass. |
| Other USB/wired/Bluetooth/headset/multichannel inputs | Test available devices with different output devices and a non-first microphone channel. Optional hardware is not a prerequisite for the built-in baseline. |
| Real mixed 44.1/48 kHz sources | Confirm supported capture or clear rejection. Webcam 16/48 kHz short capture and pitch checks pass; physical 44.1/48 kHz sources have not been exercised. |
| Two-hour timing | Measure initial path offset with a repeatable reference stimulus, then verify drift ≤50 ms after subtracting that offset. The aggregate configuration alone is not evidence of alignment. |
| Four-hour endurance/performance | Measure steady-state RSS (<150 MB target), average CPU (<10% of one core target), responsiveness, no unexplained dropouts/duplicated blocks, and final export. No recording CPU/RSS result is claimed. |
| Fifty live Start/Stop cycles | Three webcam live cycles pass; complete the remaining endurance/lifecycle qualification across supported inputs. |
| Live force-termination recovery | SIGKILL during a real two-source capture, then recover and inspect intelligibility, ordering, tail/gaps. Synthetic process-kill recovery has passed. |
| Sleep/logout/quit/storage faults | Exercise actual sleep, quit/cancel during recording and saving, permission revocation, full/removable/unavailable volumes, and best-effort checkpoint paths. Synthetic storage/export failures pass. |
| UI/accessibility | Confirm menu indicator, VoiceOver labels/meters, panel-close preview stop, recording persistence when switching apps/opening Settings, and first-run permission-dialog behavior. |

The delivery has verified separate-track conversion/storage/export/recovery behavior, native preparation checks, and short live webcam capture/cleanup checks. It is **not yet qualified as a dependable live call recorder** until the outstanding real-call source-separation, timing, and lifecycle tests pass.

### Calendar integration and attendance (version 0.9)

- **92 core tests passed** via `Scripts/test.sh`, including the existing capture/export/transcript regressions. New cases cover email aliases and preferred names; explicit group classification over person-typed invitations; roster deduplication, self/resource exclusion, direct declines, duplicate display names; recurring/shared event identity; provider host/path validation and Safe Links; reminder boundaries, snooze, dismissal persistence, rescheduling and stale wake; private directory persistence; and attendance removal/restore without silently transferring labels.
- Synthetic AAC recovery tests verify meeting details survive the manifest round trip and are published with the three audio tracks before transcript initialization. Missing delivered metadata now blocks PCM cleanup and can be re-exported without overwriting the incomplete delivery.
- **`Scripts/check-calendar-integration.sh` passed.** It injects a fake calendar reader and isolated defaults/people storage. It checks self-email learning, preferred names and groups, an actual visible native reminder panel, snooze/dismiss, declined-self filtering through aliases, and refusal to start a stale event. Temporary recording fixtures exercise lightweight speaker assignment, attendance clearing, original transcript preservation, and explicit single-attendee labeling both with and without an unsaved text draft.
- Five own-view renders were inspected for Upcoming calls, reminder, settings, people, and attendance. These are NSHostingView renders, not screenshots of the user's desktop. The integration harness never requests Calendar access, opens a meeting, or starts live audio capture.
- The broader `Scripts/check-library.sh` passed playback, library indexing/search, participant edits, owned-window close/reopen, and inline rendering, then stopped at its previously intermittent keyboard-focus check (`Inline title did not receive keyboard focus`). It is not reported as an entirely passing run. The separate new integration harness covers speaker assignment and attendance without relying on offscreen keyboard focus.
- Live EventKit metadata feasibility was established by the preceding spike. The new reminder timing and attendance paths were tested with fixtures; a real meeting and Join & record were not exercised. App windows are used for reminders, so Notification Center authorization is not required. Production calendar access requires the normal macOS prompt for the recorder's own bundle identifier.
- The release build passed signature, entitlement, property-list, and project checks. The library remained responsive after relaunch.
