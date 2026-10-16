import AppKit
import EquinoxAudio
import EquinoxCore
import EquinoxDSP
import SwiftUI
import UniformTypeIdentifiers

struct HeadphonesPage: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var importError: String?

    var body: some View {
        let hp = model.headphones
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: model.isHeadphoneOutput ? "headphones" : "hifispeaker.fill")
                    .font(.system(size: 26)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headphones").font(.system(.title2, design: .rounded).weight(.bold))
                    Text(model.currentDevice.map { "\($0.name) · \(model.isHeadphoneOutput ? "headphones" : "speakers")" } ?? "No output")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Headphone features", isOn: Binding(get: { hp.isEnabled }, set: { v in model.updateHeadphones { $0.isEnabled = v } }))
                    .toggleStyle(.switch).tint(Theme.cyan)
            }
            HStack(spacing: 14) {
                Toggle("Treat this output as headphones", isOn: Binding(
                    get: { model.isHeadphoneOutput }, set: { model.setHeadphoneOverride($0) }))
                Toggle("Turn on automatically for new headphones", isOn: $model.autoEnableHeadphones)
            }
            .font(.caption).toggleStyle(.checkbox)

            correctionCard(hp).opacity(hp.isEnabled ? 1 : 0.55)
            HStack(alignment: .top, spacing: 16) {
                crossfeedCard(hp)
                spatialCard(hp)
            }
            .opacity(hp.isEnabled ? 1 : 0.55)
        }
        .padding(24)
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    @ViewBuilder private func correctionCard(_ hp: HeadphoneSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Correction").font(.headline)
                Text("AutoEq").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.violet.opacity(0.3)))
                Spacer()
                Button("Import ParametricEQ.txt…", action: importFile).controlSize(.small)
            }
            if let c = hp.correction {
                HStack(spacing: 12) {
                    CorrectionCurve(profile: c, sampleRate: model.sampleRate).frame(height: 70)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(.system(size: 13, weight: .semibold))
                        Text("\(c.source) · \(c.bands.count) filters · preamp \(String(format: "%+.1f", c.preampDB)) dB")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { model.removeCorrection() }.controlSize(.small)
                    }
                    .frame(width: 230, alignment: .leading)
                }
            } else {
                Text("Flatten your headphones' frequency response with a measured correction from the AutoEq database (thousands of models).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search headphones, e.g. AirPods Pro, HD 650", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.searchAutoEQ(query) } }
                if model.isApplyingAutoEQ { ProgressView().controlSize(.small) }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            .task(id: query) {   // debounced; a newer query cancels the older search
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.searchAutoEQ(query)
            }
            if let status = model.autoEQStatus { Text(status).font(.caption).foregroundStyle(Theme.amber) }
            if !model.autoEQResults.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.autoEQResults) { e in
                            Button { Task { await model.applyAutoEQ(e) } } label: {
                                HStack {
                                    Text(e.name).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(e.rig.map { "\(e.source) · \($0)" } ?? e.source).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(hp.correction?.name == e.name && hp.correction?.source == e.source ? Theme.cyan.opacity(0.18) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func crossfeedCard(_ hp: HeadphoneSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crossfeed").font(.headline)
            Picker("", selection: Binding(get: { hp.crossfeed }, set: { v in model.updateHeadphones { $0.crossfeed = v } })) {
                ForEach(CrossfeedStrength.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(hp.spatialEnabled)
            Text(hp.spatialEnabled ? "Off while Spatial audio is on." :
                 "Blends a little of each side's bass into the other ear, like speakers in a room. Centred sound is untouched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func spatialCard(_ hp: HeadphoneSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spatial audio").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { hp.spatialEnabled }, set: { v in model.updateHeadphones { $0.spatialEnabled = v } }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.cyan)
            }
            slider("Width", value: hp.spatial.width, range: SpatialParameters.widthRange, format: "%.0f°") { v in
                model.updateHeadphones { $0.spatial.width = v }
            }
            slider("Room", value: hp.spatial.room * 100, range: 0...100, format: "%.0f%%") { v in
                model.updateHeadphones { $0.spatial.room = v / 100 }
            }
            Text("Places your stereo on two virtual speakers in front of you (HRTF).").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, format: String,
                        set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range).tint(Theme.violet)
            Text(String(format: format, value)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.importCorrection(from: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ParametricEQ", with: "")) }
        catch { importError = "That file isn't a ParametricEQ.txt profile." }
    }
}

/// Small response plot of a correction profile.
struct CorrectionCurve: View {
    let profile: CorrectionProfile
    let sampleRate: Double

    var body: some View {
        Canvas { ctx, size in
            let g = EQGeometry(size: size)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                       with: .color(.white.opacity(0.12)))
            var p = Path()
            for i in 0...120 {
                let x = size.width * CGFloat(i) / 120
                let db = EQResponse.decibels(bands: profile.bands, preampDB: 0, frequency: g.frequency(atX: x), sampleRate: sampleRate)
                let y = size.height / 2 - CGFloat(max(min(db, 12), -12) / 12) * size.height / 2
                i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(p, with: .linearGradient(Gradient(colors: [Theme.cyan, Theme.violet]), startPoint: .zero,
                                                endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 2)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
    }
}
