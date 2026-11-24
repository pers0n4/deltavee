# Interface Behavior

See the [Deltavee README](../README.md) for installation and [Collection Behavior](collection.md) for data sources, privacy, costs, and account risks.

## Panel Window

- Click the menu bar item to open or close the panel. Clicking outside, switching to another app, or switching Spaces also closes it.
- Escape closes the usage panel. From `Accounts` or `Settings`, Escape or `Back` returns to usage. Reopening the panel always shows usage.
- The panel accepts keyboard input, scrolls when needed, and keeps its bottom actions available. Transitions respect macOS Reduce Motion.
- `Refresh` runs immediately; `Accounts…` (`⇧⌘A`) and `Settings…` (`⌘,`) switch screens; `Quit Deltavee` quits the app.
- UI text, statuses, and dates use English. User-entered account labels are left unchanged.

## Update Notices

- `Check for Updates` checks for a new stable release. The app also checks at startup and every 24 hours. After a temporary failure, it retries after 30 minutes, up to twice per cycle. Drafts and prereleases do not produce notices.
- Checking, up to date, new release available, and check failed are distinct states, separate from usage refresh status. A failed or unavailable check does not mean the app is up to date; you can check again manually.
- Progress, up-to-date, and failure messages from a manual check appear below `Check for Updates` and clear when you close the panel. Closing the panel does not cancel the check.
- When a new release is available, a versioned GitHub link appears below `Check for Updates` and remains when you reopen the panel. You can still check again manually. The browser opens only when you select the link. Downloads and installation are manual; there are no automatic downloads or installations, macOS notification permission requests, or system banners. See the [README's installation instructions](../README.md).
- Update checks contact the public GitHub API for `pers0n4/deltavee`. They are separate from Claude usage collection and still run in `Statusline Only`. No credentials, tokens, usage data, or account information are sent. GitHub receives ordinary HTTPS request metadata, including your IP address and User-Agent.

## Menu Bar

- Each visible account shows its provider logo and weekly usage percentage. Logos and numbers adapt to the menu bar's light or dark appearance.
- `Color menu bar usage` adds a risk-colored dot before each percentage; it does not color the numbers or logos. The colors have the same meaning as the weekly graph below.
- A failed refresh appends `!`, as in `42%!`. A value more than 1 hour old is stale: without colored dots it uses secondary text color; with colored dots it has a hollow dot. Staleness alone does not add `!`.
- Tooltips and accessibility descriptions identify values more than 1 hour old. These rules also apply to restored values after startup and while waiting for a refresh after wake.

### Logo Sources and Trademarks

The logos identify account providers. Deltavee is not an official Anthropic or OpenAI app and does not imply affiliation, sponsorship, or endorsement by either company.

- Claude Spark comes from `Claude Spark - Clay.svg` in the [official Anthropic press kit](https://www.anthropic.com/press-kit). Deltavee uses a monochrome adaptation, changing its fill while preserving its shape and proportions. **Separate permission for this monochrome Spark adaptation is unconfirmed.**
- OpenAI Blossom comes from the white Blossom asset in the official OpenAI VS Code extension, `openai.chatgpt`.
- Claude, Claude Spark, and related trademarks belong to Anthropic; OpenAI, Blossom, and related trademarks belong to OpenAI. The project code license does not grant or sublicense permission to use these logos or trademarks.
- [Anthropic Trademark Guidelines](https://assets.claude.com/f7874b435aabdaee5f836e888b4439b9b56a934b.pdf) limit use to pre-approved materials, require supplied images without color or proportion changes, and prohibit misleading affiliation or endorsement. [Claude Code's name and logo guidance](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products) also requires written permission for separate use of the name or logo; whether that permission was obtained is unconfirmed.
- [OpenAI Design Guidelines and Usage terms](https://openai.com/brand/) require use directly related to its services, preservation of supplied originals, acknowledgment of OpenAI's ownership, and no greater prominence than one's own brand or misleading affiliation or sponsorship. Permission is non-exclusive, non-transferable, and revocable.

## Account Display

- Each account shows `Claude` or `Codex`, with an optional secondary label. Without a label, the sign-in email reported by the account's CLI appears there instead, if one is available; see [Local Data and Privacy](collection.md#local-data-and-privacy). Long labels are shortened at the end; long emails are shortened in the middle so the start and the domain stay visible. Tooltips and accessibility descriptions retain the full text.
- `Weekly quota` shows used or remaining percentage. Colors always reflect consumption: teal below 70% used, orange from 70% to below 90%, and red at 90% or more. In remaining mode these are more than 30%, more than 10% through 30%, and 10% or less remaining. Missing or invalid usage has no graph or dot. Other usage windows are not shown; see [Usage Interpretation](collection.md#usage-interpretation).
- `Resets` shows the quota reset time; `Updated` shows the original observation time, not the time a file was reread. Tooltips include full dates, the source, and the last successful read time.
- `Time Ago` shows elapsed observation time in minutes or larger units; observations less than 1 minute old show `just now`. `Countdown` rounds reset time up to minutes. After a reset time passes, `Reset time passed` appears rather than assuming usage is zero.
- Codex accounts with [banked resets](https://help.openai.com/en/articles/20001498-how-resets-work-in-codex) show a line such as `3 resets · Use by Dec 1, 5:22 AM`, following the `Reset time` setting (`Expires in …` with `Countdown`). The date is the earliest expiry among the resets Codex listed. Codex can list fewer resets than it counts; the line then reads `5 resets · 2 listed · Use by …`, and unlisted resets may expire sooner. Without expiry details, the line shows only the count, as in `3 resets available`. Once the listed expiry passes, the line reads `Last reported: 3 · Expiry passed` until the next successful read shows what remains. The tooltip has the full date. Accounts without banked resets, Claude accounts, and Codex CLIs that do not report resets show no line. Deltavee does not redeem resets; use Codex or ChatGPT for that.
- A failed account retains its last successful value and observation time with a failure marker. Without a successful history it shows `--`. Stale values also show `More than 1 hour old`.
- An account's refresh button refreshes only that account. While Claude accounts wait after a Claude OAuth rate limit, their refresh buttons are disabled and each shows `Rate limited · Resumes <time>` (or a countdown). Global `Refresh` skips waiting accounts and is disabled when all accounts are waiting. See [Claude OAuth 429 Wait](collection.md#claude-oauth-429-wait).

## Accounts and Settings Screens

### Shared Behavior

- Both screens open inside the panel. Changes take effect without `Save` or `Cancel`. Text fields apply on Return, Tab, loss of focus, or leaving the screen, not while typing.
- Display settings, names, ordering, and menu bar visibility do not restart collection. Changing collection settings or an account's directory, or adding or removing an account, does.

### Accounts Screen

- Choose `Claude` or `Codex` from `Add Account` to open the new account's settings. The app fills in the provider's default configuration directory. If the CLI account uses a different directory, replace the default with that path. The provider cannot be changed afterward; add another account to use another provider.
- Expand an account card to edit it; `⌘⌥E` expands or collapses all cards. The header switch controls menu bar visibility without expanding the card.
- Drag the left-hand handle to reorder accounts; the order applies when you release it. VoiceOver actions can move accounts up or down, and reordering respects Reduce Motion.
- `Label (optional)` adds a secondary label. Blank labels or labels matching the provider do not add another display line; the detected sign-in email is shown instead when available, and the empty field then reads `Blank uses the sign-in email`.
- A configuration directory is required. Clearing it shows a warning and keeps the last applied directory; a new account without a directory is not applied.
- `Remove Account…` requires an inline `Remove this account?` confirmation with `Cancel` and `Remove`.

### Settings Screen

`General` contains appearance, usage, time, and startup controls; `Data collection` contains refresh, Claude, and Codex controls. Accounts are managed separately on the `Accounts` screen.

| Control | Behavior |
| --- | --- |
| `Theme` | `System` (default), `Light`, or `Dark` for the panel and settings. Menu bar text follows the menu bar's own appearance. |
| `Translucent panel` | On by default; turn it off for an opaque panel background. |
| `Show usage as` | `Remaining` (default) or `Used`. Risk colors always reflect consumption. |
| `Color menu bar usage` | Off by default; enables colored dots and a usage-range legend. |
| `Reset time` / `Updated time` | Choose `Date & Time` or `Countdown` for resets, and `Date & Time` or `Time Ago` for observations. Tooltips retain absolute times. |
| `Clock format` | `System` (default), `12-Hour`, or `24-Hour`. Applies to displayed times and tooltips, not countdown durations. |
| `Launch at login` | Applies immediately. If macOS approval is needed, a warning links to Login Items. A failed change restores the actual state and shows guidance. |
| `Interval` | Refresh every 3, 5, 10 (default), 15, or 30 minutes. |
| Claude `Source` | `OAuth + Statusline` or `Statusline Only`; see [Claude Source Modes](collection.md#claude-source-modes) for fallback behavior, costs, and restrictions. |
| Claude / Codex `CLI path (optional)` | Override the executable for that provider; leave empty for automatic discovery. See [CLI Discovery and Configuration](collection.md#cli-discovery-and-configuration). |

The Claude and Codex cards have expandable `Terms and details` explaining collection and policy caveats. Credentials and account tokens are not displayed or editable here. Read [Provider Terms and Account Risk](collection.md#provider-terms-and-account-risk) before choosing a collection mode.
