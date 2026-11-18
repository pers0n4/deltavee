# Agent Guidelines

Build with `swift build --scratch-path ~/Library/Caches/deltavee/build` and test with `swift test --scratch-path ~/Library/Caches/deltavee/build`.

## Documentation

- Keep `README.md`, `README.ko.md`, and published `docs/` documents user-facing: installation, usage, observable behavior, privacy, costs, account risks, and legal notices.
- Keep developer references, measurements, design rationale, and release-operator procedures out of published documentation. Public documentation and code comments must not link to unpublished files.

## Swift Code Rules

- Architecture: Do not adopt architecture frameworks such as TCA. Keep Core types as `Sendable` value types, and inject external dependencies such as credentials, HTTP, CLI execution, and clocks through protocols. State shared by multiple tasks, such as polling, is managed by an actor.
- State observation: Declare app state with `@Observable`. To observe state changes from AppKit code, use the `Observations` async sequence.
- Tests: Keep the existing XCTest tests. For new tests of pure Core logic, consider Swift Testing. A test that fails even once is not "passing on rerun"; measure the reproduction rate and remove real-desktop dependencies (`NSStatusItem`, `NSScreen`, global event monitors) before reporting it as passing. Boundary tests also assert that the input exceeds the boundary, and must fail when the implementation under test is reverted.
- Code style: Format with `mise run format` (`swift format` default configuration) and check with `mise run lint`. Rules the formatter does not cover, namely declaring classes `final` by default and using the narrowest access control, are checked in review.
- `@unchecked Sendable`: Use only when the compiler cannot verify safety. When used, leave a comment naming the synchronization mechanism (such as a lock) and why it is safe.
- Evidence comments: Code that depends on an external contract (an unofficial endpoint, request headers, response fields, another tool's file or Keychain layout) or on a measured value gets a self-contained comment naming the source, tool/artifact version, and last verification date, for example `Verified 2026-11-15 against Claude Code 2.1.322`. Include a public source URL when available and measurement conditions where relevant. Label chosen policy values as choices rather than measurements. Do not cite planning or review IDs (such as `G005`) that no document in the repository defines.
- Contract mismatches: When checking an external contract reveals that the implementation differs from it, report it as a defect together with a fix or a question about fixing it. Do not record the gap as a documented assumption instead.
- Background work: For automatic or background behavior, specify the success, transient-failure, and permanent-failure paths with a retry interval and cap, and test them with an injected clock. Cache only successful results; retry failures and malformed results on the next call. Log each run's start and finish without tokens or CLI output, with file mode 600 and size rotation.
- Child processes: Launch external CLIs with the `ProcessEnvironment.child` allowlist and a fixed, app-owned working directory such as `Paths.claudeRefreshWorkdir`. After adding a launch path, check what it changes under the user's `~/.claude` or `~/.codex`.
- `AnyView`: Do not use outside the AppKit–SwiftUI hosting boundary (`NSHostingView<AnyView>`).
- Logging: Use `print` only in CLI paths whose purpose is standard output (`--login-item`, `deltavee-probe`). For app runtime logs, use `os.Logger`.

## User Input Device Restrictions

By default, tests and verification must not use the user's real mouse cursor or keyboard focus. The user keeps working on the same Mac while verification runs.

- Default method: Send events inside an XCTest `NSHostingView` or host window. Use `NSEvent.keyEvent` + `performKeyEquivalent` for key input, `NSEvent.mouseEvent` + `window.sendEvent` for clicks and drags, and `performActionForItem` for menu selection.
- Check text such as tooltips and labels through AppKit control properties (`toolTip`, `accessibilityLabel()`). Attach tooltips to settings pickers with the `help:` argument of `SettingsPicker` instead of SwiftUI `.help`.
- Check layout, line wrapping, and truncation with `fittingSize`, height comparisons across widths, and `cacheDisplay` pixel inspection.
- Check the state of the running app first with methods that send no input, such as `deltavee-probe` or reading accessibility attributes.
- When checking the installed app with fake states, point it at an isolated home with `CFFIXED_USER_HOME` so the real account documents and snapshots stay untouched, and report that they were preserved.

### Exceptions

Using real input devices is allowed only for checks that automated tests cannot replace. This covers cases that need a real hover, such as the actual rendering of a tooltip window, and menu bar or panel interactions that do not reproduce in the test host.

- Before use, tell the user what you are checking and why, and roughly how long the cursor or keyboard will be in use.
- Keep the interaction to the minimum needed for the check and finish quickly. This covers `CGEventPost`, `cliclick`, and System Events `click`/`keystroke`.
- If you quit the installed app or launched a test build, restore the original state afterward and report that you did.
- Record any item not checked through this exception as unverified in the verification report.
