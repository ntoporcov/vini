---
name: run-vini-locally
description: Use when the user asks to run locally, relaunch Vini, restart the app, kill the running app and launch it again, or install the local macOS build.
---

# Run Vini Locally

Use this skill for local app launch/relaunch requests in the Vini repo.

## Preferred Command

Run the repository script instead of manually opening a derived-data app bundle:

```bash
./scripts/install_mac_local.sh --launch
```

This script:

- Generates the Xcode project with `project.local.yml` via XcodeGen.
- Builds the Debug macOS app using local development signing.
- Gracefully quits any running `Vini.app/Contents/MacOS/Vini` process.
- Force-kills the same process if graceful quit does not finish quickly.
- Installs the built app to `/Applications/Vini.app` by default.
- Launches the installed app when `--launch` is passed.

## Variants

Use `--user` if the user wants to install to `~/Applications` instead of `/Applications`:

```bash
./scripts/install_mac_local.sh --user --launch
```

Use `--clean` when build artifacts are suspected to be stale:

```bash
./scripts/install_mac_local.sh --clean --launch
```

## Notes

- The script may require `sudo` for `/Applications` replacement.
- If the script fails because `project.local.yml` is missing, tell the user to create it from `project.local.example.yml` and set `DEVELOPMENT_TEAM`.
- If the script fails because signing identities are missing, tell the user to create an Apple Development signing identity in Xcode Settings > Accounts.
