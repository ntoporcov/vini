# Vini

Local services, one menu bar away.

Vini is a lightweight macOS command center for the databases, dev servers, agents, and background jobs running on your machine. It keeps your local stack visible, controllable, and organized without making you jump between terminals, Activity Monitor, `brew services`, and random shell scripts.

## What it does

Vini sits in your menu bar and gives you live visibility into the services powering your workday. Start, stop, restart, group, pin, and inspect services from one small native app.

Highlights:

- See your local services at a glance, including status, ports, process IDs, and logs.
- Start, stop, and restart controllable services without memorizing commands.
- Create groups for related stacks, run them together, and pin important groups directly to the menu bar.
- Import scripts from `package.json` and turn project commands into reusable services.
- Keep custom long-running commands alive across app launches when you need them to survive.
- Hide noisy discoveries and surface only the services that matter.

Service sources:

- **Homebrew** services (`brew services list --json`) - start/stop/restart
- **launchd** user agents (`launchctl list`) - start/stop
- **Listening ports** (`lsof`) - read-only detection of well-known dev ports
- **User-defined** services - configure custom start/stop commands in-app

## Distribution

Vini ships as a **non-sandboxed, Developer ID–signed, notarized** app (NOT Mac App Store).
This is required because the app spawns `brew` / `launchctl` / `lsof` to inspect and control
services. The App Store sandbox forbids executing arbitrary binaries, so direct distribution is required.

## Architecture

- **macOS only**, menu-bar-first, with a dedicated main window when you need more room
- **SwiftUI** throughout, with `NSApplicationDelegateAdaptor` for AppKit lifecycle
- `ObservableObject` store (`ServicesStore`) injected via `@EnvironmentObject`
- `actor` isolation for all process I/O (`Shell`, `ServiceDiscovery`, `ServiceController`)

### Source Layout

```
Vini/
  App/            @main entry point + AppDelegate
  Models/         Domain types (ViniService, ServiceKind, UserServiceDefinition, ServiceStatus)
  Stores/         ServicesStore — @MainActor ObservableObject
  Services/       MenuBarManager, Shell, ServiceDiscovery, ServiceController
  Views/
    MenuBar/      Popover root and header/footer
    Services/     ServiceListView, ServiceRowView
    Settings/     SettingsView
```

## Project Setup

This project uses **XcodeGen** — the `.xcodeproj` is generated and gitignored.

Install Ruby dependencies before using fastlane:

```bash
bundle install
```

```bash
# First time / after adding or removing files:
xcodegen generate

# With personal signing (required for local install):
cp project.local.example.yml project.local.yml
# Edit project.local.yml and set DEVELOPMENT_TEAM to your team id
INCLUDE_PROJECT_LOCAL_YAML=1 xcodegen generate
```

## Local Install

```bash
./scripts/install_mac_local.sh           # build + install to /Applications (sudo)
./scripts/install_mac_local.sh --user    # build + install to ~/Applications (no sudo)
./scripts/install_mac_local.sh --launch  # also open the app after installing
./scripts/install_mac_local.sh --clean   # wipe derived data first
```

## Screenshot Mode

Use screenshot mode when you need deterministic product shots without touching your real services, preferences, or logs.

```bash
open -n /Applications/Vini.app --args --screenshot-mode
```

Screenshot mode seeds demo services, groups, pinned menu-bar items, and logs in memory. It bypasses real `brew`, `launchctl`, `lsof`, and custom process execution; start/stop/restart actions only simulate status changes.

You can also launch the executable directly with `VINI_SCREENSHOT_MODE=1`.

## Fastlane

```bash
bundle exec fastlane mac build         # Debug build sanity check
bundle exec fastlane mac archive       # Developer ID signed Release .app
bundle exec fastlane mac notarize_app  # notarize + staple the archived .app
bundle exec fastlane mac release       # archive + notarize + GitHub release
```

Copy `fastlane/.env.default` to `fastlane/.env` and fill in:

- `FASTLANE_TEAM_ID` - your Apple Developer team id for Developer ID signing
- `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and key content/path - used by notarytool for notarization
- `GH_TOKEN` - a GitHub token for the personal account that owns `ntoporcov/vini`

`release` uses `MARKETING_VERSION` from `project.yml` by default and creates `build/fastlane/Vini-<version>.zip` plus a GitHub release tag `v<version>`.

To release a specific version without editing `project.yml` first:

```bash
bundle exec fastlane mac release version:1.0.1
```

### Homebrew

Homebrew distribution starts with a personal tap. Create a separate GitHub repo named `ntoporcov/homebrew-vini`; users can then install with:

```bash
brew tap ntoporcov/vini
brew install --cask vini
```

To update that tap from the release lane, set `UPDATE_HOMEBREW_CASK=1`. If your personal GitHub SSH identity uses a host alias, set `HOMEBREW_TAP_REMOTE`, for example:

```bash
HOMEBREW_TAP_REMOTE=git@github.com-personal:ntoporcov/homebrew-vini.git \
UPDATE_HOMEBREW_CASK=1 \
bundle exec fastlane mac release
```

The lane writes `Casks/vini.rb` with the GitHub release zip URL and SHA-256, commits it in the tap repo, and pushes it. Publishing to the official `Homebrew/homebrew-cask` repo is a separate manual PR path after the app has a stable public release.

## Signing

- `project.local.yml` (gitignored) holds your personal `DEVELOPMENT_TEAM`.
- `Vini/Vini.entitlements` is the **non-sandboxed** entitlement set: sandbox off,
  hardened runtime on, with library-validation disabled so the app can spawn helper tools.
- Distribution uses a **Developer ID Application** certificate, then notarization.

## License

MIT. See [LICENSE](LICENSE).
