# CodexUsage

A native menu bar app for macOS 14 or later. Displays your **remaining weekly Codex allowance**, time until it resets, and available reset credits: `C 61% · 3d 19h · 1R`.

## Build and run

Requirements: Swift 6, Xcode Command Line Tools or Xcode, and a local Codex installation signed in with a ChatGPT account. The app has no external package dependencies.

```sh
./scripts/build-app.sh --open
```

The script builds for your Mac's architecture and creates `dist/CodexUsage.app`, including an icon and a local ad hoc code signature. The bundle identifier is `com.dilongdann.CodexUsage`. The generated app is not notarized for public distribution.

After building, double-click the app in Finder or run:

```sh
open dist/CodexUsage.app
```

You can copy the app to `/Applications` to keep it outside the development folder and enable **Launch at login** in Settings. If macOS requires approval, the app provides a link to Login Items settings. Launch at login is off by default.

## Features

- General weekly allowance, identified by a 10,080-minute window in the `codex` usage group.
- Available reset-credit count in the menu bar (`1R`, `0R`); omitted if Codex has not supplied the count.
- Additional account limits, such as Reserve and Codex Spark, with remaining percentages, countdowns, and exact reset dates in your time zone.
- Plan, additional credit balance, and available reset credits with expiration dates, when provided by Codex.
- Lifetime tokens, daily peak, usage streaks, longest turn, and a chart of the last 30 available activity dates.
- Last update time, manual refresh, Open Codex, Settings, and Quit. The interface is entirely in English, follows the system appearance, and includes accessibility labels.

Missing fields appear as unavailable, never as zero. The reset count reported by the service takes precedence over the number of detail rows, which may be capped. Additional credit balances are shown in the unit returned by the service, without conversion to money. The longest-turn metric represents a single turn reported by the service, not an entire conversation.

## How it connects

The app starts a local `codex app-server --listen stdio://` process, communicates through JSON-RPC, and closes the process after each refresh. It only sends `initialize`, `initialized`, `account/read`, `account/rateLimits/read`, and `account/usage/read` messages.

Automatic detection prioritizes the executable bundled with Codex or ChatGPT, then Homebrew and common CLI locations. You can also choose an executable in Settings. During local validation, the bundled executable at `/Applications/ChatGPT.app/Contents/Resources/codex` (0.153.4) provided limits, reset credits, and activity. The Homebrew CLI (0.137.0) provided limits but did not expose those optional statistics. Availability depends on the installed Codex version and the account. CodexUsage does not update or modify your Codex installation.

The app uses the selected Codex installation's current sign-in and inherits `CODEX_HOME` when set. A normal Finder launch uses Codex's default home directory. API-key-only accounts are shown an explanation that these usage limits require a ChatGPT sign-in. Codex handles its own credential storage and refresh.

Automatic refresh runs every five minutes, configurable to one or fifteen minutes. The app also refreshes after waking, when opening the panel with a reading more than a minute old, and when a usage window or reset credit expires. Each request has a 15-second timeout. Refreshes never overlap. Countdowns update locally every ten seconds without additional network requests.

If a refresh fails, the last successful reading remains in memory and the menu bar displays `!`. When Codex reports a different account or a signed-out session, the previous reading is cleared. An expired reset stays **Pending** until a fresh reading arrives; the app never assumes the allowance has returned to 100%. Activity errors do not prevent usage limits from being displayed.

## Privacy and scope

CodexUsage does not read conversations, session history, browser cookies, or local usage history. It does not manage passwords, copy credentials, or redeem reset credits. It has no telemetry of its own. Only the refresh interval and executable path are saved in UserDefaults; account metrics remain in memory. Displayed errors are normalized to avoid exposing sensitive server responses.

Build artifacts in `.build/` and `dist/` are excluded by `.gitignore`. They can contain local compilation paths and should not be committed to the source repository. Test fixtures use fictional accounts and do not contain credentials.

## Validation

```sh
swift test
swift run CodexUsage --check
```

`--check` uses the same connection as the interface and exits with status 0 when it successfully retrieves usage limits. Its output includes a limit summary and statistics availability, without email addresses, account identifiers, or credentials. To check a specific Codex installation:

```sh
swift run CodexUsage --check --codex /opt/homebrew/bin/codex
```

Tests use a local mock JSON-RPC server, with Python 3 from the Xcode tools, without accessing your account. They cover fragmented responses, interleaved notifications, expired authentication, disconnections, timeouts, cancellation and child-process cleanup, optional metrics, usage windows, and time formatting.

## Project structure

- `UsageCore`: models, JSON-RPC transport, normalization, state, and refresh policies.
- `CodexUsage`: SwiftUI interface, AppKit menu bar and popover, Settings, and launch-at-login support.
- `scripts/build-app.sh`: local app packaging.

## References

This is an original implementation based on the documented [OpenAI App Server protocol](https://learn.chatgpt.com/docs/app-server). [ZeroP27/codex-usage](https://github.com/ZeroP27/codex-usage) and [acaexplorers/Codex-Usage-and-Resets](https://github.com/acaexplorers/Codex-Usage-and-Resets), both MIT-licensed, were consulted as references; their code was not copied. CodexUsage is an independent utility.
