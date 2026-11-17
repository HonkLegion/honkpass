# HonkPass

HonkPass is a native macOS client for [Vaultwarden](https://github.com/dani-garcia/vaultwarden), written in Swift.
It stores passwords, passkeys and other vault items, with native macOS controls and Liquid Glass surfaces.
The interface supports English and Czech.

HonkPass is an independent, unofficial client. It is not affiliated with Bitwarden Inc.

## Features

- Vault editing, search and synchronization, with folders, favorites, archive and trash.
- Multiple accounts, organizations and collections.
- Password and username generation, authenticator codes, and SSH keys.
- Quick Access from the menu bar or a keyboard shortcut.
- Login form filling in browsers and Mac applications through Accessibility.
- System AutoFill for passwords, passkeys and authenticator codes.
- Application assignments from installed or running applications, with an assignment choice when filling a login.
- Master password, PIN and Touch ID unlock.
- SSH approval, Send, import and export.
- Signed application updates through Sparkle.

With background mode enabled, closing the main window hides the Dock icon and keeps HonkPass in the menu bar.
Quick Access opens in the center of the screen and closes when it loses focus.

## Requirements

HonkPass requires macOS 26.4 or later on Apple Silicon.
It connects to a Vaultwarden server.

To build the application, install these tools:

- Xcode 27 and its command line tools.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), Fish and `jq`.
- Rust through `rustup`.
- Python 3.11 or later for license inventory and source packaging.
- Docker for the local test server.

An Apple Developer team and signing credentials are required for the signed build.

## Build

Run these commands in a Fish terminal from the repository directory.
First, copy the local signing template:

```fish
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` to your team identifier.
Your team must own the application identifier.
If needed, set `APP_BUNDLE_ID` to an identifier that your team owns.
Keep this local file out of Git.

Prepare the SDK and build the application:

```fish
make prepare-sdk
make build
make run
```

`make prepare-sdk` downloads the pinned SDK, applies the patch in `support/patches/` and builds the macOS bindings.
Normal builds use the committed interface resources.
Workflow logs are stored under `.build/logs/`.

## AutoFill and Quick Access

Enable system AutoFill in HonkPass.
Select HonkPass as a provider in macOS System Settings.
For shortcut filling in other applications, grant HonkPass Accessibility permission.

Shortcut filling uses the active application or website to find matching logins.
It fills an authenticator code when the login contains one and the form exposes a clearly identified code field.
If that code field has focus, the shortcut fills only the code.
Ambiguous fields require an explicit field choice in Quick Access.
HonkPass does not submit the form.

A login can include a signed Mac application alongside its website addresses.
Use the application chooser in the login editor, or save the application assignment when you approve filling.
HonkPass identifies an application by its bundle identifier and developer signature.
Browser logins use website addresses instead.

## SSH agent

Enable the SSH agent in HonkPass.
Then set the socket path once in Fish:

```fish
set -Ux SSH_AUTH_SOCK ~/.passvault-ssh-agent.sock
```

With the vault unlocked, list its SSH public keys:

```fish
ssh-add -L
```

The agent signs with Ed25519 keys.
The approval window identifies the requesting application and the requested key.

## Updates

Release builds use Sparkle to find and install signed updates.
Automatic discovery runs daily. The application menu also provides manual discovery.
Installation requires your action in Sparkle.

Before installation, close editors.
Finish active operations before you continue.
HonkPass locks the vault during the update and retains the stored accounts and preferences.

## Development and tests

Use synthetic data and the local Vaultwarden server for development.
The server runs at `http://localhost:8642` and uses the synthetic accounts in `support/vaultwarden/`.
Docker must run before you start the server.

```fish
make server
make test
```

`make test` runs engine tests and adapter tests against the local server.
Before GUI tests, quit the installed HonkPass. Test builds share its application identifier.
The smoke tests open windows and take keyboard focus.

```fish
make smoke
```

Both commands must end with `OK`.
Runs with `OFFLINE=1` cover only part of the tests and end with `PARTIAL`.
`make check` also runs the workflow and updater tests.

After a Debug build, test shortcut filling with synthetic AppKit and WebKit forms:

```fish
fish scripts/test-fill.fish
```

This test needs Accessibility permission for the test build.
Automated tests do not establish complete coverage of Touch ID, Safari, passkeys or external login forms.

See [visual review](docs/reference/README.md) for synthetic screen captures.
Run `make help` for all build targets.

## Distribution

Developer ID distribution requires the matching certificate, provisioning profiles and an Apple notarization profile in Keychain.
Commit the source changes before archiving.
The archive command requires a clean working tree and current license resources.

```fish
make archive
make notarize NOTARY_PROFILE=your-notary-profile
```

`make archive` exports the signed application and its corresponding source archive under `.build/distribution/`.
`make notarize` sends that export to Apple and packages the accepted application as a ZIP.
These commands do not install the application.

Distribute the notarized ZIP, matching `HonkPass-source.tar.gz` and `release-manifest.json` together.
The manifest records their hashes. The signed application records its source revision and archive hash.
Rebuilding requires the tools above and network access for dependencies.

The [public source list](support/public-source-files.txt) selects files for both source publication and the corresponding source archive.
Add new build inputs to this list before packaging a release.
Public release commits also include `public-source.json`, which records the original revision and the exported file hashes.

## License

HonkPass uses [GPL-3.0-only](LICENSE) and comes without warranty to the extent permitted by law.
Third-party components retain their licenses, copyright notices and attribution.
The Bitwarden SDK uses its GPL option. HonkPass does not use its commercial license.

Bundled resources include adapted Bitwarden client resources, Inter under OFL-1.1, the Public Suffix List under MPL-2.0, and original HonkPass artwork.
The application menu and About dialog open the bundled license notices without a network request.
The [license inventory](App/PassVault/Legal/inventory.json) records component versions, resource hashes and upstream modifications.

With the SDK prepared, regenerate and inspect the notices after resource or dependency changes:

```fish
make reference-source
make licenses
make check-licenses
```

The corresponding source archive includes the application, upstream source, modifications and dependency notices required by the packaging workflow.
