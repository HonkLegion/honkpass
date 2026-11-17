# Interface review

Use the synthetic scenes described in [Visual review](README.md).
Review current HonkPass behavior and the requested change.
Differences from another application do not define defects.

## Preparation

1. Notify the user before GUI tests.
2. Wait for the user to quit any installed HonkPass instance.
3. Start the test build with `make sandbox` and the required scene.
4. Store evidence under `.build/` with synthetic data only.

Run commands from the repository directory in Fish.
For server tests, start Docker and run `make server` first.
Use only the synthetic accounts from `support/vaultwarden/`.

## Review

- Inspect changed screens in light and dark appearances.
- Inspect narrow and wide windows, fullscreen, and expanded and collapsed navigation.
- Open and close details, editors, dialogs and Quick Access where relevant.
- Use the keyboard to move focus, search, select items and dismiss panels.
- Scroll to the last field and history entry. Make sure that headers and controls stay readable and clickable.
- Inspect transitions at rest and during motion. Make sure that Reduce Motion disables optional motion.
- Make sure that the window can be dragged and that unused title-bar space supports the native double-click behavior.

Do not use real vaults, private websites or personal authentication sessions.
If a system permission or physical authentication blocks a test, report the limitation.

## Automated coverage

With the local server running and the installed application closed, run:

```fish
make test
make smoke
```

Both commands must end with `OK`.
Record the commands, log paths, results and remaining manual checks in the pull request.
Quit the test application after the review.
