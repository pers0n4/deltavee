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
- **Failures:** A failed fetch preserves the last successful value and its observation time. Missing credentials or a rejected login require signing in through the CLI; available statusline observations can still be shown.
- **Account changes:** If you sign in to a different account in the same directory, Deltavee asks you to accept the change in the panel before mixing in the new account's values.

## Claude OAuth 429 Wait

If Anthropic rate-limits an OAuth usage request, Deltavee waits before trying again, honoring the longer of its backoff and the server's requested wait (the server wait is capped at 24 hours). Refresh, settings changes, app restarts, and waking the Mac do not bypass this wait. Statusline Only does not use the endpoint; switching to it preserves any pending wait for a later return to OAuth mode.

See [Account Display](interface.md#account-display) for how waiting accounts appear.

## Claude Source Modes

Choose a mode in `Settings… → Data collection → Claude`:

- **OAuth + Statusline** (default): Tries the unofficial OAuth usage endpoint first, then falls back to local statusline observations on failure.
- **Statusline Only:** Reads only local statusline observations. It does not read credentials, run the Claude CLI, or send Claude usage requests.

Statusline Only controls Claude usage collection, not all app networking. Deltavee can still make separate app update-check requests; see [Update Notices](interface.md#update-notices).

## Claude Token Expiration and CLI Refresh

When an OAuth access token has expired, Deltavee shows `Token expired — run claude to refresh:` and the account's command. You can run that command in Terminal; signing in again is not normally necessary just because the token expired.

In OAuth + Statusline mode, Deltavee also tries to refresh the token automatically by launching the account's official Claude CLI in the background. **Each run makes a Haiku model request and consumes that request's usage.** It disables tools, session persistence, user settings (including hooks and plugins), MCP servers, and slash commands. The CLI may still create local project state for these refresh runs. Each run has a 60-second timeout.

The next scheduled fetch rereads credentials; a completed CLI process alone does not prove refresh succeeded. For the same account and expired token, Deltavee allows an initial run and up to 3 retries, at least 30 minutes apart, then leaves the manual instructions visible. Restarting the app resets this attempt count.

Automatic refresh does not run in Statusline Only mode or when the Claude executable is unavailable.

## CLI Discovery and Configuration

Deltavee looks for installed CLIs in Homebrew locations, `~/.local/bin`, and its execution environment's `PATH`, including when launched from Finder or a login item. Codex also has an app-wide `Settings… → Data collection → Codex → CLI path (optional)` setting. An invalid explicit path is an error, not a reason to use another executable. Claude has no separate executable-path setting.

Set each account's config directory in Deltavee's account settings; these control `CODEX_HOME` and `CLAUDE_CONFIG_DIR` for launched CLIs. Shell API-key, OAuth-token, and custom-endpoint environment variables do not override the app's CLI authentication or endpoints. Standard proxy and locale settings can be inherited.

## Local Data and Privacy

Deltavee stores account settings, usage snapshots, rate-limit waits, statusline observations, and token-refresh logs in `~/Library/Application Support/dev.pers0n4.deltavee/`. It does not store tokens there.

The local token-refresh log records attempts and outcomes and **can contain account IDs and config-directory paths**. It does not log tokens, prompts, or CLI output. The statusline capture helper saves only weekly usage percentages, reset times, and observation time—not the full statusline input or conversation contents—and does not call provider APIs.

## Claude Statusline Observations

The capture helper runs from Claude Code's `statusLine.command`, not session-event hooks. Install it using [Configuring the Claude Statusline Hook](../README.md#configuring-the-claude-statusline-hook).

Statusline values update only when Claude Code supplies new usage observations. Deltavee's **Refresh** rereads the saved file; it cannot ask the server for newer values in Statusline Only mode. If no observation exists, the app shows `Statusline hook not installed or no data`, rather than asking you to sign in. After a manual app update, also copy the bundled helper as described in the setup instructions.

## Refresh after Wake

Deltavee restarts collection 5 seconds after the Mac wakes, allowing time for networking to reconnect. Repeated wake notifications restart that delay rather than creating duplicate fetches. The display may show the old value as stale before collection finishes.

After success, collection returns to the configured interval. Failures increase the interval up to 30 minutes; a pending Claude rate-limit wait still applies. Statusline Only still needs new CLI observations, even after wake.
