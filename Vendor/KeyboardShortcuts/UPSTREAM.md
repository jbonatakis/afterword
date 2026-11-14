# KeyboardShortcuts

Source: https://github.com/sindresorhus/KeyboardShortcuts

Version: 3.1.0, commit `772133d9dbe800fdac0473226822994c5c162c58`.
License: MIT; see `license`. Requires Swift 6.2 to build; runtime supports macOS 10.15+.

`Package.swift`, `Sources`, and `Tests` are vendored from that revision.
Build adaptations replace `@Entry` in `ConflictPolicy.swift` with the equivalent
explicit `EnvironmentKey` implementation and gate the three design-time previews
in `Recorder.swift` behind `CALL_RECORDER_XCODE_PREVIEWS`. Apple's standalone
Command Line Tools do not ship the macro plugins required by those features.
`Utilities.swift` first finds the localization bundle in the app's Resources
directory, then falls back to SwiftPM's generated accessor. This allows a signed
app assembled by the command-line build script to run outside the build tree.
Shortcut handling, storage, recorder controls, resource contents, and tests are unchanged.
