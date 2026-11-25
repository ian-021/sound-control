import SwiftUI

struct MixerView: View {
    let model: MixerModel
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OutputSection(model: model)
            if model.permission != .granted { PermissionNotice(model: model) }
            Divider()
            if model.apps.isEmpty {
                Text("Apps appear here when they play sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.apps) { AppRow(model: model, app: $0) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, 420))
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var footer: some View {
        HStack {
            Button("Reset All") { model.resetAll() }
                .buttonStyle(.borderless)
                .disabled(!model.hasAdjustments)
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                Divider()
                Button("Quit SoundSystem") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options")
        }
        .font(.callout)
    }
}

/// Separate so that dragging the output volume redraws this row and not the whole panel.
private struct OutputSection: View {
    let model: MixerModel

    var body: some View {
        if let output = model.output { OutputRow(model: model, output: output) }
    }
}

private struct OutputRow: View {
    let model: MixerModel
    let output: OutputDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(output.name).font(.headline).lineLimit(1)
            if let volume = output.volume {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { output.isMuted ? 0 : volume }, set: { model.setOutputVolume($0) }), in: 0...1)
                        .accessibilityLabel("\(output.name) volume")
                    if output.canMute {
                        MuteButton(isMuted: output.isMuted, volume: volume, name: output.name) { model.toggleOutputMute() }
                    }
                }
            } else {
                Text("This output’s volume is set on the device itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppRow: View {
    let model: MixerModel
    let app: MixerApp

    var body: some View {
        let setting = model.setting(for: app)
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1).foregroundStyle(app.isPlaying ? .primary : .secondary)
                    if let problem = app.problem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .help(problem)
                            .accessibilityLabel(problem)
                    }
                    Spacer()
                    Text(setting.muted ? "Muted" : "\(Int((setting.volume * 100).rounded()))%")
                        .foregroundStyle(.primary.opacity(0.75))
                        .monospacedDigit()
                }
                .font(.callout)
                Slider(value: Binding(get: { setting.muted ? 0 : setting.volume }, set: { model.setVolume($0, for: app) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("\(app.name) volume")
            }
            MuteButton(isMuted: setting.muted, volume: setting.volume, name: app.name) { model.toggleMute(app) }
        }
    }

    @ViewBuilder private var icon: some View {
        Group {
            if let path = app.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(4).foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .opacity(app.isPlaying ? 1 : 0.6)
        .accessibilityHidden(true)
    }
}

private struct MuteButton: View {
    let isMuted: Bool
    let volume: Float
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", variableValue: isMuted ? 1 : Double(volume))
                .foregroundStyle(isMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute \(name)" : "Mute \(name)")
        .accessibilityLabel(isMuted ? "Unmute \(name)" : "Mute \(name)")
    }
}

private struct PermissionNotice: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow audio access to change app volumes")
                .font(.callout.weight(.semibold))
            Text(model.permission == .denied
                 ? "Turn on SoundSystem under System Audio Recording Only. Nothing is recorded or saved."
                 : "macOS calls this system audio recording. Nothing is recorded or saved.")
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button(model.permission == .denied ? "Open Settings" : "Allow…") { model.requestPermission() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
    }
}
