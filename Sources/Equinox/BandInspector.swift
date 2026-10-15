import EquinoxCore
import EquinoxDSP
import SwiftUI

struct BandInspector: View {
    @Bindable var model: AppModel
    @Binding var selectedBandID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.working.bands.enumerated()), id: \.element.id) { i, band in
                        Button { selectedBandID = band.id } label: {
                            HStack(spacing: 5) {
                                Circle().fill(band.isEnabled ? Theme.bandColor(i) : .gray).frame(width: 7, height: 7)
                                Text(Theme.hz(band.frequency)).monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(band.id == selectedBandID ? .white.opacity(0.18) : .white.opacity(0.06)))
                        }.buttonStyle(.plain)
                    }
                    Button {
                        selectedBandID = model.addBand(frequency: 1000, gainDB: 0)
                    } label: { Image(systemName: "plus").padding(6).background(Circle().fill(.white.opacity(0.06))) }
                        .buttonStyle(.plain)
                        .disabled(model.working.bands.count >= BiquadBank.maxSections)
                        .help("Add band")
                }
            }
            if let id = selectedBandID, let band = model.working.bands.first(where: { $0.id == id }) {
                HStack(spacing: 14) {
                    Picker("", selection: bind(id, \.type, band.type)) {
                        ForEach(FilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width: 120)
                    field("Freq", bind(id, \.frequency, band.frequency), unit: "Hz", format: .number.precision(.fractionLength(0)))
                    field("Gain", bind(id, \.gainDB, band.gainDB), unit: "dB", format: .number.precision(.fractionLength(1)))
                        .disabled(!band.type.usesGain)
                    field("Q", bind(id, \.q, band.q), unit: "", format: .number.precision(.fractionLength(2)))
                    Toggle("On", isOn: bind(id, \.isEnabled, band.isEnabled)).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Button(role: .destructive) { model.removeBand(id); selectedBandID = nil } label: { Image(systemName: "trash") }
                        .help("Delete band")
                }
            } else {
                Text("Drag a node to shape the sound · double-click to add · pinch to change width · right-click for options")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bind<V>(_ id: UUID, _ key: WritableKeyPath<EQBand, V>, _ current: V) -> Binding<V> {
        Binding(get: { model.working.bands.first { $0.id == id }?[keyPath: key] ?? current },
                set: { v in model.updateBand(id) { $0[keyPath: key] = v } })
    }

    private func field(_ label: String, _ value: Binding<Double>, unit: String,
                       format: FloatingPointFormatStyle<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: format).textFieldStyle(.roundedBorder).frame(width: 64)
                .font(.system(size: 12, design: .rounded).monospacedDigit())
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
