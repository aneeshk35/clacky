import SwiftUI

/// The main window: on/off, the switch, and how loud and deep it sounds. Everything else is in Settings.
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 18)
            Rule()
            VStack(alignment: .leading, spacing: 22) {
                notices
                switches
                levels
            }
            .padding(22)
            Rule()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .background(Theme.ground)
        .background(WindowChrome())
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12.5, style: .continuous))  // the artwork is square; the Dock rounds it
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Clacky")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 7) {
                    statusMark
                    Text(status.text)
                        .foregroundStyle(status.isProblem ? Theme.warning : Theme.secondary)
                        .lineLimit(2)
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            Toggle("Enabled", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .help("Turn Clacky on or off (\(AppModel.shortcut.label) from any app)")
        }
    }

    /// A lit dot while it's playing, a dim one while it's off, and an icon for anything in the way.
    @ViewBuilder
    private var statusMark: some View {
        if let symbol = status.symbol {
            Image(systemName: symbol)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(model.isEnabled ? Theme.accent : Theme.dashed)
                .frame(width: 7, height: 7)
                .background(Circle().fill(Theme.accent.opacity(model.isEnabled ? 0.2 : 0)).frame(width: 13, height: 13))
                .accessibilityHidden(true)
        }
    }

    private var status: (text: String, symbol: String?, isProblem: Bool) {
        if !model.hasPermission {
            return ("Needs permission to hear your keys", "exclamationmark.triangle.fill", true)
        }
        if !model.isEnabled {
            return ("Off", nil, false)
        }
        if let message = model.microphoneMessage {
            return (message, "mic.fill", true)
        }
        guard let output = model.activeOutputName else {
            return ("No sound output can play right now", "exclamationmark.triangle.fill", true)
        }
        return ("Playing through \(output)", nil, false)
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if !model.hasPermission {
            Notice(symbol: "keyboard", color: Theme.warning,
                   text: "Allow Clacky under Input Monitoring so it can hear your keystrokes. Sounds start a couple of seconds after you switch it on.") {
                Button("Open Input Monitoring") { model.openInputMonitoringSettings() }
            }
        }
        if let status = model.outputStatus {
            Notice(symbol: "hifispeaker.fill", color: Theme.warning, text: status) {
                SettingsButton(tab: .output) { Text("Sound Output…") }
            }
        }
        if let error = model.errorMessage {
            Notice(symbol: "exclamationmark.octagon.fill", color: Theme.danger, text: error) {
                EmptyView()
            }
        }
    }

    // MARK: Switches

    private var switches: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Switch")
                    .font(.headline)
                Spacer()
                Button {
                    model.preview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.accent))
                        Text("Preview")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.soundOptions.isEmpty)
            }
            if model.soundOptions.isEmpty {
                Notice(symbol: "folder", color: Theme.secondary,
                       text: "No sounds yet. Add a folder of recordings to the Sound Packs folder, then reload.") {
                    Button("Open Folder") { model.openPacksFolder() }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(model.soundOptions) { option in
                        SwitchCard(option: option, isSelected: option.id == model.soundID) {
                            model.soundID = option.id
                            model.preview()
                        }
                    }
                    AddSoundsCard { model.openPacksFolder() }
                }
            }
        }
    }

    // MARK: Volume and tone

    private var levels: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                Text("Volume")
                    .gridColumnAlignment(.trailing)
                Slider(value: $model.volume, in: 0...1)
                Text("\(Int((model.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 104, alignment: .leading)
            }
            GridRow {
                Text("Tone")
                Slider(value: Binding(get: { model.tone }, set: { model.tone = $0; model.previewSoon() }),
                       in: -1...1, step: 0.25)
                Text(toneName)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 104, alignment: .leading)
            }
        }
    }

    private var toneName: String {
        switch model.tone {
        case ..<(-0.9): return "Deepest"
        case ..<(-0.3): return "Deeper"
        case ..<(-0.1): return "A bit deeper"
        case ..<0.1: return "As recorded"
        case ..<0.3: return "A bit brighter"
        case ..<0.9: return "Brighter"
        default: return "Brightest"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.hasShortcut {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(Array(AppModel.shortcut.label), id: \.self) { key in
                            KeyChip(key: String(key))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AppModel.shortcut.label)
                    Text("turns Clacky on or off from any app")
                }
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
            Spacer()
            SettingsButton {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(RaisedButtonStyle())
        }
    }
}

/// One sound pack, as a card you click to choose (and hear).
private struct SwitchCard: View {
    let option: AppModel.SoundOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Keycap(colors: Theme.keycap(for: option.name))
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(option.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .cardStyle(isSelected ? .selected : .plain)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(option.summary)
    }
}

/// The last card: where your own sounds go.
private struct AddSoundsCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 30, height: 31)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Your Own")
                        .font(.body.weight(.semibold))
                    Text("Each folder in Sound Packs is a switch.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .cardStyle(.dashed)
        }
        .buttonStyle(.plain)
        .help("Open the Sound Packs folder")
    }
}

private enum CardLook {
    case plain, selected, dashed
}

private extension View {
    func cardStyle(_ look: CardLook) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
            .background(shape.fill(look == .selected ? Theme.accent.opacity(0.12)
                                   : look == .plain ? Theme.card : Color.clear))
            .overlay {
                switch look {
                case .selected: shape.strokeBorder(Theme.accent, lineWidth: 2)
                case .plain: shape.strokeBorder(Theme.line, lineWidth: 1)
                case .dashed: shape.strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .shadow(color: look == .selected ? Theme.accent.opacity(0.18) : .clear, radius: 8, y: 3)
            .contentShape(shape)
    }
}

/// A small keycap in the switch's color, echoing the app icon.
private struct Keycap: View {
    let colors: Theme.Keycap

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colors.side)
                .frame(width: 30, height: 31)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(colors.top)
                .frame(width: 22, height: 22)
                .padding(.top, 2)
        }
        .accessibilityHidden(true)
    }
}

/// One key of a shortcut, drawn as a key.
private struct KeyChip: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(Theme.text)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.raised))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
    }
}

/// A quiet button on a raised chip, like the Settings button.
struct RaisedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundStyle(Theme.text)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A one-point line between the window's sections.
private struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.raised)
            .frame(height: 1)
    }
}

/// A tinted box with an icon, a message and an optional button.
private struct Notice<Action: View>: View {
    let symbol: String
    let color: Color
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
    }
}

/// Paints the title bar in the window's own color, so the window reads as one piece.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.groundColor
        }
    }
}
