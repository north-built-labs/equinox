import AppKit
import EquinoxCore
import SwiftUI
import UniformTypeIdentifiers

struct PresetBar: View {
    @Bindable var model: AppModel
    var compact = false
    @State private var naming = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var importError: String?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Built-in") {
                    ForEach(model.presets.filter(\.isBuiltIn)) { p in Button(p.name) { model.selectPreset(p.id) } }
                }
                if !model.userPresets.isEmpty {
                    Section("My Presets") {
                        ForEach(model.userPresets) { p in Button(p.name) { model.selectPreset(p.id) } }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text(model.selectedPreset.name).lineLimit(1)
                    if model.isModified { Circle().fill(Theme.amber).frame(width: 6, height: 6) }
                }
            }
            .menuStyle(.button)
            .fixedSize()

            if !compact {
                Button("Save") { model.save() }
                    .disabled(!model.isModified || model.selectedPreset.isBuiltIn)
                Button("Save As…") { newName = model.selectedPreset.name; naming = true }
                Button("Revert") { model.revert() }.disabled(!model.isModified)
                Menu {
                    Button("Rename…") { newName = model.selectedPreset.name; renaming = true }
                        .disabled(model.selectedPreset.isBuiltIn)
                    Button("Import…", action: importPresets)
                    Button("Export Current…") { export([model.selectedPresetID]) }
                    Button("Export All My Presets…") { export(model.userPresets.map(\.id)) }.disabled(model.userPresets.isEmpty)
                    Divider()
                    Button("Delete Preset", role: .destructive) { model.deletePreset(model.selectedPresetID) }
                        .disabled(model.selectedPreset.isBuiltIn)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .alert("Save Preset As", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { model.saveAs(name: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Preset", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.renamePreset(model.selectedPresetID, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.importPresets(from: Data(contentsOf: url)) }
        catch { importError = "That file isn't an Equinox preset." }
    }

    private func export(_ ids: [UUID]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ids.count == 1 ? "\(model.selectedPreset.name).json" : "Equinox Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportData(for: ids).write(to: url, options: .atomic) }
        catch { importError = "Could not export: \(error.localizedDescription)" }
    }
}
