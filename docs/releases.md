# Releasing Afterword

## Install with Homebrew

Use an Apple Silicon Mac running macOS 14.2 or later. Homebrew downloads the app from the public tap and verifies its SHA-256 checksum. The ZIP includes Lookback.

```sh
brew install --cask jbonatakis/tap/afterword
```

If you have a manually installed `/Applications/Afterword.app`, quit it and move that bundle out of Applications before installing the cask. To upgrade a Homebrew installation, run `brew update` followed by `brew upgrade --cask jbonatakis/tap/afterword`.

## Publish a release

Each push to `main` updates one draft in GitHub Releases. Its tag targets the checked-out commit, and its notes list commits since the previous published version, including direct pushes. You can add release highlights above or below the generated notes. On the first release, the notes cover the repository history.

Click **Publish release** on the draft to start the Apple Silicon build. The ZIP appears on that release when the build succeeds. If a build fails, fix any missing credentials and rerun the failed job in Actions. The build uses the published tag's commit on each attempt.

## Choosing the version

The first planned release is **v0.16.0**. After it ships, the next push drafts **v0.16.1** automatically. Further pushes update that same draft until you publish it.

- Use a **patch** for fixes and performance improvements. The workflow increments this automatically from the highest published stable version on `main`.
- For a feature release, set `CFBundleShortVersionString` in `Configuration/Info.plist` to the next **minor** version, such as `0.17.0`, and push. The draft picks up the new version.
- Choose a **major** deliberately, for example `1.0.0` for the first stable release or `2.0.0` for a later incompatible change.

The published tag supplies the app's version. The number of commits reachable from the tagged commit supplies its build number, which stays the same on retries.

## GitHub Actions setup

The build uses the repository secret `LOOKBACK_READ_TOKEN`. Use a fine-grained token with read-only access to the contents of the private `jbonatakis/lookback` repository. SwiftPM uses the revision pinned by Afterword.

For stable releases, the workflow verifies the private release ZIP against GitHub's SHA-256 and sends it to a temporary branch in `jbonatakis/homebrew-tap` using `HOMEBREW_TAP_DEPLOY_KEY`. The tap's **Publish Afterword** workflow verifies the bytes, publishes the ZIP as a release asset, updates `Casks/afterword.rb` and removes the temporary branch. Published versions retain their checksum. Use a new version for a changed binary. To resync the latest stable release, choose **Actions → Release → Run workflow** on Afterword's `main`.

If your release bundles a GitHub OAuth client ID, set the repository **variable** `AFTERWORD_GITHUB_CLIENT_ID`. Release immutability must be off for this publish-then-upload flow because GitHub locks assets when an immutable release is published. [GitHub release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

The workflow packages `Afterword-vX.Y.Z-macOS-arm64.zip` for macOS 14.2 and later. It uses ad-hoc signatures for the app and its helpers, which you can create without an Apple Developer account. To build the same ZIP locally on Apple Silicon, run `./Scripts/build-release.sh v0.16.0`. The ZIP is written to `build/release/`.

On first launch, macOS may flag a downloaded release as coming from an unidentified developer. After attempting to open a copy you trust, you can approve that app in **System Settings → Privacy & Security → Open Anyway**. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)
