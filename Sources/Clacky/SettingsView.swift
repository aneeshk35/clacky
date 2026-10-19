import AppKit
import SwiftUI

enum SettingsTab: String {
    case sound, output, quiet, general
}

/// The Settings window (⌘,): everything that isn't needed every day, one topic per tab.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("settingsTab") private var tab = SettingsTab.sound

    var body: some View {
        TabView(selection: $tab) {
            SoundSettings(model: model)
                .tabItem { Label("Sound", systemImage: "waveform") }
                .tag(SettingsTab.sound)
            OutputSettings(model: model)
                .tabItem { Label("Output", systemImage: "hifispeaker") }
                .tag(SettingsTab.output)
            QuietSettings(model: model)
                .tabItem { Label("Stay Quiet", systemImage: "moon") }
                .tag(SettingsTab.quiet)
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 500)
        .tint(Theme.accent)
    }
}

/// A settings page: a grouped form exactly as tall as what's in it.
private struct Page<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form(content: content)
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SoundSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                LabeledContent("Stereo width") {
                    Slider(value: $model.stereoWidth, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Center")
                    } maximumValueLabel: {
                        Text("Wide")
                    }
                }
            } footer: {
                Note("Wide: keys come from where they sit on the keyboard, left to right.")
            }
            Section {
                Toggle("Key release sounds", isOn: $model.playsKeyUp)
            } footer: {
                Note(model.hasReleaseSounds
                     ? "A softer second sound when you let go of a key, like a real switch springing back up."
                     : "A softer second sound when you let go of a key. The switch you're using has no release recordings, so it only sounds on press.")
            }
            Section {
                Toggle("Every key sounds a little different", isOn: Binding(
                    get: { model.variesByKey },
                    set: { model.variesByKey = $0; model.previewSoon() }
                ))
            } footer: {
                Note("Like a real keyboard, where keys in different spots don't sound quite the same. Each key keeps its own sound.")
            }
        }
    }
}

private struct OutputSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Picker("Play through", selection: $model.outputChoice) {
                    Text("Automatic").tag("")
                    ForEach(model.outputOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
            } footer: {
                if let status = model.outputStatus {
                    Note(status, color: Theme.warning)
                } else {
                    Note("Automatic follows your Mac's sound output, and switches to your Mac's speakers when that output can't play (a monitor without speakers, say).")
                }
            }
        }
    }
}

private struct QuietSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            if model.canWatchMicrophone {
                Section {
                    Toggle("While the microphone is on", isOn: $model.quietWhileMicOn)
                } footer: {
                    Note("Pauses during calls, recordings and dictation, so nobody else hears the clicks.")
                }
            }
            Section {
                if model.quietApps.isEmpty {
                    Text("No apps yet")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.quietApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: app.id))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text(app.name)
                        Spacer()
                        Button("Remove") { model.unquiet(app) }
                    }
                }
                Menu("Add App") {
                    ForEach(model.appsToQuiet) { app in
                        Button(app.name) { model.quiet(app) }
                    }
                    Divider()
                    Button("Choose…") { model.chooseAppToQuiet() }
                }
                .fixedSize()
            } header: {
                Text("In these apps")
            } footer: {
                Note("Clacky is silent while one of these apps is in front, for games, say.")
            }
        }
    }

    private static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Page {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                ))
                LabeledContent("Turn on or off from any app") {
                    Text(model.hasShortcut ? AppModel.shortcut.label : "Unavailable")
                        .foregroundStyle(Theme.secondary)
                }
            } footer: {
                if !model.hasShortcut {
                    Note("Another app is using \(AppModel.shortcut.label).")
                }
            }
            Section {
                LabeledContent("Sound packs") {
                    HStack {
                        Button("Open Folder") { model.openPacksFolder() }
                        Button("Reload") { model.reloadPacks() }
                    }
                }
            } footer: {
                Note("Each folder in there is a switch. Reload after adding or changing one.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Quit Clacky") { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }
}

private struct Note: View {
    let text: String
    var color: Color = Theme.secondary

    init(_ text: String, color: Color = Theme.secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Opens Settings, optionally on a given tab.
struct SettingsButton<Label: View>: View {
    var tab: SettingsTab?
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 14, *) {
            Modern(tab: tab, label: label)
        } else {
            Button {
                select(tab)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                label()
            }
        }
    }

    @available(macOS 14, *)
    private struct Modern: View {
        let tab: SettingsTab?
        let label: () -> Label
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Button {
                select(tab)
                openSettings()
            } label: {
                label()
            }
        }
    }
}

private func select(_ tab: SettingsTab?) {
    if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
}
