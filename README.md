# Mbappe

macOS menu-bar app to manage running local services, inspired by the JetBrains Services panel.

## What it does

Mbappe sits in your menu bar and gives you live visibility into every local service running on your Mac — databases, HTTP servers, daemons — with one-click start/stop/restart controls.

Service sources:

- **Homebrew** services (`brew services list --json`) — start/stop/restart
- **launchd** user agents (`launchctl list`) — start/stop
- **Listening ports** (`lsof`) — read-only detection of well-known dev ports
- **User-defined** services — configure custom start/stop commands in-app (run on demand)

## Distribution

Mbappe ships as a **non-sandboxed, Developer ID–signed, notarized** app (NOT Mac App Store).
This is required because the app spawns `brew` / `launchctl` / `lsof` to inspect and control
services — the App Store sandbox forbids executing arbitrary binaries.

## Architecture

- **macOS only**, menu-bar-only (`LSUIElement = true`)
- **SwiftUI** throughout, with `NSApplicationDelegateAdaptor` for AppKit lifecycle
- `ObservableObject` store (`ServicesStore`) injected via `@EnvironmentObject`
- `actor` isolation for all process I/O (`Shell`, `ServiceDiscovery`, `ServiceController`)

### Source Layout

```
Mbappe/
  App/            @main entry point + AppDelegate
  Models/         Domain types (MbappeService, ServiceKind, UserServiceDefinition, ServiceStatus)
  Stores/         ServicesStore — @MainActor ObservableObject
  Services/       MenuBarManager, Shell, ServiceDiscovery, ServiceController
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
fastlane mac build         # Debug build sanity check
fastlane mac archive       # Developer ID signed Release .app
fastlane mac notarize_app  # notarize + staple the archived .app
fastlane mac release       # archive + notarize + zip distributable artifact
```

Copy `fastlane/.env.default` to `fastlane/.env` and fill in your App Store Connect API key
(used by notarytool for notarization) and `FASTLANE_TEAM_ID`.

## Signing

- `project.local.yml` (gitignored) holds your personal `DEVELOPMENT_TEAM`.
- `Mbappe/Mbappe.entitlements` is the **non-sandboxed** entitlement set: sandbox off,
  hardened runtime on, with library-validation disabled so the app can spawn helper tools.
- Distribution uses a **Developer ID Application** certificate, then notarization.
