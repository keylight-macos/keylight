# KeyLight Compatibility Contract

This file freezes the behavior that the incremental rewrite must preserve. A change to one of these contracts requires an explicit migration and a compatibility test; architectural cleanup alone is not a reason to change it.

## Product boundary

- KeyLight is a local-only, menu-bar macOS utility with no Dock icon or persistent dashboard.
- The passive overlay remains nonactivating, click-through, absent from the accessibility tree, and anchored to the bottom edge of the keyboard display.
- Input Monitoring uses a listen-only event tap. Decoding may retain canonical key codes, direction, repeat state, source, and timestamp only. Character data, typed content, positions, colors, layouts, and imported payloads are never logged or transmitted.
- Classic Glow remains available on macOS 14 and later. System Glass, Physical Refraction, and Solid Black are available on macOS 26 and resolve to Classic Glow below it; all macOS 26 API references stay compiler- and availability-guarded.
- Classic+ and the custom prismatic Liquid Glass preview are retired migration values. Existing preferences and themes map to Classic Glow and System Glass respectively, but neither retired route is selectable or rendered.
- There are no accounts, analytics, crash-upload SDKs, plug-ins, typing history, or per-app rules. The only network feature is the signed updater, which stays inactive until a manual check or explicit automatic-check opt-in.

## Persistent compatibility

The authoritative key list is asserted by `SettingsManager._testUserDefaultsKeyContract`. Existing keys retain their names, defaults, clamps, and meanings. The optional `activeThemeID`, `activeLayoutID`, `hasSeenPermissionExplanation`, `overlayDisplaySelection`, `mirroredDisplayIDs`, `displayLayoutProfileBindings`, `globalShortcut`, `chordSurfaceStyle`, `chordIntensityMultiplier`, `powerSavingMode`, `configurationSnapshotsV1`, and `configurationSnapshotRecoveryV1` keys are additive. Active theme/layout names continue to be written for older builds. Display selection uses a stable CoreGraphics display UUID and always falls back to the original built-in-first policy if the requested display is unavailable. Mirror IDs remain persisted while unavailable and are deduplicated from the resolved primary display. The global shortcut defaults to Command-Shift-K; custom shortcuts persist key-code and modifier metadata only.

- Theme share strings retain the `keylight-theme-v1` and `keylight-theme-v2` grammar and field ordering.
- Layout profiles retain the current JSON schema, canonical key allow-list, and media-key aliases.
- Existing saved theme and layout UUIDs are stable identities. Legacy records without IDs are upgraded deterministically by name.
- Imports are transactional: invalid input changes neither live state nor persisted state.
- Import limits are 1 MB, 512 unique key entries, and 100 characters per saved name.
- Configuration snapshot documents use `kind: keylightConfigurationSnapshot`, version 1, the `.keylight-snapshot.json` suffix, a 1 MB import limit, and a 500 KB persistent-data limit. Applying a snapshot may write only the typed exportable-key registry; unknown JSON keys are ignored and excluded settings are never replaced.
- `SMAppService.mainApp.status` is the source of truth for launch-at-login; the legacy preference is only a compatibility mirror after a successful change.

## Input and overlay behavior

- Every physically held key renders concurrently without a logical key limit. Natural Merge preserves the established cohesive surface behavior; Independent keeps one stable surface identity per key with no bridge geometry. Releasing one key does not move or hide any remaining key.
- Priority is physical key, then the temporary chord test, then calibration preview, then Settings preview. The chord test is never persisted and records no physical input.
- Tap failure, permission loss, sleep, disablement, or monitor restart clears physical interaction state. Still-active previews may resume after a physical reset.
- Start, stop, reset, show, refresh, hide, and clear operations are safe to repeat.
- Classic Glow pixels and timings remain unchanged unless a visual contract is deliberately revised.
- Surface effects use the shared persistent motion engine with bounded surfaces during interruption and style changes. Physical Refraction uses a separate event-driven Metal renderer with on-demand capture.
- Automatic Power Saving preserves the selected Physical Refraction preference, stops capture under Low Power Mode or serious/critical thermal pressure, re-renders held keys through the supported fallback, and restores once the condition clears.
- Selected mirror displays share the active layout and central interaction state. Input, previews, configuration, power changes, resets, and clears are broadcast to every live overlay panel; unavailable mirror IDs remain saved for reconnect.
- Reduce Motion suppresses geometry animation. Reduce Transparency and Increase Contrast adjust material visibility without changing the selected supported route.

## Release gates

- Swift 6 strict-concurrency Debug build for the generic macOS destination.
- Full isolated unit/integration suite, including migration and import fixtures.
- Universal arm64/x86_64 Release build, weak-link and privacy scans, signing/notarization checks when credentials are available, mounted-DMG verification, and launch smoke test.
- Shell syntax validation for checked-in release scripts.
- Manual checks on ANSI and ISO keyboards, media/Fn/Caps Lock, clamshell and built-in displays, Spaces/full-screen, Light/Dark and textured backgrounds, VoiceOver, Reduce Motion, Reduce Transparency, Increase Contrast, macOS 14 Classic Glow, and all three macOS 26 surface routes.
- Real-hardware results must describe the exact candidate DMG hash. A release-ready report set has at least one pass for every gate; `not-applicable` never counts as coverage.

## Performance gates

Measurements are taken from a signed Release build on reference Apple Silicon after a 30-second settling period:

- input-event receipt to render submission p99 below 16.7 ms;
- idle median CPU below 0.5%;
- no event-tap timeout during a 60-second synthetic stress run;
- bounded views and layers after 100,000 synthetic transitions.

Automated tests enforce deterministic state and allocation bounds. CPU and end-to-end event latency remain hardware release checks because virtualized CI measurements are not comparable.

The measurement procedure and current verification boundary are documented in [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md).
