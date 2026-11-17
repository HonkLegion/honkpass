# Visual review

Review HonkPass with synthetic data in light and dark appearances.
Keep captures and galleries local under `.build/`.
Do not commit third-party screenshots or images that contain real account data.

## Capture a screen

Run the commands from the repository directory in Fish.
Quit the installed HonkPass before you start a test build.
The test build and installed application share an application identifier.

Build and open a synthetic scene:

```fish
make build
make sandbox NAME=vault-all-items APPEARANCE=light
```

The terminal needs Screen Recording permission to capture windows.
Capture the current HonkPass window:

```fish
make screenshot NAME=vault-all-items
```

The image is stored under `.build/screenshots/`.
Quit the test application before opening another scene.
Use `APPEARANCE=dark` for a dark appearance.
Scene names are defined in [Scenes.swift](../../App/PassVault/Scenes.swift).

`make sandbox` keeps its synthetic account in memory.
It leaves personal storage, Keychain, system AutoFill registration and global shortcuts unchanged.

See the [review checklist](test-plan.md) and [contributor rules](../../AGENTS.md) before testing.
