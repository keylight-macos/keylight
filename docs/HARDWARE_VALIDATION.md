# Motion Preview Hardware Validation

Automated tests prove state transitions, renderer bounds, migration behavior,
privacy policy, universal architecture, and package integrity. They cannot prove
keyboard rollover behavior, display topology, macOS permission continuity, visual
quality, or real input-to-render latency. Those remain real-hardware gates.

## Build the candidate

Use the end-to-end preview harness. It protects `/Applications/KeyLight.app` by
fingerprinting its file contents before and after the isolated preview build.

```bash
# Local/ad-hoc candidate
KEYLIGHT_CLONED_SOURCE_PACKAGES_DIR=/path/to/SourcePackages \
  ./scripts/validate-motion-preview.sh --local 2.2.0

# Developer ID-signed, notarized candidate
KEYLIGHT_CLONED_SOURCE_PACKAGES_DIR=/path/to/SourcePackages \
  ./scripts/validate-motion-preview.sh --signed 2.2.0
```

The signed route requires an installed Developer ID Application identity and the
`KeyLightNotary` notarytool Keychain profile. It deliberately keeps the isolated
`KeyLight Motion Preview.app` name and `com.keylight.app.motionpreview` bundle ID,
and embeds no production Sparkle feed or update key.

The harness publishes a DMG, a SHA-256 sidecar, and a property-list validation
record in `dist/validation/`. Every real-hardware gate starts as `pending`; an
automated run never marks a human observation as passed.

## Record real-hardware results

List the gate IDs, then record one result at a time:

```bash
./scripts/hardware-validation.sh list dist/validation/REPORT.plist

./scripts/hardware-validation.sh record \
  dist/validation/REPORT.plist \
  ansi_chords pass \
  '2, 3, and 4 adjacent and distant keys; staggered release passed'

./scripts/hardware-validation.sh record \
  dist/validation/REPORT.plist \
  multi_display_mirroring pass \
  'Two physical displays; resize, disconnect, reconnect, sleep, and wake passed'
```

Allowed statuses are `pending`, `pass`, `fail`, `blocked`, and
`not-applicable`. A failure, blocker, or not-applicable result requires a note.
Performance passes also require the measured value in the note. Do not put names,
serial numbers, hardware UUIDs, display UUIDs, typed content, or key codes in
notes.

One machine cannot cover both macOS 14 and macOS 26, and one keyboard may not
cover both ANSI and ISO. Complete separate reports against the exact same DMG.
An individual report may use `not-applicable`, but that does not count as suite
coverage.

## Verify the candidate set

```bash
./scripts/hardware-validation.sh verify \
  dist/validation/REPORT.plist \
  dist/KeyLight-2.2.0-motion-preview-signed.dmg

./scripts/hardware-validation.sh verify-suite \
  dist/KeyLight-2.2.0-motion-preview-signed.dmg \
  dist/validation/macOS14-REPORT.plist \
  dist/validation/macOS26-REPORT.plist
```

`verify` rejects a report that has pending, failing, or blocked gates or whose
DMG hash differs. `verify-suite` additionally requires at least one actual pass
for every gate across all supplied reports.

## Measurement boundary

For latency and CPU, use the signed universal Release candidate and the process
described in [PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md). The report stores
only the Mac model identifier, architecture, macOS version/build, candidate
identity, trust status, source commit, and gate results. It does not query or
store device serial numbers or stable hardware/display identifiers.
