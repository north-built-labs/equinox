import EquinoxCore
import EquinoxDSP
import SwiftUI

/// Gain-only view over the same bands, sorted by frequency.
struct GraphicEQView: View {
    @Bindable var model: AppModel

    var body: some View {
        let bands = model.working.bands.enumerated().sorted { $0.element.frequency < $1.element.frequency }
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(bands, id: \.element.id) { i, band in
                VStack(spacing: 6) {
                    Text(String(format: "%+.1f", band.gainDB))
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                    VerticalSlider(value: Binding(get: { band.gainDB }, set: { v in model.updateBand(band.id) { $0.gainDB = v } }),
                                   range: EQBand.gainRange, tint: Theme.bandColor(i))
                        .frame(height: 150)
                        .opacity(band.type.usesGain && band.isEnabled ? 1 : 0.35)
                        .disabled(!band.type.usesGain)
                    Text(Theme.hz(band.frequency)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 44)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
