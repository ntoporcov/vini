fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac build

```sh
[bundle exec] fastlane mac build
```

Run a build sanity check (Debug, no signing concerns)

### mac archive

```sh
[bundle exec] fastlane mac archive
```

Build a Developer ID signed release archive (.app) for direct distribution

### mac notarize_app

```sh
[bundle exec] fastlane mac notarize_app
```

Notarize the Developer ID signed app and staple the ticket

### mac release

```sh
[bundle exec] fastlane mac release
```

Full release: archive + notarize + zip a distributable artifact

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
