import AppKit
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
import CoreAudioKit
import EquinoxCore
import EquinoxDSP
import SwiftUI

struct EffectsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Effects").font(.system(.title2, design: .rounded).weight(.bold))
                Spacer()
                addMenu
            }
            Text("Effects run after the EQ, in order from left to right. They're saved with the preset.")
                .font(.caption).foregroundStyle(.secondary)
            if model.working.effects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    Text("No effects yet").font(.headline)
                    Text("Add reverb, compression, a limiter, a delay, or any Audio Unit installed on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .glassCard()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(model.working.effects.enumerated()), id: \.element.id) { index, slot in
                            if index > 0 { Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 80) }
                            EffectCard(model: model, slot: slot, index: index, count: model.working.effects.count)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(24)
        .onAppear { model.refreshPlugins() }
    }

    private var addMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(BuiltInEffect.allCases, id: \.self) { e in
                    Button { model.addEffect(.builtIn(e)) } label: { Label(e.displayName, systemImage: e.symbol) }
                }
            }
            Section("Audio Units") {
                let byMaker = Dictionary(grouping: model.availablePlugins, by: \.manufacturerName)
                ForEach(byMaker.keys.sorted(), id: \.self) { maker in
                    Menu(maker) {
                        ForEach(byMaker[maker]!, id: \.self) { au in Button(au.name) { model.addEffect(.audioUnit(au)) } }
                    }
                }
            }
        } label: { Label("Add Effect", systemImage: "plus") }
        .menuStyle(.button).fixedSize()
    }
}

struct EffectCard: View {
    @Bindable var model: AppModel
    var slot: EffectSlot
    var index: Int
    var count: Int

    var body: some View {
        let crashed = model.isDisabledByCrash(slot)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(slot.isEnabled && !crashed ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.gray))
                    .frame(width: 30)
                Spacer()
                Toggle("", isOn: Binding(get: { slot.isEnabled }, set: { model.setEffectEnabled(slot.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.cyan).disabled(crashed)
            }
            Text(slot.kind.displayName).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if crashed {
                Text("Turned off after it crashed while loading.").font(.caption2).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                if case .audioUnit(let id) = slot.kind { Button("Turn Back On") { model.reenablePlugin(id.key) }.controlSize(.small) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button { model.moveEffect(slot.id, by: -1) } label: { Image(systemName: "arrow.left") }.disabled(index == 0)
                Button { model.moveEffect(slot.id, by: 1) } label: { Image(systemName: "arrow.right") }.disabled(index == count - 1)
                Spacer()
                Button("Edit") { PluginWindows.shared.open(slot: slot, model: model) }.disabled(crashed)
                Button(role: .destructive) { PluginWindows.shared.close(slot.id); model.removeEffect(slot.id) } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
        .frame(width: 170, height: 170, alignment: .topLeading)
        .glassCard(cornerRadius: 18, padding: 14)
        .opacity(slot.isEnabled && !crashed ? 1 : 0.6)
    }

    private var icon: String {
        if case .builtIn(let e) = slot.kind { return e.symbol }
        return "puzzlepiece.extension"
    }

    private var subtitle: String {
        switch slot.kind {
        case .builtIn: "Built-in"
        case .audioUnit(let id): id.manufacturerName
        }
    }
}

/// Sliders for every parameter of a unit (used when a plugin has no custom view, and for built-ins).
struct GenericParameterView: View {
    let unit: AUAudioUnit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(unit.parameterTree?.allParameters ?? [], id: \.address) { p in ParameterRow(parameter: p) }
            }
            .padding(18)
        }
        .frame(minWidth: 380, minHeight: 200)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

private struct ParameterRow: View {
    let parameter: AUParameter
    @State private var value: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(display)
                    .font(.system(size: 11, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { value = $0; parameter.setValue($0, originator: nil) }),
                   in: parameter.minValue...max(parameter.maxValue, parameter.minValue + 0.0001))
                .tint(Theme.cyan).controlSize(.small)
        }
        .foregroundStyle(.white)
        .onAppear { value = parameter.value }
    }

    private var display: String {
        var v = value
        let text = parameter.string(fromValue: &v)
        let number = text.isEmpty ? (abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)) : text
        return number + (parameter.unitName.map { " \($0)" } ?? "")
    }
}

/// One window per open effect: the plugin's own UI when it has one, otherwise generic sliders.
/// Windows follow chain rebuilds: a window whose unit was replaced is reopened on the new unit; a window whose
/// effect is gone is closed.
@MainActor
final class PluginWindows {
    static let shared = PluginWindows()

    private struct Entry {
        let window: NSWindow
        let unit: AUAudioUnit
        let closeObserver: NSObjectProtocol
    }

    private var windows: [UUID: Entry] = [:]
    private var opening: Set<UUID> = []

    func open(slot: EffectSlot, model: AppModel) {
        if let entry = windows[slot.id] { entry.window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        guard !opening.contains(slot.id) else { return }          // a request is already in flight
        guard let unit = model.effectUnit(for: slot.id) else { NSSound.beep(); return }
        opening.insert(slot.id)
        unit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.opening.remove(slot.id)
                    guard model.effectUnit(for: slot.id) === unit else { return }   // chain rebuilt meanwhile
                    self.present(slot: slot, unit: unit, controller: controller)
                }
            }
        }
    }

    private func present(slot: EffectSlot, unit: AUAudioUnit, controller: NSViewController?) {
        let content: NSViewController = controller ?? NSHostingController(rootView: GenericParameterView(unit: unit))
        let window = NSWindow(contentViewController: content)
        window.title = slot.kind.displayName
        window.styleMask.insert(.closable)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let id = slot.id
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.forget(id) }
        }
        windows[id] = Entry(window: window, unit: unit, closeObserver: observer)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Call after the effects chain was rebuilt.
    func revalidate(_ model: AppModel) {
        for (id, entry) in windows where model.effectUnit(for: id) !== entry.unit {
            close(id)
            if let slot = model.working.effects.first(where: { $0.id == id }), model.effectUnit(for: id) != nil {
                open(slot: slot, model: model)
            }
        }
    }

    func close(_ id: UUID) {
        guard let entry = forget(id) else { return }
        entry.window.close()
    }

    @discardableResult
    private func forget(_ id: UUID) -> Entry? {
        guard let entry = windows.removeValue(forKey: id) else { return nil }
        NotificationCenter.default.removeObserver(entry.closeObserver)
        return entry
    }
}
