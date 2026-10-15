import AppKit
import EquinoxCore
import EquinoxDSP
import Observation
import SwiftUI

/// Polls per-strip peaks at 30 Hz while attached.
@MainActor
@Observable
final class MixerMeters {
    private(set) var levels: [String: Float] = [:]
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clients = 0
    @ObservationIgnored private var frozen = false

    init(model: AppModel) { self.model = model }

    func level(_ key: String) -> Float { levels[key] ?? 0 }

    func attach() {
        clients += 1
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        clients = max(clients - 1, 0)
        if clients == 0 { timer?.invalidate(); timer = nil }
    }

    /// Diagnostics: fixed levels, no polling.
    func freeze(_ levels: [String: Float]) { frozen = true; self.levels = levels }

    private func tick() {
        guard !frozen else { return }
        var next: [String: Float] = [:]
        for (i, key) in model.activeStripKeys.enumerated() {
            next[key] = max(model.stripMeters.take(strip: i), (levels[key] ?? 0) * 0.85)
        }
        levels = next
    }
}

struct AppIcon: View {
    var bundleID: String?
    var size: CGFloat

    var body: some View {
        if let image = icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: bundleID == nil ? "terminal.fill" : "app.fill")
                .font(.system(size: size * 0.6)).frame(width: size, height: size)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var icon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct MixerPage: View {
    @Bindable var model: AppModel
    var meters: MixerMeters

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Mixer").font(.system(.title2, design: .rounded).weight(.bold))
                Spacer()
                Text("Changing an app gives it its own channel. Reset returns it to Other Apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.mixerStrips) { strip in ChannelStripView(model: model, meters: meters, strip: strip) }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .onAppear { meters.attach() }
        .onDisappear { meters.detach() }
    }
}

struct ChannelStripView: View {
    @Bindable var model: AppModel
    var meters: MixerMeters
    var strip: MixerStrip

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if strip.isOthers {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 22)).frame(width: 38, height: 38)
                        .foregroundStyle(Theme.accent)
                } else {
                    AppIcon(bundleID: strip.bundleID, size: 38)
                }
                if strip.isPlaying {
                    Circle().fill(.green).frame(width: 9, height: 9).overlay(Circle().stroke(Theme.background, lineWidth: 2))
                }
            }
            Text(strip.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).frame(width: 96)

            HStack(alignment: .bottom, spacing: 8) {
                VerticalSlider(value: Binding(get: { strip.volume * 100 },
                                              set: { model.setStripVolume(($0 / 100), for: strip.id) }),
                               range: 0...150, tint: strip.isMuted ? .gray : Theme.cyan, zero: 100)
                    .frame(width: 34, height: 170)
                meter.frame(width: 6, height: 170)
            }
            Text("\(Int((strip.volume * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(strip.volume > 1 ? Theme.amber : .white.opacity(0.8))

            HStack(spacing: 6) {
                toggle("M", on: strip.isMuted, color: .red) { model.setStripMuted(!strip.isMuted, for: strip.id) }
                if !strip.isOthers {
                    toggle("S", on: strip.isSoloed, color: Theme.amber) { model.toggleSolo(strip.id) }
                }
            }

            Menu {
                Button("No EQ") { model.setStripPreset(nil, for: strip.id) }
                Divider()
                ForEach(model.presets) { p in Button(p.name) { model.setStripPreset(p.id, for: strip.id) } }
            } label: {
                Text(presetName).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .menuStyle(.button).controlSize(.small).frame(width: 96)

            Button("Reset") { model.resetStrip(strip.id) }
                .buttonStyle(.borderless).font(.caption2)
                .opacity(strip.volume != 1 || strip.isMuted || strip.presetID != nil || strip.isSoloed ? 1 : 0.3)
        }
        .frame(width: 112)
        .glassCard(cornerRadius: 18, padding: 12)
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(strip.isSoloed ? Theme.amber : .clear, lineWidth: 1.5))
    }

    private var presetName: String {
        strip.presetID.flatMap { id in model.presets.first { $0.id == id }?.name } ?? "No EQ"
    }

    @ViewBuilder private var meter: some View {
        GeometryReader { geo in
            let db = Decibels.fromLinear(Double(meters.level(strip.id)))
            let t = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(LinearGradient(colors: [Theme.cyan, Theme.violet, db > -1 ? .red : Theme.violet],
                                              startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * t)
            }
        }
        .opacity(strip.isDedicated ? 1 : 0.25)
        .help(strip.isDedicated ? "Live level" : "Adjust this app to get a live meter")
    }

    private func toggle(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 26, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : .white.opacity(0.08)))
                .foregroundStyle(on ? .black : .white.opacity(0.8))
        }.buttonStyle(.plain)
    }
}

/// Popover mixer: apps currently playing (max 5) plus Other Apps.
struct CompactMixer: View {
    @Bindable var model: AppModel
    var meters: MixerMeters

    var body: some View {
        let strips = Array(model.mixerStrips.filter { $0.isOthers || $0.isPlaying || $0.isDedicated }.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(strips) { strip in
                HStack(spacing: 8) {
                    if strip.isOthers {
                        Image(systemName: "square.stack.3d.up.fill").frame(width: 18).foregroundStyle(Theme.accent)
                    } else {
                        AppIcon(bundleID: strip.bundleID, size: 18)
                    }
                    Text(strip.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 84, alignment: .leading)
                    Slider(value: Binding(get: { strip.volume }, set: { model.setStripVolume($0, for: strip.id) }),
                           in: 0...StripSettings.maxVolume)
                        .tint(strip.volume > 1 ? Theme.amber : Theme.cyan).controlSize(.small)
                    Button { model.setStripMuted(!strip.isMuted, for: strip.id) } label: {
                        Image(systemName: strip.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                            .foregroundStyle(strip.isMuted ? .red : .white.opacity(0.7)).frame(width: 16)
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { meters.attach() }
        .onDisappear { meters.detach() }
    }
}
