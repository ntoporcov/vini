# Vini — Agent Notes

## What this project is

A macOS-only, menu-bar-only app (`LSUIElement = true`) that shows running local services and lets users start/stop/restart them. Inspired by the JetBrains Services panel.

## Distribution model (IMPORTANT)

Vini is **non-sandboxed**, **Developer ID–signed**, and **notarized** — it is NOT a Mac App Store app.

This is a hard requirement: the app spawns `brew`, `launchctl`, and `lsof` via `Process` to
discover and control services. The App Store sandbox forbids executing arbitrary binaries, so
sandboxing is disabled in `Vini/Vini.entitlements`. Hardened Runtime stays ON (required for
notarization), with library validation disabled so child processes launch cleanly.

Do NOT re-enable `com.apple.security.app-sandbox` — it will break discovery and control.

## Architecture

- SwiftUI throughout — no UIKit
- AppDelegate via `@NSApplicationDelegateAdaptor` for NSStatusItem lifecycle
- `ObservableObject` store (`ServicesStore`) passed via `@EnvironmentObject`
- `actor` isolation for all process I/O: `Shell`, `ServiceDiscovery`, `ServiceController`
- All UI state is `@MainActor`
- Configuration is intentionally persisted with Codable values in `UserDefaults`, not SwiftData. Keep it small and explicit.
- `ServicesStore` accepts an injectable `UserDefaults`; app code uses `.standard`, tests must use isolated suites.

## Service model

`ViniService` carries a `kind` (`ServiceKind`) that determines how it is controlled:

- `.homebrew(formula:)` — `brew services start|stop|restart <formula>`
- `.launchAgent(label:)` — `launchctl start|stop <label>`
- `.portProbe(port:)` — read-only (detected via `lsof`), `isControllable == false`
- `.userDefined(definition:)` — runs the user's custom start/stop shell commands

`UserServiceDefinition` is `Codable` and persisted in `UserDefaults` by `ServicesStore`.

## Persistence Rules

- Do not let tests touch the real app defaults domain (`com.ntoporcov.vini`).
- Never use `UserDefaults.standard` directly in `ViniTests` for `vini.*` keys. Use `TestDefaults.make()` and inject it into `ServicesStore`.
- Flush preference writes explicitly through the store (`synchronize()`) because this is a menu-bar app and users may quit/kill it soon after edits.
- Keep user configuration keys stable. Current important keys include:
  - `vini.userDefinitions`
  - `vini.hiddenServiceIDs`
  - `vini.surfacedServiceIDs`
  - `vini.groups`
  - `vini.expandedNodeIDs`
  - `vini.serviceOrderIDs`
  - `vini.keptAliveProcesses`
- If preferences appear to vanish during development, suspect test isolation first. Previous test runs wiped live data before `ServicesStore` became defaults-injectable.

## Tree / Groups UX

- Services are rendered as a recursive tree via `ServiceTree` and `ServiceTreeNode`.
- Simultaneous groups behave like folders: expandable and runnable as a group.
- Sequenced groups behave like leaf/service rows: runnable as a sequence, not expandable.
- Loose services appear under the non-runnable `Ungrouped` bucket, not directly at the root.
- Group nesting uses member ids in the form `group:<uuid>`. Keep cycle checks when adding/moving nested groups.
- `Remove from Group` removes a member only from the specific parent group currently rendering that row.
- `Duplicate to Group` preserves existing membership and adds the same service reference to another group.
- Drag/drop move semantics are intentionally different from duplicate semantics:
  - Dragging moves an item, removing prior memberships.
  - `Duplicate to Group` duplicates membership without moving.
- Dragging onto a row reorders/inserts before that row.
- Dragging onto a folder body moves into that folder.
- Dragging onto the left/indent side of a folder row reorders before that folder.
- Manual top-level group order follows the stored `groups` array; do not sort top-level groups alphabetically.
- Manual ungrouped service order is persisted in `vini.serviceOrderIDs`; unknown/unordered services may fall back to name sorting.
- Drag feedback should show animated insertion space for reorder targets and a soft folder highlight for move-into-folder targets.

## Add/Edit Flows

- Service/group add and edit flows run in standalone `WindowGroup` windows, not popover sheets. File/folder pickers focus poorly from transient popovers.
- When opening editor, log, or settings windows from the popover, activate the app (`NSApp.activate(ignoringOtherApps: true)`) so the window comes forward.
- The Settings button should explicitly bring the Settings window to the front; `SettingsLink` alone may leave it hidden behind other apps.

## NPM Helper

- NPM helper imports multiple selected scripts from a `package.json`.
- Imported services should be named by script only (`dev`, `start`, etc.), not prefixed with package name.
- The helper should automatically create a simultaneous group named after the package and place imported script services in that group.
- Detect the package manager from lockfiles and use the correct run command (`npm`, `pnpm`, `yarn`, `bun`).

## Process / Logs

- User-defined services are owned by `ProcessManager` while Vini launches them.
- Keep-alive-on-quit is best effort: persisted PID plus command is verified before re-adoption.
- Re-adopted processes can show historic logs only; live stdout/stderr pipes cannot be recovered.
- Logs live under `~/Library/Application Support/Vini/logs/` and use sanitized service ids.

### Process-handling invariants (regressions here are expensive)

These four rules each fixed a real, user-visible bug. Do not undo them.

1. **A `readabilityHandler` MUST uninstall itself when `availableData` is empty.**
   An fd at EOF is *permanently* readable, so a handler that just returns spins the
   dispatch source at ~1M calls/sec — one saturated CPU core per exited service.
   This is why pipe draining lives in `PipeLogReader`, which owns the teardown.
   Covered by `testPipeLogReaderUninstallsItselfAtEOF`.
2. **Never gate cleanup on `Process.isRunning`.** The `zsh -lc` wrapper exits while
   the real server keeps running in the same process group (backgrounded/disowned
   commands). Treating that as "stopped" leaves orphaned `node`/`vite` processes
   holding ports, and the next start then fails with `EADDRINUSE`. Use
   `ProcessManager.treeMembers` / `signalTree`, which signal the recorded **pgid**
   plus descendants that escaped it. Covered by
   `testStopKillsSurvivorsAfterWrapperShellExits`.
3. **Never `Thread.sleep` inside an actor.** `ProcessManager.stop` is `async` and
   uses `Task.sleep` for its grace period. Blocking the actor serialised every other
   caller (including discovery's `runningServiceIDs()`), which made start/stop
   buttons appear dead for seconds at a time.
4. **Drain stdout and stderr concurrently in `Shell.run`.** Reading stdout to EOF
   first deadlocks whenever the child fills the ~64KB stderr buffer. All invocations
   also carry a timeout (`Shell.defaultTimeout` / `Shell.discoveryTimeout`).

### Cost discipline

- Discovery must stay at a small, constant number of subprocesses. Listening ports
  come from **one** batched `lsof -Fpn` call (`ServiceDiscovery.listeningPIDsByPort`),
  not one `lsof` per port.
- There is **no polling timer** anywhere; refresh is entirely event-driven. Do not add
  one — an idle app should sit at 0% CPU.
- `start`/`stop`/`restart` each end with `refresh()`. Bulk/group operations must wrap
  their work in `coalescingRefresh` so N services cost one discovery, not N + 1.
- `ProcessTable.snapshot()` reads the process table via `sysctl`, deliberately not by
  shelling out to `ps`/`pgrep`.

### MCP server

- Every session teardown must call `server.stop()`, not just `transport.disconnect()`.
  The MCP SDK's receive loop is a long-lived `Task` that only `Server.stop()` cancels;
  omitting it leaks a task per `initialize`.
- Sessions are evicted by idle timeout and a hard count cap; `sessions` must never grow
  unboundedly.
- The listener binds loopback only via `params.requiredLocalEndpoint`. Because that
  carries the port, construct it as `NWListener(using: params)` — passing `on:` as well
  fails with `EINVAL`.
- Requests are read until `Content-Length` is satisfied; a single `receive` only returns
  the first TCP segment and truncates larger bodies.
- SSE chunks must be **awaited**, and the connection closed via a final
  `send(isComplete: true)` whose completion cancels it. `routeResponse` finishes the
  stream immediately after yielding the reply, so a fire-and-forget `send` followed by
  `connection.cancel()` discards the response and the client sees a dropped connection.

## Key Files

- `Vini/App/ViniApp.swift` — `@main` entry point (Settings scene only)
- `Vini/App/AppDelegate.swift` — creates `MenuBarManager` and kicks off initial refresh
- `Vini/Services/MenuBarManager.swift` — owns `NSStatusItem` and `NSPopover`
- `Vini/Services/Shell.swift` — process runner + tool path discovery (`brewPath`, `launchctlPath`, `lsofPath`)
- `Vini/Models/ViniModels.swift` — `ViniService`, `ServiceKind`, `UserServiceDefinition`, `ServiceStatus`
- `Vini/Stores/ServicesStore.swift` — observable store; refresh, actions, user-definition persistence
- `Vini/Services/ServiceDiscovery.swift` — real discovery (brew JSON + launchctl + lsof ports)
- `Vini/Services/ServiceController.swift` — real start/stop/restart per `ServiceKind`
- `Vini/Views/MenuBar/MenuBarRootView.swift` — popover root
- `Vini/Views/Services/ServiceListView.swift` — scrollable service list
- `Vini/Views/Services/ServiceRowView.swift` — service row; hides actions for non-controllable services
- `Vini/Views/Settings/SettingsView.swift` — settings window content

## Project Generation

**Do not edit `Vini.xcodeproj` directly.** It is generated by XcodeGen from `project.yml`.
After adding or removing Swift files, run:

```bash
xcodegen generate
# or with local signing:
INCLUDE_PROJECT_LOCAL_YAML=1 xcodegen generate
```

## Tooling assumptions

- Homebrew is expected at `/opt/homebrew/bin/brew` (Apple Silicon), with `/usr/local/bin/brew` fallback.
- `Shell.run` prepends common tool paths to `PATH` so tools resolve even when launched from Finder.
- Discovery is best-effort: any source that fails (missing tool, parse error) returns an empty list
  rather than throwing, so the menu always renders.

## Distribution / fastlane

- `fastlane mac build` — Debug sanity build
- `fastlane mac archive` — Developer ID signed Release `.app`
- `fastlane mac notarize_app` — notarize + staple
- `fastlane mac release` — archive + notarize + zip
- Notarization uses the App Store Connect API key (env vars in `fastlane/.env`).

## Coding Conventions

- Swift 6.0 strict concurrency — no `nonisolated(unsafe)` unless justified
- All process I/O in `actor` types, never on `@MainActor`
- Views receive state via `@EnvironmentObject` — never hold stores as `@State`
- Stores are `@MainActor final class ... : ObservableObject` with `@Published` state, since `@EnvironmentObject` requires `ObservableObject`
- Preview all views with `#if DEBUG` guards around `#Preview` blocks
