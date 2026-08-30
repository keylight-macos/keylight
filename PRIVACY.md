# KeyLight Privacy Policy

Last updated: August 30, 2026

This privacy policy is informational and not legal advice.

## Summary

KeyLight is a local macOS app. It does not collect personal data, use analytics, show advertising, require an account, or upload your typing or settings.

## What KeyLight accesses

- Input Monitoring is required to detect global key press and release state. KeyLight keeps only the key identity, direction, repeat state, source, and timing needed to draw the effect. It does not keep typed characters or a typing history.
- Physical Refraction can optionally use Screen Recording after you press its permission button. The other effects do not need it.
- Settings, themes, keyboard layouts, and configuration snapshots are stored locally on your Mac.
- Files are read or written only when you explicitly import or export a theme, layout, or configuration snapshot.

## Physical Refraction

Physical Refraction captures only a shallow strip along the bottom of each selected display while the effect is visible. KeyLight keeps at most the newest frame for each display and passes it directly to the GPU.

The captured image is not saved, copied to the clipboard, read with OCR, logged, or sent anywhere. Capture stops when the effect finishes, when KeyLight is disabled, when the effect changes, when the Mac sleeps, or when KeyLight quits.

## What KeyLight does not do

- No telemetry or analytics
- No cloud sync or account system
- No keystroke content logging
- No saved screenshots or captured-image history
- No background upload of settings, themes, layouts, or snapshots
- No scripts, plugins, or executable code loaded from imported files

## Updates and network access

The unsigned KeyLight v2.0.0 release has no configured update feed or update key. Its update controls remain unavailable and it does not make update-check requests. Download future versions manually from the official GitHub Releases page.

The source includes support for a signed Sparkle update feed if a future Developer ID release configures one. Automatic checks remain off until explicitly enabled, and KeyLight does not send a system profile or custom identifiers.

## Local data

KeyLight stores its preferences in the normal macOS application preferences. This includes effect settings, themes, keyboard layouts, calibration, display routing, shortcuts, and saved configuration snapshots.

You can remove this data by deleting KeyLight's preferences. Input Monitoring and Screen Recording permissions are controlled separately by macOS in System Settings.

## General

KeyLight is distributed under the MIT License and comes without warranty as described in that license.
