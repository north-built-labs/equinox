# Equinox — System-wide Audio Equalizer for macOS (Design Spec)

Date: 2026-10-15
Status: Draft for review

## 1. Intent

**What the user said:** Reverse engineer eqMac (black-box), and build a better, cooler-looking
version that includes all of eqMac's Pro features. Personal use only. Use every feature
(“everything”) and the recommended engine approach (process taps + AVAudioEngine).

**Assumptions (correct me):**
- Single user, single Mac (Apple Silicon, macOS 27). No distribution, notarization, licensing, updater, or telemetry.
- “Better” means: native UI (no WebView), no kernel/HAL driver install, lower friction, nicer visuals, plus features eqMac lacks (AutoEQ, crossfeed, spatial).
- Clean-room: eqMac informs *what* features exist; no eqMac code, assets, strings, or license logic are reused.

**Success criteria:**
1. Launch → grant “System Audio Recording” once → all system audio flows through Equinox with no audible glitches during normal playback, and stops cleanly (audio returns to normal) on quit or crash.
2. Every feature in §3 works from the UI and persists across relaunches.
3. Output latency added ≤ ~20 ms; CPU < 5% of one core with EQ + spectrum active.
4. It looks distinctly better than eqMac (see §6).

## 2. Black-box findings (REA, eqMac v1.9.2, static only)

Evidence: `ev_3cce3053…` (Info.plist), `ev_fe0d2c11…` (Swift classes), `ev_5fce7c3a…` (strings).

- Capture: `CATapDescription`, `TapCaptureUnit`, `SystemSourceTapBackend`, private aggregate `eqMac-Capture-Aggregate`; legacy `eqMac.driver` still bundled.
- Processing: AVAudioEngine with `AVAudioUnitEQ`, `AVAudioUnitReverb`, hosted AUs.
- UI: WKWebView + JS bridge → Swift “DataBus” handlers, ReSwift state store.
- Feature inventory: Basic / Advanced / Expert (parametric, grouped, shelf/lowpass) EQ; System mixer (per-app volumes, per-client taps); volume gain/boost, balance, mute; Basic reverb + Matrix reverb; AU plugin hosting with crash auto-disable; multiband compressor, peak limiter, bandpass; spectrum analyzer; preset auto-switch on output-device change; per-output-device config; headphone detection.
- Not found: AutoEQ, crossfeed, spatial/HRTF (these are Equinox originals).

## 3. Feature set (phased; every phase ships a working app)

**Phase 1 — Engine & core**
- System-wide capture via global process tap; processed audio to the current default output device.
- Parametric EQ: up to 32 bands; types Peak, Low/High Shelf, Low/High Pass, Notch, Band Pass; freq / gain / Q per band; preamp; per-band enable.
- Quick modes: 10-band graphic (fixed freqs) and full parametric — both are views over the same band model.
- Live spectrum analyzer (post-processing) + L/R peak meters.
- Presets: built-in set + user presets; create/rename/duplicate/delete; import/export JSON.
- Volume boost (0 – +12 dB above unity) with automatic safety limiter; balance; mute; software volume for devices with no hardware volume (e.g. HDMI).
- Per-output-device memory: each device remembers its preset & enabled state; auto-switches when the default output changes.
- Global bypass toggle; launch at login.

**Phase 2 — Per-app mixer**
- List of apps currently producing audio (icon, name, live meter).
- Per-app volume (0–150%), mute, solo; persisted by bundle ID.
- Per-app EQ preset (optional; default = none).

**Phase 3 — Effects & plugins**
- Built-in effects (reorderable chain, each with bypass): Reverb (factory presets + wet/dry), Compressor, Multiband Compressor, Peak Limiter, Delay.
- Host third-party AUv2/AUv3 effect plugins: browse installed, insert into chain, open plugin UI in its own window, save plugin state inside presets.
- Crash protection: a plugin that crashes during load is auto-disabled next launch with a notice.

**Phase 4 — Headphone extras**
- AutoEQ: search the AutoEq database (downloaded index from the AutoEq GitHub repo, cached) or import a `ParametricEQ.txt`; becomes a “correction” layer independent of the user's taste EQ.
- Crossfeed (Bauer-style, 3 strengths).
- Spatial: virtual stereo speakers rendered binaurally (HRTF) with width/room controls.
- Headphone detection: optional auto-enable of the headphone layer when output is headphones.

## 4. Architecture

```
 ┌──────────────── EquinoxApp (SwiftUI) ────────────────┐
 │ MenuBarExtra popover · Main window · Onboarding       │
 │            AppModel (@Observable, MainActor)          │
 └──────┬──────────────────────────────▲─────────────────┘
        │ immutable DSPConfig snapshots │ meters/spectrum (lock-free ring)
 ┌──────▼──────────────────────────────┴─────────────────┐
 │ EquinoxAudio                                          │
 │  AudioSystem   – devices, processes, change listeners │
 │  TapSession    – process taps + private aggregate dev │
 │  RenderGraph   – IOProc render pipeline (RT thread)   │
 │  EffectsHost   – AVAudioEngine (manual realtime mode) │
 └──────┬────────────────────────────────────────────────┘
        │
 ┌──────▼──────────────── EquinoxDSP (pure, testable) ───┐
 │ Biquad design (RBJ) · BiquadBank (vDSP_biquadm)       │
 │ Gain/Balance · Limiter · Crossfeed · FFT Spectrum     │
 │ Preset model & codecs · AutoEQ parser                 │
 └───────────────────────────────────────────────────────┘
```

Built as a Swift Package with three library targets (`EquinoxDSP`, `EquinoxAudio`, `EquinoxUI`) + an executable target, assembled into `Equinox.app` by `scripts/build-app.sh` (Info.plist with `NSAudioCaptureUsageDescription`, `LSUIElement`, codesign). Deployment target **macOS 15** (needed for the `Synchronization` module's `Atomic`); host is macOS 27.

### 4.1 Capture (TapSession)
- One private aggregate device per session: main sub-device = current output device (clock source), tap list = taps below, drift compensation on, `TapAutoStart` on.
- Taps (`CATapDescription`, `isPrivate = true`, `muteBehavior = .mutedWhenTapped`):
  - **Rest tap**: global stereo tap *excluding* Equinox itself and every app that has a custom mixer setting.
  - **App taps**: one stereo-mixdown tap per app with a custom mixer setting (Phase 2).
- Because taps mute only while Equinox lives, a crash or quit restores normal audio automatically — no stuck-silent state (eqMac driver failure mode).
- Rebuild triggers: default output device change, output format/sample-rate change, mixer app set change (debounced 300 ms), device removal, IOProc watchdog (no callbacks for 2 s while running). Rebuild = create new session, start it, then destroy old (minimizes gap).

### 4.2 Render pipeline (RenderGraph, inside the aggregate's IOProc)
Per buffer, strictly real-time safe (no allocation, locks, ObjC messaging, or logging):
1. Pick up the newest `DSPConfig` if one is pending (atomic pointer swap); apply biquad target coefficients with vDSP ramping (no zipper noise).
2. For each tap input stream: per-app gain/mute/EQ → sum into the mix bus.
3. Master: preamp → AutoEQ correction bank → user EQ bank → EffectsHost render (skipped entirely when the chain is empty) → crossfeed/spatial → balance → boost gain → safety limiter (ceiling −0.3 dBFS).
4. Write stereo to the first two output channels (zero others).
5. Copy post-chain samples into a lock-free SPSC ring buffer for meters/spectrum.

### 4.3 EffectsHost
AVAudioEngine in `.realtime` manual rendering mode; its input node pulls from the pipeline's current buffer; chain = user-ordered `AVAudioUnit`s (built-in Apple units: `AVAudioUnitReverb`, `AUDynamicsProcessor`, `AUMultibandCompressor`, `AUPeakLimiter`, `AVAudioUnitDelay`; third-party via `AVAudioUnitComponentManager`). Spatial uses `AVAudioEnvironmentNode` (HRTF-HQ) with two mono sources at ±30°. Chain edits happen off the RT thread by building a fresh engine and swapping it in at a buffer boundary.

### 4.4 State & persistence
- `AppModel` (@Observable) owns all user state; every mutation produces a new immutable `DSPConfig` sent to the audio side.
- Stored as JSON in `~/Library/Application Support/Equinox/` (`settings.json`, `presets/*.json`, `devices.json`, `apps.json`, `autoeq-cache/`). Writes debounced 500 ms, atomic.
- Spectrum UI pulls from the ring buffer at display refresh (TimelineView), FFT 4096 with Hann window, log-frequency bins, attack/release smoothing.

## 5. Error handling
- **Permission not granted / denied:** onboarding screen explains why, button opens Privacy & Security → Screen & System Audio Recording; app stays in bypass.
- **Tap/aggregate creation fails:** status pill turns red with the OSStatus explained; audio untouched (tap never muted anything); retry button + automatic retry on next device change.
- **Output device disappears:** follow the new default output; restore that device's saved preset.
- **Clipping:** the limiter is always last and cannot be disabled while boost > 0 dB.
- **Plugin crash on load:** “loading plugin X” marker written before instantiation and cleared after; if present on launch, that plugin is disabled with a banner.
- **Corrupt JSON:** file is moved to `*.corrupt-<date>` and defaults are used; user is notified once.

## 6. Visual design
- Dark-first, translucent “glass” surfaces (`.glassEffect` on macOS 26+, material fallback), one accent gradient (electric cyan → violet), SF Pro Rounded numerals, smooth spring animations.
- **Menu bar popover (360 pt wide):** power toggle with status glow · output device picker · mini live spectrum with the EQ curve overlaid · preset picker · volume/boost slider with boost zone tinted amber · compact per-app mixer (top 5 active apps) · “Open Equinox” button.
- **Main window:** sidebar (Equalizer, Mixer, Effects, Headphones, Presets, Settings).
  - *Equalizer:* full-width canvas — gradient-filled spectrum behind a glowing EQ curve; each band is a draggable node (drag = freq/gain, scroll or pinch = Q, right-click = type/enable/delete, double-click empty space = add band). Band strip beneath with exact numeric fields. Graphic/Parametric toggle.
  - *Mixer:* channel-strip cards per app with icon, vertical fader, live meter, mute/solo, EQ preset menu.
  - *Effects:* horizontal draggable chain of effect cards with bypass and expand-to-edit.
  - *Headphones:* AutoEQ search + selected model's target curve plot; crossfeed/spatial controls.
- Status-bar icon reflects state (active / bypassed / error) and optionally a tiny live level.

## 7. Testing
- **EquinoxDSP unit tests (XCTest):** RBJ coefficient magnitude response vs analytic values at center/corner freqs for each filter type; BiquadBank processing a sine matches predicted gain ±0.1 dB; Q↔bandwidth conversion; limiter never exceeds ceiling on a +12 dB burst; crossfeed preserves mono (L=R) signals at unity; balance/gain math; AutoEQ `ParametricEQ.txt` parser on real samples; preset JSON round-trip.
- **Offline pipeline harness:** runs RenderGraph (minus taps) on generated signals to verify ordering, bypass, and config swaps without glitches (no discontinuities > threshold).
- **Manual checklist per phase:** permission flow, play music → EQ audibly applied, device switch (built-in ↔ AirPods), quit restores audio, kill -9 restores audio, sleep/wake, per-app volumes, plugin load/crash marker.

## 8. Out of scope
App Store/notarization, licensing, auto-update, analytics, cloud preset sync, input-device (microphone) processing, Intel Macs, macOS < 15.
