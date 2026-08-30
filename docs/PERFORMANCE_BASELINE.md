# KeyLight Performance Baseline

Performance is a release contract. KeyLight now keeps keyboard decoding on a dedicated user-interactive CFRunLoop thread, forwards only normalized value events to the MainActor, and drives the Physical Refraction MTKView only when motion, backdrop, configuration, resize, or clearing actually requires a frame.

The normal input hot path resolves established raw key codes directly. It does not construct an AppKit event or inspect character metadata unless an otherwise-unresolved special/function-key event needs that platform hint.

## Automated baseline

`PerformanceContractTests` runs 100,000 synthetic press/release pairs through the pure held-key and preview model. It verifies that physical state returns to empty, preview priority remains correct, and the event value exposes no character or text field. Renderer smoke tests separately assert the fixed view/surface budget and cleanup after style changes. The authoritative total test count comes from the current `.xcresult` bundle so this document cannot drift when coverage grows.

These tests are deterministic correctness and bounded-state gates. They are not presented as end-to-end latency or CPU measurements.

## Hardware release baseline

Measure a signed universal Release build on the reference Apple Silicon Mac after 30 seconds of idle settling. Record the Mac model, macOS build, KeyLight version/build, effect style, display topology, and accessibility display options with each result.

Required gates:

- input receipt to render submission p99 below 16.7 ms;
- idle median CPU below 0.5% over five minutes;
- no event-tap timeout during a 60-second typing stress run;
- stable view/layer counts after 100,000 synthetic transitions.

Use Instruments Points of Interest with the DEBUG-only anonymous sequence signposts for the latency sample, and Activity Monitor/Instruments for idle CPU. The signposts cover input receipt, normalization, MainActor dispatch, overlay update, renderer submission, capture start/stop, and presented/dropped frames. They never include key codes, characters, positions, colors, theme values, captured pixels, or imported data.

## Current verification status

The deterministic 100,000-transition test, bounded renderer assertions, event-driven draw contract, dedicated input-loop behavior, and privacy-safe signpost contract are checked in. Hardware CPU/GPU measurements, p95/p99 latency, 60/120 Hz frame pacing, signed-build stress, and macOS 14/macOS 26 visual results remain explicit release gates and must be recorded from real hardware; CI or an unsigned debug build is not an acceptable substitute.

Create and verify candidate-bound hardware records with
[`scripts/hardware-validation.sh`](../scripts/hardware-validation.sh) using the
workflow in [HARDWARE_VALIDATION.md](HARDWARE_VALIDATION.md). The verifier rejects
pending/failing gates, measured performance passes without notes, a mismatched DMG
hash, and validation suites with no actual pass for any required gate.
