# Listening: consistent levels and reactive EQ

## Scope

Add an opt-in Listening stage to the master mix, saved with presets and unsaved
working settings. UI: a Listening sidebar page, preset controls, one master switch,
consistent-volume controls, three reactive EQ amounts and live gain/cut meters.
The menu bar exposes the same switch. Existing presets load with Listening off.

This first version levels stereo RMS, not calibrated acoustic loudness or LUFS.
It operates on the whole mix; per-app targets and automatic content recognition
are outside this change. No added buffering or lookahead.

## Processing

Keep correction → EQ → effects → spatial/crossfeed → Listening → existing
output controls → safety limiter. The level detector runs before output volume,
so it cannot counteract the user's volume, balance or mute controls. Preamp remains
folded into output gain, as in the current engine.

- Stereo-linked RMS levelling, maximum +6 dB gain / −18 dB attenuation, a −50 dBFS
  activity gate and startup qualification before upward gain. Target −30…−14 dBFS.
  Preserve-dynamics control reduces correction and slows gain adaptation.
- Three stereo-linked dynamic cuts at 120 Hz, 3.2 kHz and 7 kHz. Use the existing
  RBJ constant-peak bandpass design and subtract a smoothed fraction of the band
  from the dry signal. Fixed poles avoid coefficient-modulation instability.
  Each band has a level threshold and a maximum cut of 9 dB × amount.
  Reference: https://www.w3.org/TR/audio-eq-cookbook/ (constant 0 dB peak BPF).
- Fixed-size scalar state; coefficient design and validation off the audio thread.
  Control updates every 64 samples, independent of callback sizes. Smooth enable,
  disable and parameter changes. Reset on invalid input and rate changes.
- Publish activity through atomic scalars on the existing analysis tap; UI only
  polls while visible. The final limiter remains last.

## Verification

Measure output on generated signals: steady level convergence, loud/quiet contrast,
dynamics preservation, gain bounds, silence/noise gating, selective band cuts,
stereo linking, bypass transitions, callback-size independence, sample rates,
non-finite recovery, output mute/volume and limiter ceiling. Test preset migration,
import/export, save/revert/relaunch and model-to-audio propagation.

Run the hardware-independent suite, optimized Listening DSP tests and DSP Address
Sanitizer checks. Build the app and render the real Listening UI using snapshots.
Audible quality, latency/CPU on hardware, device changes and real plugin combinations
still require listening on a real output device; do not infer these from unit tests.

## Implemented and verified

- 201 hardware-independent tests pass in debug and release. After final silent-tail
  and invalid-input hardening, all 201 debug tests and the 22 relevant optimized
  Listening/model/renderer tests pass.
- All 62 DSP tests pass under Address Sanitizer.
- The host-architecture release app builds with an ad-hoc signature. The Listening
  screen was rendered offscreen and visually inspected; meters in snapshots use
  illustrative frozen values, while renderer tests verify actual meter publication.
- Reviewed the new render path for allocation/locking and malformed preset values.
  Settings are clamped at decode/model/config boundaries; no new dependencies,
  permissions or network access are introduced.
- Interactive controls, audible tuning, hardware switching and cross-OS/universal
  builds have not been validated in this change.

In the restricted environment, SwiftPM's nested sandbox and Apple Audio Unit
loading blocked initial runs. Tests and packaged snapshots were rerun with normal
macOS service access. No Audio Unit tests were omitted to work around that failure.
