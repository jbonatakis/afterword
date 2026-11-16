# Call Recorder — agent implementation specification

> Historical specification under the original working name. The current product, package, and project are Afterword; current behavior and paths are documented in README.md.

**Version:** 1.1  
**Prepared:** November 12, 2026  
**Revised:** November 13, 2026  
**Platform:** Native macOS, Apple silicon first  
**Product priority:** Easy, dependable recording—not audio-production features.

**Revision 1.1 supersedes version 1.0.** This is a hardware-agnostic macOS call recorder. No external audio interface, vendor-specific integration, or hardware loopback is required. The built-in microphone is a first-class baseline, not a fallback.

## 1. Instructions to the implementing agent

Build the application described below, not another proposal or a visual-only prototype. Inspect the existing repository first. If it is empty, create a native macOS application project with a shared Xcode scheme and tests. Do not rewrite unrelated code.

Work through the milestones in Section 12. Prove real audio capture before polishing the interface. Use public Apple APIs and verify availability against the installed SDK; do not invent permission APIs or assume that the newest sample project supports the minimum OS without checking its symbols.

Make reasonable implementation decisions within this specification. Document consequential deviations and their evidence. Do not expand the feature set. If the execution environment cannot run macOS audio capture, finish the buildable implementation and automated tests that are possible, then identify the precise hardware/permission tests still outstanding. Never describe mocked capture or an untested hardware path as working.

The requirements and numerical thresholds below are design decisions, not claims that an implementation has already passed them. References support the platform API choices.

## 2. Product goal and scope

The user joins a video call normally, opens a menu-bar popover, presses **Start recording**, and later presses **Stop recording**. The app automatically saves one audio file containing the conversation. The file can be opened in Finder and manually uploaded elsewhere for transcription.

The app must work on a supported Mac using its built-in microphone, with no external audio interface attached. It must not require learning an audio workstation, installing a virtual audio driver, configuring Audio MIDI Setup, changing the call application's audio routing, or selecting tracks for export. Optional external microphones and interfaces use the same generic input-selection path.

| Decision | MVP requirement |
|---|---|
| Working name | Call Recorder |
| Minimum OS | macOS 14.2; verify all chosen APIs against this deployment target |
| UI | SwiftUI menu-bar utility with AppKit integration where needed |
| Capture | System audio through Core Audio process taps; selected microphone through Core Audio |
| Default microphone | **System default**: resolve the current macOS default input at each session start |
| Optional microphone choice | Any usable input device exposed through Core Audio, including built-in microphones, USB microphones, headsets, Bluetooth inputs, and external interfaces; no manufacturer-specific behavior |
| Input channels | Automatic for a single-channel input; a generic single-channel selector when a multichannel device needs it |
| Hardware dependency | None beyond a supported Mac and an available audio input; no external interface or hardware loopback required |
| Output | One mixed stereo AAC-LC `.m4a`, 48 kHz, target 128 kbps |
| Default destination | `~/Music/Call Recordings/`, created when needed |
| Data handling | Local only; no accounts, server, analytics, or automatic uploads |
| Distribution | Locally runnable app first; no App Store submission requirement |

Apple documents Core Audio tap capture on macOS 14.2 or later, using a tap attached to a HAL aggregate device. That is the basis of the driver-free capture design. [S1]

### Explicit non-goals

No transcription, summaries, AI integration, video capture, meeting detection, calendar integration, automatic recording, per-application capture picker, waveform editor, track editor, cloud sync, global hotkey, pause/resume, or software monitoring. Do not implement a second capture backend, hardware-loopback capture mode, vendor-specific integration, Electron wrapper, bundled FFmpeg, or background service for the MVP.

**Boundary:** “System audio” includes other applications and notifications, not only the video call. Do not label it “Other participants” or imply call-specific isolation. The global stereo tap supports mixing output from processes while excluding specified processes. [S3]

## 3. Hardware-independent audio requirements

### 3.1 Separate system capture from microphone selection

Capture system audio through the macOS process-tap path, not an audio interface's loopback channels. Microphone selection and system-audio capture are independent: the microphone and playback device do not have to be the same device. Do not ask the user to route the call through an interface or the recorder. Qualify supported output routes with the tests in Section 10; never infer compatibility merely because a device appears in the list.

Support input devices by their Core Audio capabilities, not by manufacturer, model, display name, connection type, or an assumed channel layout. The same code path must handle built-in microphones, USB microphones, headset microphones, Bluetooth inputs, and multichannel interfaces when their exposed formats are usable. Do not add a brand allowlist or claim every device/configuration has been tested.

### 3.2 Default and explicit device selection

The microphone picker defaults to **System default**. Show the currently resolved device beside that label so the user knows which microphone will be recorded. For a single-channel default input, permissions and Start should be sufficient; do not require a separate device/channel setup wizard. Test audio remains available for confirmation.

Persist one of two selection modes:

- **System default:** Resolve the current macOS default input when preparing each preview or recording. Follow changes while idle, but freeze the resolved device for an active session. Do not persist yesterday's resolved UID as an explicit device choice.
- **Specific device:** Persist its **device UID**, not its display name or transient device ID. Re-resolve the UID on launch and before capture. If it is absent, show **“Selected microphone unavailable”** and offer an explicit replacement, including System default. Never silently substitute another device.

Enumerate public input-capable devices and display their actual names. Unusual or duplicate names must not affect capability detection or identity. Add a non-sensitive distinguishing label when names collide. Do not assume a similarly named replacement is the previously selected device.

The system-default microphone need not be the microphone selected privately inside a meeting app. Make the resolved source visible and allow an explicit choice; do not inspect or change the meeting app's settings.

### 3.3 Generic channel selection

For a device exposing one usable input channel, select it automatically and hide channel controls. For a multichannel device, reuse a valid previously confirmed channel for that UID. Otherwise use an unambiguous microphone-channel designation exposed by the device, or ask the user to choose a single channel with the Test audio meter. Do not assume the first channel is the intended microphone, and never mix all channels by default.

Prefer device-provided channel labels, with one-based numbered labels as a fallback. Translate indices internally. Persist channel preferences per device UID and revalidate them against the current layout. A different system-default device must not inherit another device's channel index. If a layout change invalidates the preference, require selection again rather than guessing.

Treat the selected microphone channel as mono and place it equally in both channels of the final stereo file. Do not leave local speech in only one ear or treat arbitrary adjacent inputs as a stereo microphone pair. This is a generic speech-recording policy, not an interface-specific channel map.

Do not choose an input identified as a playback/loopback mix as a microphone automatically. Use available capability/channel metadata, but do not invent a universal way to identify virtual or loopback sources. If the source is ambiguous, require explicit selection and verification. Never intentionally capture system audio through both the tap and a loopback input.

### 3.4 Device lifecycle and compatibility

The recorder must not install drivers, require hardware routing changes, or require hardware loopback. An optional device must already be usable by macOS; the recorder does not manage its drivers or control software. Sample rates, stream counts, channel counts, and layouts must be discovered at runtime.

During a session, do not switch microphones automatically. A change to the macOS default input alone need not end a session if the frozen source remains valid. If the active input disconnects or its stream configuration becomes invalid, stop safely and save the captured portion. Apply the latest system-default selection only on the next user-initiated session.

Bluetooth/headset configurations are part of compatibility testing, not a separate backend or an assumed guarantee. Observe their actual stream formats and route/configuration changes. Reject an unusable configuration clearly rather than silently recording only one side. No particular external device is a prerequisite for building, using, or proving the baseline recorder.

## 4. User experience

### First run

Explain the app's two sources, request microphone and system-audio permission in context, and preselect System default. Display the resolved microphone and allow an optional explicit device choice. Ask for a channel only when the multichannel rules in Section 3 require it. Include these plain-language notices:

- **“System audio includes sounds from other apps and notifications.”**
- **“Your microphone is recorded independently of the call. Muting yourself in Zoom, Meet, or Teams does not mute this recorder.”**
- **“Use headphones to avoid recording the call audio again through your microphone. Get any required permission before recording.”**

Provide a **Test audio** action. It starts explicitly indicated, temporary metering without saving audio. Ask the user to speak and play audio or use the call application's speaker test. Do not play a test tone through this app while excluding its own process from capture. End the preview when its panel closes or after 60 seconds. No microphone or system-audio capture should remain active while idle outside this explicit test.

Permissions may be granted at setup, but no recording begins until the user presses Start.

### Menu-bar popover

Keep the main view small. Show status, the microphone selection mode and resolved device (channel only when relevant), separate **Microphone** and **System audio** level meters, elapsed recording time, one prominent Start/Stop button, and a **Record microphone** toggle.

The microphone toggle defaults on. When switched off during a recording, replace that contribution with silence before persistence; system audio continues. Label the microphone meter **Off**, and record the transition in session metadata. This control affects the recording only, not what the user transmits to the meeting. Do not infer or synchronize meeting-app mute state.

Show a persistent recording indicator in the menu bar even when the popover closes. Use an icon/state change and accessible label, not color alone. Opening another application, dismissing the popover, or opening Settings must not stop recording.

After Stop, show **Saving…** until export validation finishes, then **Saved** with **Show in Finder**. Never open Finder or play the recording automatically. The popover may show the most recent saved filename; a recording-library interface is unnecessary.

Settings contain only microphone selection (System default or a specific device), the channel selector when relevant, destination folder, and the recording notices. Lock source and destination selection during a session; the microphone recording toggle remains usable.

### State model

Serialize control operations through one coordinator: **Idle → Preparing → Recording → Finalizing → Idle**. Support **Previewing**, **Needs permission**, **Error**, and **Recoverable recording** as explicit states.

Preparing verifies permissions, source availability, storage, stream configuration, and callback startup. Do not wait for nonzero audio to declare recording: silence is valid. Do not show Recording merely because resources were allocated; verify that the capture path is running. Disable duplicate Start/Stop requests and prevent overlapping sessions.

## 5. Permissions and app identity

Include truthful `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` strings. Microphone permission and system-audio permission are distinct. Apple's tap sample describes the system permission prompt occurring when recording starts on an aggregate containing a tap. Do not use a microphone permission check as proof of system-audio authorization. [S1, S2]

Use the documented microphone authorization flow. For system-audio authorization, follow the process-tap flow supported by the target OS; distinguish an API failure, unavailable source, denied permission, and legitimate silence. Do not guess that an all-zero buffer means permission was denied.

On denial, explain which permission is missing and provide an Open System Settings action with accurate instructions. Settings labels and deep links must be verified on supported OS versions; include a text navigation fallback. Do not repeatedly trigger prompts, change TCC records, reset other applications' permissions, or request Screen Recording merely as a speculative workaround.

Use a stable bundle identifier and document signing for local development. Enable the hardened runtime with the required audio-input entitlement; Apple documents `com.apple.security.device.audio-input` for microphone/Core Audio input access. Ship the initial local build outside App Sandbox unless sandbox support is deliberately implemented and tested. Do not add unrelated entitlements. [S4]

Do not request camera, Accessibility, contacts, calendar, or automation permissions. OS privacy indicators must remain intact. No startup item or launch-at-login behavior in the MVP.

## 6. Capture architecture

### 6.1 Primary approach: one private aggregate

Start with Apple's tap sample and the installed SDK headers. Create a private, unmuted global stereo process tap, excluding this application's Core Audio process object. The exclusion list uses Core Audio process object IDs, not raw POSIX PIDs. Preserve normal system playback. [S1, S3]

Create a session-scoped private aggregate that combines the resolved Core Audio microphone input device and the tap. This must work with the built-in input; it must not depend on an external interface. Configure an explicit clock source and appropriate drift compensation for other clock domains; relevant HAL keys include `kAudioSubDeviceDriftCompensationKey` and `kAudioSubTapDriftCompensationKey`. These keys exist, but their correct application to this particular combination must be verified in the capture milestone. [S5]

The intended result is one coordinated input timeline containing the chosen microphone source and stereo system source. Query the resulting stream/channel layout and formats. Never assume fixed aggregate channel offsets, a particular input-channel count, interleaved buffers, or a 48 kHz hardware rate. Resolve the selected microphone channel from the discovered device/stream layout, not a hard-coded offset.

Use `AudioDeviceCreateIOProcID`, `AudioDeviceStart`, and the corresponding stop/destroy operations for capture lifecycle. Keep allocation, failure cleanup, and teardown explicit. [S6]

**Implementation gate:** First prove concurrent capture with the built-in microphone and ordinary system playback, with no external audio interface attached. Confirm that the aggregate captures both sources without changing the user's existing audio routing or hardware sample-rate settings. Then test the same generic path with available external inputs and different output routes. If the aggregate approach fails on a required configuration, document the failure before replacing it with separate microphone/tap capture and timestamp-based synchronization. A replacement must meet the same tests, include drift correction, and become the single implementation—not a user-visible backend choice. Do not claim an aggregate automatically guarantees correct alignment.

Never set the aggregate as the macOS default input/output, call microphone, or call speaker. Do not acquire exclusive device access. Do not send recorded audio to an output device. On teardown, destroy only resources created by this session; never delete user-created aggregate devices.

### 6.2 Real-time boundary

Use a small C callback layer and preallocated, bounded buffers. The callback may validate/copy frames and timestamps, apply the current microphone-enable flag, and update atomic counters. It must not perform disk writes, encoding, logging, UI work, blocking locks, allocation, or asynchronous task creation.

Move processing to a dedicated worker. Keep UI updates on the main thread, throttled to roughly 10 Hz. Size queues explicitly. On queue overflow, record the exact discontinuity and transition to a visible failure/partial-save path rather than silently dropping audio or growing memory indefinitely.

Copy only the resolved microphone channel into the recording pipeline. Do not persist unselected input channels or duplicate system playback from a loopback source. Keep separate source meters before mixing; a moving system meter must not conceal a missing microphone source.

### 6.3 Timing, conversion, and mixing

Use capture timestamps and frame counts, not UI timers or callback arrival order, as the audio timeline. Track discontinuities. Preserve silence; do not shorten the recording whenever a source becomes quiet. Account for reported input/tap latency where applicable and measure the remaining offset.

Normalize the coordinated stream to 48 kHz floating-point PCM on the worker without forcing hardware sample-rate changes. Apple provides sample-rate conversion through `AVAudioConverter`; its callback-based conversion method is required for sample-rate conversion, unlike its simpler buffer-to-buffer method. [S7]

For each output frame, use:

**Left = 0.5 × selected mono microphone + 0.5 × system left**  
**Right = 0.5 × selected mono microphone + 0.5 × system right**

When microphone recording is off, its contribution is zero. This fixed mix is the MVP headroom policy; no mixer UI, automatic gain control, loudness normalization, denoiser, or acoustic echo cancellation. Validate finite sample values and handle out-of-range input safely. Expose clipping in diagnostics rather than claiming that a clipped input was repaired.

The recorder must remain a passive observer of the call. Headphones are the supported recommendation for avoiding acoustic duplication; speakerphone echo cancellation is explicitly outside the MVP.

## 7. Durable recording and final output

Do not rely on a single unfinished compressed file as the only copy of a long meeting. Use a session directory under `~/Library/Application Support/Call Recorder/Sessions/<UUID>/` containing a small versioned manifest and sequential, independently finalized PCM CAF chunks. Target 10-second chunks of the mixed 48 kHz stereo float stream. Do not retain separate source tracks in the product.

The manifest records session ID, start time with timezone, monotonic timing reference, microphone-selection mode, resolved device UID/channel for this session, actual source formats, intended destination, completed chunk frame counts/order, microphone toggle intervals, errors/discontinuities, and finalization status. Avoid application/window titles and meeting metadata.

Close and flush each completed chunk, then atomically checkpoint the manifest. Recovery must also reconcile complete chunk files created just before a manifest update was interrupted. Retain the unfinished current chunk for best-effort salvage; never delete it merely because it cannot be decoded immediately.

On Stop: stop capture, drain queued frames, finalize the last chunk, release audio resources, encode chunks sequentially into a temporary M4A, validate it, then atomically rename it into place on the destination volume. Keep memory bounded throughout export. Preserve the session until the final file is safely in place.

Filename format: **`Call-YYYY-MM-DD_HH-mm-ss.m4a`**, using local start time and a collision-safe suffix when needed. Never overwrite a prior recording. Target AAC-LC stereo, 48 kHz, 128 kbps; report an encoder failure rather than silently changing the format or writing a misleading extension.

Before declaring Saved, reopen the file, confirm the expected codec/channel/sample-rate properties, verify duration within 100 ms of the PCM timeline, and decode beginning/middle/end samples. Codec priming and padding must be handled correctly. Remove temporary chunks only after successful validation and delivery.

On next launch, offer **Recover recording** for unfinished sessions. Reconstruct the longest valid timeline and clearly label any missing tail or known gap. If export fails, keep the recoverable PCM and provide Retry and Show recovery files. Do not claim crash recovery has passed until force-termination tests succeed.

Set private file/directory permissions where supported. The application performs no upload, but a user-selected folder may itself be synchronized or backed up by another service; do not promise otherwise. Do not claim encryption at rest or secure erasure.

## 8. Failure and lifecycle behavior

| Situation | Required behavior |
|---|---|
| Selected microphone missing before Start | If System default resolves to no usable input, block with a clear explanation; if a specific device is missing, offer explicit replacement or System default, never silent substitution |
| macOS default input changes | While idle, update the resolved source in System default mode; during a session, keep the frozen input if valid and apply the new default only on the next session |
| Saved channel no longer valid | Require a new channel selection before capture; do not reuse another device's channel preference or silently choose a different channel |
| Device disconnects or stream configuration changes during capture | Stop safely, save the captured portion, and show the cause; no silent continuation with one side missing |
| Output route changes | Continue only if the existing tap/aggregate remains demonstrably valid; otherwise stop and save partial audio with a visible message |
| Long source silence | Keep recording; meters indicate silence. Do not infer failure from quiet audio alone |
| Source/backend reports failure | Stop safely and preserve partial audio; distinguish reported failure from ordinary silence |
| Destination unavailable | Preserve the local session and offer another destination for export |
| Low disk space/write error | Warn with remaining capacity, stop before exhausting the reserve where possible, preserve completed chunks |
| System sleep/logout | Best-effort stop/checkpoint; use recovery after forced termination. Never resume recording automatically on wake |
| User quits while recording | Ask whether to Stop and save or Cancel quit; no silent discard |
| Export failure | Keep PCM and offer Retry; do not show Saved |

Calculate storage requirements from the actual PCM format. A proposed initial guardrail is 1 GB free before starting and a 256 MB emergency reserve during capture; check both the spool and output volumes. These thresholds are not a guarantee against disk-full errors. Check all write results and keep enough headroom for finalization when possible.

While recording, an idle-sleep prevention assertion is acceptable, but it must be released on every stop/error path. Do not prevent deliberate sleep or lid-close behavior. Do not notify with sounds that would contaminate the recording.

## 9. Code organization and diagnostics

Use a small set of responsibilities, not a plugin framework:

| Component | Responsibility |
|---|---|
| App/UI | Menu bar, popover, settings, accessibility, user actions |
| RecordingCoordinator | Serialized state machine and lifecycle ownership |
| PermissionService / DeviceCatalog | Authorization flow, System default versus explicit selection, device UIDs, per-device channels, device-change observations |
| CoreAudioCapture | Tap/aggregate creation, format discovery, C callback integration, teardown |
| AudioPipeline | Bounded queues, source meters, timing, conversion, fixed mixing |
| SessionStore / Exporter | PCM chunks, manifest, recovery, AAC export and validation |

Persist ordinary preferences locally, including microphone-selection mode and per-device channel choices. Keep audio-device IDs session-local; resolve saved UIDs again after launch and topology changes. Resolve System default anew at each session start and record the actual resolved UID in that session, without changing the persisted selection mode.

Use structured local diagnostics with operation names, decoded OSStatus values, OS/app version, actual formats, frame counts, dropped-frame counters, timing discontinuities, and capture/export state. Never log raw audio, transcripts, secrets, or meeting contents. A user-initiated Copy diagnostics action may provide a redacted summary. Do not transmit logs.

SwiftUI supports a `MenuBarExtra` window-style popover; `LSUIElement` supports keeping a menu-bar-only utility out of the Dock/app switcher. Use these facilities rather than constructing an audio-workstation window. [S8]

## 10. Acceptance tests

### Automated tests

Use deterministic PCM fixtures and a fake capture source for tests only. Cover mono-to-stereo centering, exclusion of unselected channels, fixed mixing, microphone toggling, silence preservation, interleaved/noninterleaved layouts, 44.1-to-48 kHz conversion, state transitions, bounded-queue overflow, malformed manifests, filename collisions, chunk reconciliation, encoder failure, and recovery cleanup safety.

Test System default resolution at each session start, idle default changes, frozen-device behavior during recording, explicit UID persistence across renaming, duplicate display names, missing explicit devices, per-device channel preferences, and invalidated channel layouts. Assert that no manufacturer/model-specific selection or fixed multichannel offset is required.

Test startup failure at each resource-allocation step and verify balanced teardown. Test duplicate Start/Stop actions and Stop during preparation. Test simulated format changes, missing devices, storage failures, and export retries. Test that recovered/exported PCM ordering is correct rather than merely asserting that a file exists.

### Real macOS/hardware tests

| Test | Passing result |
|---|---|
| Built-in microphone, no external audio interface | Baseline passes on a supported Mac: both sources reach one valid file, microphone centered, no driver installation or routing configuration; speakers may cause the disclosed acoustic duplication |
| Built-in microphone + ordinary headphones | Both sides of a real call are intelligible without hardware loopback or an interface; normal workflow is Start/Stop |
| System default selection | Current default input is displayed and resolved per session; changing the default between sessions uses the new device; no silent mid-session mic switch |
| Explicit device selection | Choice survives app restarts and display-name changes by UID; a missing device requires explicit replacement |
| USB microphone or wired headset | Available device uses the same picker and capture path, without brand-specific configuration; test with a different playback device |
| Bluetooth/headset input | Test an available device/configuration, including route/format changes; both sources record correctly or an unsupported configuration is clearly rejected, never false success |
| Generic multichannel input | User-selected channel alone is saved and centered; verify selection of a channel other than the first; no fixed channel-count or offset assumption |
| Renamed or duplicate-name input devices | Discovery is capability-based and explicit choices retain UID identity; names do not drive selection |
| Concurrent call use | Recording does not change call input/output, playback volume, mute state, or shared hardware sample rate |
| Application coverage | At minimum, one real Google Meet browser call and one Zoom or Teams call, with tested versions recorded |
| Microphone privacy | Meeting-app mute does not falsely show recorder mute; Record microphone off removes local speech from the saved file |
| System capture behavior | Other-app audio is captured as disclosed; output-volume/mute behavior is measured and documented; no app playback feedback |
| Two-hour timing run | After measuring initial path latency, relative timing drift is no more than 50 ms; no unexplained dropouts or duplicated blocks |
| Mixed-rate configuration | A real 44.1/48 kHz source combination succeeds or the unsupported configuration is clearly rejected before capture |
| Unplug/output switch | No false success or silently missing side; partial recording and explanation available |
| Permission denial/revocation | Accurate state and remediation, no crash or infinite prompt cycle |
| Forced termination | Completed chunks recover; any lost tail is bounded to the unfinished chunk plus queued data and is disclosed |
| Four-hour endurance | Bounded memory, responsive controls, valid export; no growth proportional to recording duration in RAM |
| Repeated sessions | Fifty start/stop cycles without orphaned tap/aggregate resources or retained microphone access |
| Sleep/quit/disk failure | Expected stop/recovery behavior and preserved completed audio |

Built-in-input tests are the required baseline. External-device tests are compatibility coverage using whatever hardware is available, never a purchase or a named-model requirement. Mark unavailable cases **not run** and qualify compatibility claims; lack of optional hardware must not prevent delivery of the baseline implementation.

Measure timing with a repeatable reference stimulus and known capture-path latency, not subjective listening alone. Do not classify network-call latency as local capture drift.

Initial performance targets on a supported Apple-silicon Mac: recording steady-state memory under 150 MB and average CPU under 10% of one core, excluding export. Treat these as targets to measure, not claims. Report actual measurements and explain deviations. No busy polling while idle.

## 11. Definition of done

A clean checkout builds through the documented Xcode scheme. The app runs locally with appropriate signing, obtains the correct permissions, records real microphone and system audio, saves a validated M4A automatically, and exposes recoverable sessions after interruption. Normal use requires only Start and Stop after setup. The baseline must work with the built-in microphone and no external audio interface, vendor-specific driver integration, or hardware loopback. A demo that works only with a particular external interface does not satisfy this specification.

Deliver source, project configuration, shared scheme, entitlements/usage descriptions, automated tests, a README covering build/install/permissions/use, and a test report separating **passed**, **failed**, and **not run** checks. Include specific OS versions, devices, call applications, output routes, and known limitations. Provide local build/run/test commands in the README; do not require a paid developer account merely to test locally when Xcode local signing suffices.

A notarized distribution package is not an MVP blocker. Document the additional signing/notarization work rather than adding an updater or release service.

## 12. Implementation order

1. **Capture proof:** Build the app bundle and real permissions flow; resolve System default; prove actual system and built-in microphone capture with no external interface attached; inspect layouts, levels, timing, and call coexistence. Exercise generic explicit-device/channel selection with available hardware. Document the aggregate decision before adding polish.
2. **Recording core:** Implement bounded capture queues, timing/conversion/mixing, PCM chunk persistence, Stop/export/validation, and failure cleanup. Produce a real end-to-end file.
3. **Minimal product UI:** Add menu-bar state, Start/Stop, meters, microphone toggle, System default/explicit microphone selection, conditional channel controls, remembered settings, explicit test mode, and Show in Finder.
4. **Reliability:** Add recovery, device/route changes, storage/sleep/quit handling, permission remediation, and diagnostics.
5. **Verification and handoff:** Run automated tests and available hardware tests; measure endurance and timing; document exact limitations and remaining manual checks.

Do not finish at milestone 1 or substitute a polished mock for the recording core. Do not add deferred features while core acceptance tests remain unresolved.

## 13. Primary references

Consult these together with the installed SDK headers. These platform references are retained from version 1.0; revision 1.1 changes hardware-selection requirements, not the API reference set. Symbol-level availability and behavior must still be verified during implementation. URLs are included so this file remains self-contained when passed to another agent.

**[S1] Apple — Capturing system audio with Core Audio taps**  
`https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps`

**[S2] Apple — NSAudioCaptureUsageDescription; Requesting Authorization for Media Capture on macOS**  
`https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription`  
`https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos`

**[S3] Apple — CATapDescription global stereo tap initializer**  
`https://developer.apple.com/documentation/coreaudio/catapdescription/initstereoglobaltapbutexcludeprocesses:`

**[S4] Apple — Audio Input Entitlement; Configuring the hardened runtime**  
`https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input`  
`https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime`

**[S5] Apple — Aggregate subdevice and subtap drift-compensation keys**  
`https://developer.apple.com/documentation/coreaudio/kaudiosubdevicedriftcompensationkey`  
`https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationkey`

**[S6] Apple — AudioDeviceStart and related lifecycle APIs**  
`https://developer.apple.com/documentation/coreaudio/audiodevicestart%28_%3A_%3A%29`  

**[S7] Apple — TN3136: AVAudioConverter — performing sample rate conversions; AVAudioConverter**  
`https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions`  
`https://developer.apple.com/documentation/avfaudio/avaudioconverter`

**[S8] Apple — MenuBarExtra**  
`https://developer.apple.com/documentation/swiftui/menubarextra`
