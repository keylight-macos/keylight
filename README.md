# KeyLight for macOS

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-6.2%2B-orange)](https://www.swift.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Lightweight glow effects for your keyboard with more immersive typing, tuned for macOS. It is meant as a natural extension of your typing projected onto the bottom of your screen with cool glow effects.

<img src="https://github.com/keylight-macos/keylight/blob/main/docs/assets/keylight_demo.png?raw=1" alt="KeyLight Hero" width="100%">

## Inspiration

Hi, KeyLight was inspired by a [YouTube video](https://www.youtube.com/watch?v=esY3iS4l3Xs) by the creator HTX Studio. I wanted to have a piano-visualizer-like effect when typing. The effect best works in dark mode and with the dock set on auto-hide or when the dock is on the side of the screen.

## Why KeyLight

- Ambient typing effect for your Mac.
- Lightweight runtime designed to stay out of your way.
- No noticeable battery drain in normal use on Apple Silicon (tested on M4).
- Highly customizable effects: colors, gradients, per-key behavior, dimensions, roundness, and fade timing.
- Built-in key position editor to calibrate glow placement to your keyboard and monitor combination.

## System Requirements

- macOS **14.0+** (Sonoma and higher)
- Input Monitoring permission (required for global key listening)

## Installing KeyLight

1. Download the .dmg from the releases page.
2. Open `KeyLight-<version>.dmg`.
3. Drag `KeyLight.app` to `Applications`.
4. Launch from `Applications`.

## First-Run Setup

KeyLight currently shows the macOS verification warning because this build is unsigned (I'm currently not enrolled in the Apple Developer Program, which is US$99/year).

1. Launch `KeyLight.app` from `Applications`.
2. If macOS shows `"KeyLight" Not Opened` / `Apple could not verify "KeyLight"...`:
   - Click `Done` in that first warning popup.
   - Open `System Settings` -> `Privacy & Security`.
   - Scroll down to the `Security` section.
   - Click `Open Anyway` for `KeyLight`.
   - In the second popup (`Open "KeyLight"?`), click `Open Anyway` again.
   - Enter your macOS password (or Touch ID) to confirm.
3. Grant **Input Monitoring** when macOS requests it.
4. Click **Quit & Reopen** the app when the prompt appears.
5. Start typing.

If the prompt does not appear try typing this into the terminal to reset permissions in macOS:
```bash
killall KeyLight 2>/dev/null || true
tccutil reset ListenEvent com.keylight.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
```

More troubleshooting info:

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Features

- Menubar-only app
- Global hotkey: `Cmd + Shift + K` to toggle KeyLight
- Color modes: Solid, Position Gradient, Random Per Key, Rainbow
- Theme save/load with rename and delete actions
- Layout profile system (save, load, export, import)
- Key position editor with drag calibration and glow preview for maximum customizability
- Launch at login

## Community Keyboard Layouts/Presets

Current checks for submissions:
- .JSON-only parsing
- No executable/plugin/script loading
- Import size cap (max. 5MB)
- Strict validation, normalization, and clamping
- Allowed-key filtering and max entry limits
- Numeric and string sanitation on import paths

## MacBook Air 13" (2024) & Pro 14" (2024) layouts

This repo includes a ready-to-share layout for a MacBook Air 13" (2024) bundle which is selected by default. It also supports the Macbook Pro 14" (2024) as a preset. 

- check `docs/variants/` for more layouts (hopefuly to come soon)

Import flow:
- Use `keylight-layout-profile-template.json` via **Key Layout -> Import** for layout (offsets + width) transfer.
- Use `Copy Theme String` / `Import Theme String` in **Themes** for shareable custom glow themes.

My baseline is the **German ISO** layout of the Macbook Air 13" (2024), with guidance for US keyboard (**ANSI**) layouts. However, most keys should just map 1:1 for different keyboard layouts of the same variant. 

## Next Steps & Known Issues

Here are some features I would still like to implement to this app in the future if I come around to it:
- Liquid glass-like effect similar to the button presses

Known issues are:
- Media key handling is missing/wrong for the media keys corresponding to F4 (maps to F5 media key), F5 (fallback to middle), F6, F7, F9 (no keylight). This is due to difficult handling with the HID, but to be honest I have no idea why it does not work. If you have a fix please let me know.
- Caps lock release (from ON to OFF) does not give a KeyLight effect. This is due to the handling of the effect in macOS. Right now, I force it to light up only briefly. Otherwise it would stay on as long caps lock is ON.

## Privacy and License

- Privacy policy: [PRIVACY.md](PRIVACY.md)
- License: [MIT](LICENSE)
