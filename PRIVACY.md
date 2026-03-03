# KeyLight Privacy Policy

Last updated: February 27, 2026
This privacy policy is informational and not legal advice.

## Summary

KeyLight is a local macOS app. It does not collect personal data and does not send data to external servers or require an internet connection.

## What KeyLight accesses

- Input Monitoring events (required to detect global key press/release state).
- Local app settings stored in `UserDefaults`.
- Local files only when you explicitly transfer data:
  - layout profiles via JSON import/export
  - theme strings via copy/import

## What KeyLight does not do

- No telemetry
- No analytics SDKs
- No cloud sync (use the import function to transfer layouts and themes)
- No account/login system
- No background network upload of your data
- No keystroke content logging by design

## Data storage

KeyLight stores settings locally on your Mac, including:

- Effect settings (color, size, fade, mode)
- Saved themes/profiles
- Key position/width adjustments

You can export and delete this data at any time from within the app.

## Community presets / imported files

Imported presets are treated as untrusted data and parsed as JSON or text only.
No scripts, plugins, or executable code are loaded from imported files. But users should treat all such as insecure and not blindly trust others (general caution and common sense).

## Security note

Keep macOS and KeyLight updated. There is not yet an auto update function, you will need to uninstall and install a new version from the GitHub repo. Only import presets/settings from sources you trust.

## General

KeyLight is distributed under the MIT License. The MIT License already includes warranty/liability disclaimer language ("AS IS", without warranty).
