# Build and test Afterword

## Build the app

Use a Mac with Swift 6.2 or later, the macOS 26 SDK, Git, uv, and a local Python 3.12 installation that uv can discover. Git needs read access to the private Lookback dependency pinned in `Package.swift`. Run these commands from the repository root. [uv installation](https://docs.astral.sh/uv/)

```sh
./Scripts/setup-local-signing.sh
./Scripts/build-app.sh
open build/Afterword.app
```

Run the signing setup once per Mac. Quit a running copy before launching the new build. The build script fetches pinned native sources and speaker models, caches build tools and artifacts under `build/`, embeds the transcription, embedding, speaker, and MCP helpers, and verifies the signed bundle. After installation, local transcription uses the bundled workers and an installed speech model. Python and uv are build dependencies.

The local signing script creates a self-signed identity named **Call Recorder Local Development** in your login keychain and trusts it for code signing. The app's bundle ID is `io.local.afterword`. Reusing the certificate lets macOS recognize successive builds for privacy permissions. To use an existing Apple-issued identity instead of running local signing setup, set the identity on the build command.

```sh
SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' ./Scripts/build-app.sh
```

To check update identity between two different locally signed builds, run `python3 Scripts/check-signing.py '/path/to/Previous.app' '/path/to/Updated.app'`. For the ad-hoc signed Apple Silicon release ZIP, publishing workflow, and Actions credentials, use the [release guide](releases.md).

### Build with Xcode

Open `Afterword.xcodeproj` in Xcode 26 or later and select the shared **Afterword** scheme. The same scheme also supports command-line builds and tests.

```sh
xcodebuild -project Afterword.xcodeproj -scheme Afterword \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/xcode build
xcodebuild -project Afterword.xcodeproj -scheme Afterword \
  -destination 'platform=macOS' -derivedDataPath build/xcode test
```

The project defaults to the same local signing identity. If using another certificate, set `CODE_SIGN_IDENTITY` consistently. Regenerate the checked-in project after adding or removing source or test files with `python3 Scripts/generate-project.py`.

### Migrate an installation named Call Recorder

Quit the old app and its MCP helpers. Run `python3 Scripts/migrate-afterword-data.py` before opening Afterword. It moves support and cache directories and copies preferences into the new domain. Recording folders stay in place. If both installations already have data, the script refuses to merge them. Grant permissions to the new app when prompted and update any MCP clients to use the new bundle's `Contents/Helpers/AfterwordMCP`.

## Run checks

| Command | What it exercises |
| --- | --- |
| `./Scripts/test.sh` | Core tests through XCTest with full Xcode, or the same test bodies through the Command Line Tools adapter |
| `./Scripts/check-library.sh` | Library UI, editing, playback, and file management using generated recordings |
| `./Scripts/check-library.sh --sources` | Source configuration, sidebar navigation, and search |
| `./Scripts/check-calendar-integration.sh` | Calendar connection, reminders, attendance, and settings with fixture calendars |
| `./Scripts/check-echo.sh` | Native echo processing, including silence, overlapping speech, and failures |
| `./Scripts/run-crash-test.sh` | Interrupted synthetic recording, recovered audio, track order, and duration |
| `./Scripts/check-library.sh Tests/SummaryRefreshHarness.swift` | Changes to saved summaries and watched folders from another process |

The library and calendar fixtures render offscreen by default. For focus and scrolling checks, run `./Scripts/check-library.sh --interactive`. The dedicated foreground keyboard fixture is `./Scripts/check-library.sh Tests/LibraryKeyboardHarness.swift`. Test the configurable global shortcut with `./Scripts/check-shortcut.sh`. If AAC encoding fails with `fmt?` in a development sandbox, rerun the test in Terminal with access to the system audio codec service.

After building the app, exercise model download, inference, and cancellation with the public speech sample and a separate model directory.

```sh
mkdir -p build/asr-smoke
cp build/vendor/transcribe.cpp/samples/jfk.wav build/asr-smoke/Test.wav
./Scripts/check-transcription.sh download whisper-base.en build/asr-models
./Scripts/check-transcription.sh run whisper-base.en build/asr-models build/asr-smoke/Test.wav
./Scripts/check-transcription.sh cancel whisper-base.en build/asr-models build/asr-smoke/Test.wav
```

The model download needs network access. Recognition runs locally and writes under `build/asr-smoke/Transcripts/`. For integration and retrieval checks, see [MCP verification](mcp.md#verification) and the [search quality benchmark](search-quality.md).

### Check real devices and calendars

Run `./Scripts/check-layout.sh` to list inputs. Pass a listed index, for example `./Scripts/check-layout.sh 1`, to prepare and tear down that input. For a live check, `./Scripts/check-capture.sh --preview 0` runs three short in-memory previews on input 0 and writes numeric diagnostics to `build/capture-check.log`. It requests microphone and system-audio permissions under a separate diagnostic app identity.

The Calendar probe also has its own permission grant. List calendar IDs before selecting a calendar and search term for a read-only scan. Reports contain matching event titles and attendee details and belong in the Git-ignored build directory.

```sh
./Scripts/check-calendar.sh --list --output "$PWD/build/calendar-spike/calendars.json"
./Scripts/check-calendar.sh --scan --calendar '<selected-calendar-id>' \
  --match '<person or group>' --output "$PWD/build/calendar-spike/events.json"
```

The hardware acceptance work includes real Meet, Zoom, or Teams calls, separation and microphone mute during overlapping speech, device changes and disconnection, and permission revocation. Timing and endurance targets include measuring initial offset and drift over two hours, checking four-hour capture and export, and repeating live starts and stops. Sleep, low disk space, removable destinations, and interruption during real capture also need hardware validation. The macOS 14.2 deployment target still needs runtime qualification on that version. The original specification gives the measurement criteria. [Hardware acceptance tests](spec-v1.1.md#real-macoshardware-tests)
