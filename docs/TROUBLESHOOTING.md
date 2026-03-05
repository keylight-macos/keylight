# KeyLight Troubleshooting

This guide covers first-run setup and recovery for Input Monitoring issues.
The expected bundle identifier for this project is `com.keylight.app`. Some of this is repeated from the README.md of this repo.

## Unsigned Build

This warning happens because the app is currently unsigned (no paid Apple Developer Program membership yet, US$99/year).

If you see:

- `"KeyLight" Not Opened`
- `Apple could not verify "KeyLight" is free of malware...`

then do this once:

1. Try opening `KeyLight.app` once from `Applications`.
2. In the first warning popup, click `Done`.
3. Open `System Settings` -> `Privacy & Security`.
4. Scroll down to the `Security` section.
5. Click `Open Anyway` for `KeyLight`.
6. In the second popup (`Open "KeyLight"?`), click `Open Anyway` again.
7. Enter your macOS password (or Touch ID) to confirm.

Alternative: Control-click `KeyLight.app` -> `Open` -> `Open`.

## If No Prompt Appears

It may happen that macOS suppresses the native prompt if a prior prompt already exists.

Run:

```bash
killall KeyLight 2>/dev/null || true
tccutil reset ListenEvent com.keylight.app
```

Relaunch KeyLight and enable the effect again.

If still no native prompt appears, open Input Monitoring manually and enable KeyLight:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
```

If this still does not work, then please just restart your machine and hope it works. 

## Prompt Was Denied

1. Quit KeyLight.
2. Open Input Monitoring settings.
3. Remove the KeyLight entry.
4. Reset TCC state:

```bash
tccutil reset ListenEvent com.keylight.app
```

## Manual Recovery Commands

Reset the permission decision:

```bash
tccutil reset ListenEvent com.keylight.app
```

Force close the app, reset, and the open settings pane:

```bash
killall KeyLight 2>/dev/null || true
tccutil reset ListenEvent com.keylight.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
```
