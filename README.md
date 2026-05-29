# Mbappe

macOS menu-bar app to manage running local services, inspired by the JetBrains Services panel.

## What it does

Mbappe sits in your menu bar and gives you live visibility into every local service running on your Mac — databases, HTTP servers, daemons — with one-click start/stop/restart controls.

## Architecture

- **macOS only**, menu-bar-only (`LSUIElement = true`)
- **SwiftUI** throughout, with `NSApplicationDelegateAdaptor` for AppKit lifecycle
- `@Observable` stores for state — no singletons in views
- `actor` isolation for all I/O (discovery, process control)

### Source Layout

```
Mbappe/
  App/            @main entry point + AppDelegate
  Models/         Domain types (MbappeService, ServiceStatus)
  Stores/         ServicesStore — observable, @MainActor
  Services/       MenuBarManager, ServiceDiscovery, ServiceController
  Views/
    MenuBar/      Popover root and header/footer
    Services/     ServiceListView, ServiceRowView
    Settings/     SettingsView
```

## Project Setup

This project uses **XcodeGen** — the `.xcodeproj` is generated and gitignored.

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

## Fastlane

```bash
fastlane mac build            # simulator/Debug build sanity check
fastlane mac archive          # release archive for App Store
fastlane mac beta             # archive + upload to TestFlight
fastlane mac release          # archive + upload to App Store Connect
fastlane mac metadata_check   # precheck metadata
fastlane mac metadata         # upload metadata only
```

Copy `fastlane/.env.default` to `fastlane/.env` and fill in your App Store Connect credentials.

## Signing

`project.local.yml` (gitignored) holds your personal `DEVELOPMENT_TEAM`.
`Mbappe/Mbappe.entitlements` is the App Store entitlement set (sandbox on, network client).
