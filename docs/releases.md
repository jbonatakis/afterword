# Releasing Afterword

Each push to `main` updates one draft in GitHub Releases. Its tag targets the checked-out commit, and its notes list commits since the previous published version, including direct pushes. You can add release highlights above or below the generated notes. On the first release, the notes cover the repository history.

Click **Publish release** on the draft to start the Apple Silicon build. The ZIP appears on that release when the build succeeds. If a build fails, fix any missing credentials and rerun the failed job in Actions. The build uses the published tag's commit on each attempt.

## Choosing the version

The first planned release is **v0.16.0**. After it ships, the next push drafts **v0.16.1** automatically. Further pushes update that same draft until you publish it.

- Use a **patch** for fixes and performance improvements. The workflow increments this automatically from the highest published stable version on `main`.
- For a feature release, set `CFBundleShortVersionString` in `Configuration/Info.plist` to the next **minor** version, such as `0.17.0`, and push. The draft picks up the new version.
- Choose a **major** deliberately, for example `1.0.0` for the first stable release or `2.0.0` for a later incompatible change.

The published tag supplies the app's version. The number of commits reachable from the tagged commit supplies its build number, which stays the same on retries.

## GitHub Actions setup

In **Settings → Secrets and variables → Actions**, add these repository secrets before publishing the first draft.

| Secret | Value |
| --- | --- |
| `LOOKBACK_READ_TOKEN` | A fine-grained token with **Contents: Read-only** access to the private `jbonatakis/lookback` repository. SwiftPM uses the revision pinned by Afterword. |
| `MACOS_SIGNING_P12_BASE64` | Base64-encoded PKCS#12 export containing the **Developer ID Application** certificate and its private key. |
| `MACOS_SIGNING_P12_PASSWORD` | The password used to encrypt that export. |

If your release bundles a GitHub OAuth client ID, set the repository **variable** `AFTERWORD_GITHUB_CLIENT_ID`. Release immutability must be off for this publish-then-upload flow because GitHub locks assets when an immutable release is published. [GitHub release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

The workflow produces a Developer ID–signed `Afterword-vX.Y.Z-macOS-arm64.zip` with a deployment target of macOS 14.2. Apple notarization is a separate distribution step. To exercise the same packaging path locally on Apple Silicon, run `./Scripts/build-release.sh v0.16.0` with your usual signing identity. The ZIP is written to `build/release/`.
