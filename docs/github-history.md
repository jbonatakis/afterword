# GitHub history

Afterword puts your GitHub.com contributions alongside recordings and coding sessions in **All activity**. Each issue or pull request gets one entry. Open it to read your activity in chronological order or follow a timestamp to the original contribution on GitHub.

## Connect

1. Open **Settings → GitHub** and choose **Create a read-only token on GitHub**. The form requests read access for Issues and Pull requests. GitHub includes Metadata read access automatically.
2. Choose the **Resource owner** whose repositories you want, such as your employer’s organization. Choose **Only select repositories**, select the repositories and generate the fine-grained personal access token. Each token covers one resource owner. Organizations can restrict tokens or require approval before they can read private repositories. [GitHub’s fine-grained token guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
3. Paste the token into the secure field in Afterword and click **Connect with token**. Afterword verifies your GitHub account and saves the credential in your Mac login Keychain.
4. Under **Available repositories**, click **Import** beside each repository you want. The default import covers your last 90 days. To import older contributions, choose **All my available history** on that repository. You can search as soon as the first contributions arrive.

Use **Change connection…** to switch an existing GitHub App connection to a token or replace an expiring token. Use the same GitHub account to keep existing imports and sharing settings. If the replacement loses access to an imported repository, Afterword lists the affected repositories and asks before deleting their local history and sharing grants. You can keep the current connection instead.

### Connect through a GitHub App

Choose **GitHub App** under **Connect with**, then **Connect GitHub App**. Choose **Copy code and open GitHub**, sign in, and enter the device code. Afterword saves expiring user credentials in Keychain and renews them while it runs. Your account and an installation of the app both need access to a repository for it to appear. Click **Refresh** after changing the installation.

If Connect reports `device_flow_disabled`, edit the existing GitHub App registration. Under **Identifying and authorizing users**, select **Enable Device Flow**, save, and retry **Connect GitHub App** in Afterword. Older builds display this as HTTP 400. [GitHub App registrations](https://github.com/settings/apps)

#### Register an app for a development build

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

Afterword verifies repository access at startup, on refresh, and about every 15 minutes while running. It resumes interrupted pages from the local SQLite archive in `~/Library/Application Support/Afterword/GitHub`. Overlapping searches and a periodic replay pick up late arrivals, edits, and deletions. A partial or rate-limited import keeps its last successful checkpoint. An existing entry stays in history as it ages beyond the initial 90-day window.

**Pause sync** keeps a repository searchable and still checks access. **Remove** deletes its local history and agent grant. **Disconnect and remove history** removes every imported repository and the Keychain credential. Offline reads show the saved snapshot and its last access check. A verified loss of repository access removes the local copy on the next check. An expired or revoked personal token, or an invalid GitHub App refresh credential, locks history and clears sharing. Reconnect the same account and choose what to share again.

GitHub repositories start private to the native library. To give a connected agent access, enable **Settings → Agent Access** and explicitly share each repository. A running MCP client picks up grant changes on its next request. [MCP tools and examples](mcp.md#github-activity)

## Verify a live connection

For release qualification, select one repository where you can identify an issue or PR you opened, a comment on someone else’s item, an approval, and an inline reply. Compare their text, dates and permalinks against the timeline. Check an item where you were only mentioned and search for a distinctive phrase written by a teammate. Record the time to the first searchable item and the completed import for that repository alongside its size and chosen import depth.

For a personal token, replace it through **Change connection…** and confirm that the access-check timestamp advances. For a GitHub App, use **Refresh** after the initial access token expires and confirm that it renews without another device prompt. Share one repository, open a citation with an MCP client, then turn sharing off and repeat the direct read in the same client. For access-removal testing, use a disposable repository and confirm a refresh removes it from the library.
