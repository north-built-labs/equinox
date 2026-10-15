import EquinoxCore
import EquinoxDSP
import SwiftUI

struct EQCanvasView: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    var interactive = true
    @Binding var selectedBandID: UUID?

    @State private var dragBandID: UUID?
    @State private var hoverBandID: UUID?
    @State private var pinchStartQ: Double?

    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]

    var body: some View {
        let levels = spectrum.levels
        let bands = model.working.bands
        let preamp = model.working.preampDB
        let rate = model.sampleRate
        let enabled = model.isEnabled
        GeometryReader { geo in
            let g = EQGeometry(size: geo.size)
            Canvas { ctx, size in
                drawGrid(ctx, g, size)
                drawSpectrum(ctx, g, size, levels)
                drawCurve(ctx, g, size, bands, preamp, rate, enabled)
                if interactive { drawNodes(ctx, g, bands) }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(g), including: interactive ? .all : .none)
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                guard interactive, nearestBand(to: v.location, in: g) == nil else { return }
                selectedBandID = model.addBand(frequency: g.frequency(atX: v.location.x), gainDB: g.db(atY: v.location.y))
            }, including: interactive ? .all : .none)
            .simultaneousGesture(MagnifyGesture().onChanged { v in
                guard let id = selectedBandID, let band = bands.first(where: { $0.id == id }) else { return }
                if pinchStartQ == nil { pinchStartQ = band.q }
                model.updateBand(id) { $0.q = (pinchStartQ ?? 1) * Double(v.magnification) }
            }.onEnded { _ in pinchStartQ = nil }, including: interactive ? .all : .none)
            .onContinuousHover { phase in
                guard interactive else { return }
                if case .active(let p) = phase { hoverBandID = nearestBand(to: p, in: g) } else { hoverBandID = nil }
            }
            .contextMenu { if interactive { bandMenu } }
        }
        .onAppear { spectrum.attach() }
        .onDisappear { spectrum.detach() }
    }

    // MARK: Interaction

    private func nearestBand(to p: CGPoint, in g: EQGeometry) -> UUID? {
        model.working.bands
            .map { b in (b.id, hypot(g.x(for: b.frequency) - p.x, g.y(forDB: nodeDB(b)) - p.y)) }
            .filter { $0.1 < 16 }
            .min { $0.1 < $1.1 }?.0
    }

    private func nodeDB(_ b: EQBand) -> Double { b.type.usesGain ? b.gainDB : 0 }

    private func dragGesture(_ g: EQGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBandID == nil {
                    dragBandID = nearestBand(to: v.startLocation, in: g)
                    if let id = dragBandID { selectedBandID = id }
                }
                guard let id = dragBandID else { return }
                let f = g.frequency(atX: v.location.x), db = g.db(atY: v.location.y)
                model.updateBand(id) { band in
                    band.frequency = f
                    if band.type.usesGain { band.gainDB = (db * 10).rounded() / 10 }
                }
            }
            .onEnded { _ in dragBandID = nil }
    }

    @ViewBuilder private var bandMenu: some View {
        if let id = hoverBandID ?? selectedBandID, let band = model.working.bands.first(where: { $0.id == id }) {
            Picker("Type", selection: Binding(get: { band.type }, set: { t in model.updateBand(id) { $0.type = t } })) {
                ForEach(FilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Enabled", isOn: Binding(get: { band.isEnabled }, set: { v in model.updateBand(id) { $0.isEnabled = v } }))
            Button("Reset Gain") { model.updateBand(id) { $0.gainDB = 0 } }
            Divider()
            Button("Delete Band", role: .destructive) { model.removeBand(id); selectedBandID = nil }
        } else {
            Text("Double-click to add a band")
        }
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ g: EQGeometry, _ size: CGSize) {
        for f in Self.gridFrequencies {
            let x = g.x(for: f)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                       with: .color(.white.opacity(0.05)), lineWidth: 1)
            if interactive {
                ctx.draw(Text(Theme.hz(f)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.35)),
                         at: CGPoint(x: min(max(x, 10), size.width - 12), y: size.height - 8))
            }
        }
        for db in stride(from: -18.0, through: 18.0, by: 6.0) {
            let y = g.y(forDB: db)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .color(.white.opacity(db == 0 ? 0.16 : 0.05)), lineWidth: 1)
            if interactive && db != 0 {
                ctx.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.3)),
                         at: CGPoint(x: 14, y: y - 7))
            }
        }
    }

    private func drawSpectrum(_ ctx: GraphicsContext, _ g: EQGeometry, _ size: CGSize, _ levels: [Float]) {
        guard !levels.isEmpty else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, level) in levels.enumerated() {
            let t = CGFloat(min(max((Double(level) + 90) / 90, 0), 1))
            path.addLine(to: CGPoint(x: g.x(for: spectrum.frequencies[i]), y: size.height - t * size.height * 0.85))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .linearGradient(Gradient(colors: [Theme.violet.opacity(0.45), Theme.cyan.opacity(0.05)]),
                                             startPoint: CGPoint(x: 0, y: size.height * 0.15),
                                             endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawCurve(_ ctx: GraphicsContext, _ g: EQGeometry, _ size: CGSize, _ bands: [EQBand],
                           _ preamp: Double, _ rate: Double, _ enabled: Bool) {
        let steps = max(Int(size.width / 3), 64)
        var curve = Path()
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let db = EQResponse.decibels(bands: bands, preampDB: preamp, frequency: g.frequency(atX: x), sampleRate: rate)
            let p = CGPoint(x: x, y: g.y(forDB: min(max(db, -EQGeometry.dbRange), EQGeometry.dbRange)))
            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: size.width, y: g.y(forDB: 0)))
        fill.addLine(to: CGPoint(x: 0, y: g.y(forDB: 0)))
        fill.closeSubpath()
        let opacity = enabled ? 1.0 : 0.35
        ctx.fill(fill, with: .color(Theme.cyan.opacity(0.08 * opacity)))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.stroke(curve, with: .color(Theme.cyan.opacity(0.6 * opacity)), lineWidth: 5)
        }
        ctx.stroke(curve, with: .linearGradient(Gradient(colors: [Theme.cyan.opacity(opacity), Theme.violet.opacity(opacity)]),
                                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func drawNodes(_ ctx: GraphicsContext, _ g: EQGeometry, _ bands: [EQBand]) {
        for (i, b) in bands.enumerated() {
            let c = CGPoint(x: g.x(for: b.frequency), y: g.y(forDB: nodeDB(b)))
            let selected = b.id == selectedBandID, hovered = b.id == hoverBandID
            let r: CGFloat = selected ? 9 : (hovered ? 8 : 7)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let color = Theme.bandColor(i)
            if b.isEnabled {
                ctx.drawLayer { l in l.addFilter(.blur(radius: 5)); l.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.6))) }
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                ctx.stroke(Path(ellipseIn: rect), with: .color(.gray), lineWidth: 1.5)
            }
            if selected { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 2) }
            ctx.draw(Text("\(i + 1)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.75)), at: c)
        }
    }
}
