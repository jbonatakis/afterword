# GitHub history

Afterword puts your GitHub.com contributions alongside recordings and coding sessions in **All activity**. Each issue or pull request gets one entry. Open it to read your activity in chronological order or follow a timestamp to the original contribution on GitHub.

## Connect

1. Open **Settings → GitHub → Connect GitHub**. If this build asks for a GitHub App client ID, follow the registration steps below first.
2. Choose **Copy code and open GitHub**, sign in to the account whose history you want, and enter the device code. Afterword saves expiring user credentials in the Mac login Keychain and renews them while it runs.
3. Under **Available repositories**, choose **Import** beside each repository you want. A repository must be accessible to both your account and an installation of the GitHub App. An organization owner may need to approve or install it. Use **Refresh** after changing an installation.
4. The default import covers your actions in the last 90 days. Choose **All my available history** on an individual repository to backfill older actions. You can search as soon as the first contributions arrive.

### Register an app for a development build

A distributor can register one GitHub App and include its **Client ID** in every build. For a personal build, **Register a read-only GitHub App** opens a prefilled registration form. Choose a unique name, enable **Device Flow**, keep expiring user authorization tokens enabled, and register the app. The repository permissions are read-only **Issues**, **Pull requests**, and the automatic **Metadata** permission. Leave webhooks disabled. Select **Install App** on its settings page and choose the account and repositories. Copy the **Client ID** from the app’s General settings into Afterword. A secret or private key is unnecessary for this flow. [GitHub device authorization](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow-to-generate-a-user-access-token) · [GitHub token renewal](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens#refreshing-a-user-access-token-with-a-refresh-token)

To package a registered app’s public ID with the signed executable, run:

```sh
AFTERWORD_GITHUB_CLIENT_ID='your-public-client-id' ./Scripts/build-app.sh
```

## Read and search

- An item you opened includes its description. A teammate’s item includes its title, author, state and permalink when you contributed. Your comments, submitted reviews, approvals without text, and published inline replies appear in the timeline. Inline comments include the file and original line when available. Mentions and assignments alone create no entry.
- The **GitHub** sidebar and toolbar search options filter by repository, issue or PR, contribution, and activity date. **Reviewed** with **Last week** uses your review’s submission date even when the PR is years old.
- Search for a GitHub URL or `owner/repo#42` to jump to an exact item. Select a repository first to search for `#42`. A qualified reference in a saved call summary or a coding message can open an imported item in the library.
- Keyword search works immediately. Enabling a local model in **Settings → Search** also indexes your saved GitHub passages. The repository’s sync status and the model’s embedding progress are reported separately.

## Sync and access

Afterword checks installations at startup, on refresh, and about every 15 minutes while running. It resumes interrupted pages from the local SQLite archive in `~/Library/Application Support/Afterword/GitHub`. Overlapping searches and a periodic replay pick up late arrivals, edits, and deletions. A partial or rate-limited import keeps its last successful checkpoint. An existing entry stays in history as it ages beyond the initial 90-day window.

**Pause sync** keeps a repository searchable and still checks installation access. **Remove** deletes its local history and agent grant. **Disconnect and remove history** removes every imported repository and the Keychain credential. Offline reads show the saved snapshot and its last access check. A verified loss of repository access removes the local copy on the next check. An invalid refresh credential locks history and clears sharing until you reconnect the same account and choose what to share again.

GitHub repositories start private to the native library. To give a connected agent access, enable **Settings → Agent Access** and explicitly share each repository. A running MCP client picks up grant changes on its next request. [MCP tools and examples](mcp.md#github-activity)

## Verify a live installation

For release qualification, select one repository where you can identify an issue or PR you opened, a comment on someone else’s item, an approval, and an inline reply. Compare their text, dates and permalinks against the timeline. Check an item where you were only mentioned and search for a distinctive phrase written by a teammate. Record the time to the first searchable item and the completed import for that repository alongside its size and chosen import depth.

After the initial access token expires, use **Refresh** and confirm the access-check timestamp advances without another device prompt. Share one repository, open a citation with an MCP client, then turn sharing off and repeat the direct read in the same client. For installation-removal testing, use a disposable repository and confirm a refresh removes it from the library.
