# Collection Behavior

How Deltavee reads usage, handles failures, and uses local credentials. See the [README](../README.md) for installation and setup, and [Interface Behavior](interface.md) for display behavior.

## Collection Paths by Provider

| Provider | Usage source | Credential boundary |
| --- | --- | --- |
| Codex | The official Codex CLI's app-server usage reporting | Deltavee does not read or write `auth.json`. The launched CLI may refresh its own credentials. |
| Claude | An unofficial Anthropic OAuth usage endpoint, with local statusline observations as a fallback | Outside Statusline Only mode, Deltavee reads the CLI's credentials from macOS Keychain, falling back to the account directory's `.credentials.json`. It does not use refresh tokens or write credentials back; it may launch the official CLI to refresh an expired token, as described below. |

## Provider Terms and Account Risk

> [!WARNING]
> Anthropic does not allow developers to collect, store, or proxy Claude.ai credentials or session tokens ([Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)) and states that it may enforce this restriction without prior notice. Deltavee's default Claude mode reads your own CLI credentials on your Mac and calls an unofficial endpoint. Whether this use is permitted under the terms has not been confirmed. There is no guarantee against account suspension.

A more conservative option is `Settings… → Data collection → Claude → Statusline Only`, which uses local observations from [official statusline data](https://code.claude.com/docs/en/statusline#available-data) without reading tokens or making direct provider requests. It cannot update without CLI observations and does not guarantee zero account risk. Switching modes is your choice; existing settings are not changed automatically.

Codex uses the [official app-server's usage reporting](https://learn.chatgpt.com/docs/app-server#auth-endpoints). OpenAI's documentation permits continued app-server authentication for local or open-source apps, but not commercial or hosted services. This does not exempt individual accounts from sanctions. Review authentication conditions and logo trademark terms before distributing or commercializing the app.

## Usage Interpretation

- **Weekly usage only:** Deltavee displays one weekly quota per account, not 5-hour or per-model limits. A provider may report the weekly quota as unavailable. An unexpected response format is reported as an error.
- **Stale values:** A value becomes stale after 1 hour without a new observation. Rereading an old statusline file does not make it current.
- **Failures:** A failed fetch keeps the previous observation unless a newer local statusline observation is available. Showing a newer statusline value does not clear the failure. If credentials are missing or rejected, sign in through the CLI.
- **Account changes:** When Deltavee detects a different account in the same configuration directory, it asks you to confirm in the panel before showing that account's usage. `Statusline Only` does not detect account changes.

## Claude OAuth 429 Wait

If Anthropic rate-limits an OAuth usage request, Deltavee waits before trying again, honoring the longer of its backoff and the server's requested wait (the server wait is capped at 24 hours). Refresh, other settings changes, app restarts, and waking the Mac do not bypass this wait. Changing an account's configuration directory clears the wait associated with the previous directory. `Statusline Only` does not use the endpoint; switching to it preserves any pending wait for a later return to OAuth mode.

See [Account Display](interface.md#account-display) for how waiting accounts appear.

## Claude Source Modes

Choose a mode in `Settings… → Data collection → Claude`:

- **OAuth + Statusline** (default): Tries the unofficial OAuth usage endpoint first, then falls back to local statusline observations on failure.
- **Statusline Only:** Reads only local statusline observations. It does not read credentials, run the Claude CLI, or send Claude usage requests.

Statusline Only controls Claude usage collection, not all app networking. Deltavee can still make separate app update-check requests; see [Update Notices](interface.md#update-notices).

## Claude Token Expiration and CLI Refresh

When an OAuth access token has expired, Deltavee shows `Token expired — run claude to refresh:` and the account's command. You can run that command in Terminal; signing in again is not normally necessary just because the token expired.

In `OAuth + Statusline`, Deltavee also tries to refresh the token by launching the account's Claude CLI in the background. **Each attempt can send a Haiku model request and consume usage.** Deltavee disables tools, session persistence, user settings (including hooks and plugins), MCP servers, and slash commands for this run. The CLI may still create local project state. Each attempt has a 60-second timeout.

The next scheduled fetch rereads credentials; a completed CLI process alone does not prove refresh succeeded. For the same account and expired token, Deltavee allows an initial run and up to 3 retries, at least 30 minutes apart, then leaves the manual instructions visible. Restarting the app resets this attempt count.

Automatic refresh does not run in Statusline Only mode or when the Claude executable is unavailable.

This also works with a mise-installed Claude Code CLI. If automatic discovery does not find it, [set the CLI path](#cli-discovery-and-configuration). With a valid CLI login, a successful background refresh lets Deltavee resume fetching the weekly quota without an interactive session.

## Set Up Claude Code CLI for Desktop Users

Deltavee does not read usage directly from Claude Desktop. If you only use Desktop, install the [Claude Code CLI](https://code.claude.com/docs/en/quickstart#step-1-install-claude-code) in addition to the desktop app:

- **[Anthropic standalone installer](https://code.claude.com/docs/en/quickstart#step-1-install-claude-code):** `curl -fsSL https://claude.ai/install.sh | bash`
- **[Homebrew cask](https://formulae.brew.sh/cask/claude-code):** `brew install --cask claude-code`
- **[mise](https://mise.jdx.dev/registry.html):** `mise use -g claude@latest`

Run `claude` in Terminal and sign in with the same Claude subscription account you use in Desktop. You can keep working in Desktop: for [Pro, Max, and Ultra](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-max-or-ultra-plan), Claude and Claude Code share the account's subscription limits. Deltavee shows the shared weekly quota, not a Desktop-only breakdown.

In `OAuth + Statusline`, Deltavee polls the account's quota while the CLI login is valid; no interactive CLI session is required. [Automatic token refresh](#claude-token-expiration-and-cli-refresh) can consume usage, and you may need to use Terminal if refresh fails or the login is rejected. See [Provider Terms and Account Risk](#provider-terms-and-account-risk) for the unofficial OAuth endpoint.

If you choose `Statusline Only`, also [configure the statusline hook](../README.md#configuring-the-claude-statusline-hook) and run interactive Claude Code sessions in Terminal to produce new observations. The supported setup does not rely on Desktop to trigger the hook.

If you prefer not to install the CLI, check your quota manually in [Claude → Settings → Usage](https://claude.ai/settings/usage).

## Install Codex CLI Without Node.js

If you only use Codex in the ChatGPT desktop app, install the Codex CLI separately for Deltavee. The following options install a native CLI without Node.js:

- **[OpenAI standalone installer](https://github.com/openai/codex#quickstart):** Run `curl -fsSL https://chatgpt.com/codex/install.sh | sh`. The default executable path is `~/.local/bin/codex`.
- **[Homebrew cask](https://formulae.brew.sh/cask/codex):** Run `brew install --cask codex`. The cask installs OpenAI's native CLI in Homebrew's `bin` directory.
- **[mise](https://mise.jdx.dev/registry.html):** `mise use -g codex@latest`

Run `codex login` in Terminal and use the same ChatGPT account and, if applicable, workspace as in Codex on Desktop. You can keep working in Desktop: Deltavee runs `codex app-server` to read the account's [Codex usage limits](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan), without an interactive CLI session. It does not read the Desktop app directly or report Desktop-only usage. If the plan does not report a weekly quota, Deltavee cannot display one.

Run `codex --version` to check the installation. If you have more than one Codex installation, set `CLI path (optional)` to the native executable's absolute path to avoid selecting an older npm launcher.

## CLI Discovery and Configuration

Deltavee looks for installed CLIs in Homebrew locations, `~/.local/bin`, and its execution environment's `PATH`, including when launched from Finder or a login item. Under `Settings… → Data collection`, Claude and Codex each have an app-wide `CLI path (optional)` setting. Leave a field empty for automatic discovery. An explicit path never falls back to another executable.

For Claude, the path selects the CLI for version checks and automatic token refresh. In `Statusline Only`, Deltavee does not launch it.

If you installed either CLI with mise and Deltavee cannot discover it, run `mise which claude` or `mise which codex` in Terminal and paste the resulting absolute path into the corresponding `CLI path (optional)` field. Update the setting if the installed path changes.

If Deltavee reports `Codex cannot find Node.js`, the selected launcher could not find Node in the app's environment. Install the native CLI above or choose a Codex executable that can run without shell initialization.

For either CLI, Deltavee adds the selected executable's directory to the child process's `PATH` without following symlinks. This lets a launcher find `node` installed alongside it. Deltavee does not load shell startup files. If a launcher or shim needs Node in a different directory or depends on shell initialization, setting the path alone may not be sufficient.

Set each account's config directory in Deltavee's account settings; these control `CODEX_HOME` and `CLAUDE_CONFIG_DIR` for launched CLIs. Shell API-key, OAuth-token, and custom-endpoint environment variables do not override the app's CLI authentication or endpoints. Standard proxy and locale settings can be inherited.

## Local Data and Privacy

Deltavee stores account settings, usage snapshots, rate-limit waits, statusline observations, and token-refresh logs in `~/Library/Application Support/dev.pers0n4.deltavee/`. It does not store tokens there.

The local token-refresh log records attempts and outcomes and **can contain account IDs and config-directory paths**. It does not log tokens, prompts, or CLI output. The statusline capture helper saves only weekly usage percentages, reset times, and observation time—not the full statusline input or conversation contents—and does not call provider APIs.

## Claude Statusline Observations

The capture helper runs from Claude Code's `statusLine.command`, not session-event hooks. Enable it as described in [Configuring the Claude Statusline Hook](../README.md#configuring-the-claude-statusline-hook).

Statusline values update only when Claude Code supplies new usage observations. Deltavee's **Refresh** rereads the saved file; it cannot ask the server for newer values in Statusline Only mode. If no observation exists, the app shows `Statusline hook not installed or no data`, rather than asking you to sign in.

## Refresh after Wake

Deltavee restarts collection 5 seconds after the Mac wakes, allowing time for networking to reconnect. Repeated wake notifications restart that delay rather than creating duplicate fetches. The display may show the old value as stale before collection finishes.

After success, collection returns to the configured interval. Failures increase the interval up to 30 minutes; a pending Claude rate-limit wait still applies. Statusline Only still needs new CLI observations, even after wake.
