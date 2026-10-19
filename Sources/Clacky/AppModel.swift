import AppKit
import Carbon.HIToolbox
import ClackyCore
import os
import ServiceManagement

private let log = Logger(subsystem: "com.aneeshkolluri.Clacky", category: "keys")

enum SoundSelectionError: LocalizedError {
    case unavailable
    var errorDescription: String? { "That sound isn't available. Pick another from the list." }
}

/// App state: settings (persisted), the selected sound, and the wiring from key monitor to audio.
final class AppModel: ObservableObject {
    struct SoundOption: Identifiable, Hashable {
        let id: String
        let name: String
        let summary: String
    }

    struct OutputOption: Identifiable, Hashable {
        let id: String  // the device's UID
        let name: String
    }

    struct QuietApp: Identifiable, Hashable {
        let id: String  // bundle identifier
        let name: String
    }

    /// Turns Clacky on and off from any app.
    static let shortcut = (keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey | cmdKey, label: "⌃⌥⌘C")

    /// Each subfolder here is a sound pack of recordings; see README.md for file naming.
    static let packsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clacky/Sound Packs", isDirectory: true)

    /// The packs that ship inside the app. A pack in `packsFolder` with the same name replaces one of these.
    static let bundledPacksFolder = Bundle.main.resourceURL?.appendingPathComponent("Sound Packs", isDirectory: true)

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            updateDockBadge()
        }
    }
    @Published var soundID: String {
        didSet {
            UserDefaults.standard.set(soundID, forKey: Key.sound)
            applySelectedSound()
        }
    }
    @Published var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Key.volume)
            engine?.volume = Float(volume)
        }
    }
    @Published var stereoWidth: Double {
        didSet {
            UserDefaults.standard.set(stereoWidth, forKey: Key.stereoWidth)
            engine?.stereoWidth = Float(stereoWidth)
        }
    }
    @Published var playsKeyUp: Bool { didSet { UserDefaults.standard.set(playsKeyUp, forKey: Key.keyUp) } }
    /// -1 deeper … 0 as recorded … 1 brighter.
    @Published var tone: Double {
        didSet {
            UserDefaults.standard.set(tone, forKey: Key.tone)
            engine?.bank?.tone = Float(tone)
        }
    }
    @Published var variesByKey: Bool {
        didSet {
            UserDefaults.standard.set(variesByKey, forKey: Key.variesByKey)
            engine?.bank?.variesByKey = variesByKey
        }
    }
    @Published var quietWhileMicOn: Bool {
        didSet {
            UserDefaults.standard.set(quietWhileMicOn, forKey: Key.quietWhileMicOn)
            updateMicrophoneWatching()
        }
    }
    /// Apps Clacky stays silent in, sorted by name.
    @Published private(set) var quietApps: [QuietApp] = []
    /// Another app recording from the microphone, while `quietWhileMicOn` is on.
    @Published private(set) var microphoneUser: MicrophoneWatcher.Recorder?
    /// False if another app already took the on/off shortcut.
    @Published private(set) var hasShortcut = false
    /// Where the sounds play, by device UID; empty means Automatic (follow the Mac's sound output).
    @Published var outputChoice: String {
        didSet {
            UserDefaults.standard.set(outputChoice, forKey: Key.output)
            if let option = outputOptions.first(where: { $0.id == outputChoice }) {
                UserDefaults.standard.set(option.name, forKey: Key.outputName)
            }
            engine?.outputChoice = outputChoice.isEmpty ? nil : outputChoice
        }
    }
    @Published private(set) var outputOptions: [OutputOption] = []
    /// Plain-English note about where sound is going, when it isn't simply the chosen output.
    @Published private(set) var outputStatus: String?
    /// The output sound is playing through (nil while none can play).
    @Published private(set) var activeOutputName: String?
    @Published private(set) var soundOptions: [SoundOption] = []
    @Published private(set) var hasPermission = false
    @Published private(set) var errorMessage: String?
    /// True while the output isn't taking audio; Clacky resumes on its own when it does.
    private var isAudioStalled = false

    private let monitor = KeyMonitor()
    private var engine: SoundEngine?
    private var banks: [String: SoundBank] = [:]
    private var permissionTimer: Timer?
    private let microphone = MicrophoneWatcher()
    private var hotKey: HotKey?
    private var frontmostAppID: String?
    private var pendingPreview: DispatchWorkItem?

    private enum Key {
        static let enabled = "enabled"
        static let sound = "sound"
        static let volume = "volume"
        static let stereoWidth = "stereoWidth"
        static let keyUp = "playsKeyUp"
        static let output = "output"
        static let outputName = "outputName"
        static let tone = "tone"
        static let variesByKey = "variesByKey"
        static let quietWhileMicOn = "quietWhileMicOn"
        static let quietApps = "quietApps"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.enabled: true,
            Key.sound: SwitchProfile.all.first.map { "synth:" + $0.id } ?? "",
            Key.volume: 0.7,
            Key.stereoWidth: 0.5,
            Key.keyUp: true,
            Key.output: "",
            Key.tone: 0.0,
            Key.variesByKey: true,
            Key.quietWhileMicOn: true,
        ])
        defaults.removeObject(forKey: "playsRepeats")  // setting removed: held keys never repeat now
        isEnabled = defaults.bool(forKey: Key.enabled)
        soundID = defaults.string(forKey: Key.sound) ?? ""
        volume = defaults.double(forKey: Key.volume)
        stereoWidth = defaults.double(forKey: Key.stereoWidth)
        playsKeyUp = defaults.bool(forKey: Key.keyUp)
        outputChoice = defaults.string(forKey: Key.output) ?? ""
        tone = defaults.double(forKey: Key.tone)
        variesByKey = defaults.bool(forKey: Key.variesByKey)
        quietWhileMicOn = defaults.bool(forKey: Key.quietWhileMicOn)
        quietApps = Self.sorted(defaults.dictionary(forKey: Key.quietApps) as? [String: String] ?? [:])

        do {
            let engine = try SoundEngine()
            engine.onOutputAvailabilityChange = { [weak self] available in
                self?.isAudioStalled = !available
                self?.refreshOutputStatus()
            }
            engine.onOutputChange = { [weak self] in self?.refreshOutputStatus() }
            engine.volume = Float(volume)
            engine.stereoWidth = Float(stereoWidth)
            engine.outputChoice = outputChoice.isEmpty ? nil : outputChoice
            self.engine = engine
        } catch {
            errorMessage = "Clacky couldn't set up its audio: \(error.localizedDescription)"
        }

        refreshOutputOptions()
        AudioDevices.observeChanges { [weak self] in
            self?.refreshOutputOptions()
            self?.engine?.outputsChanged()
        }
        // After sleep or a locked screen, the key tap and the audio output can come back stale:
        // still listed as on, but silent. Start both fresh, the way relaunching Clacky would.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.startFresh()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.startFresh()
        }
        // Coming back from Finder after adding a pack: show it without needing Reload.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadPacksIfFoldersChanged()
        }
        engine?.startWhenPossible()

        reloadPacks()
        monitor.onKey = { [weak self] keyCode, phase in
            self?.handleKey(keyCode, phase: phase)
        }
        startMonitoring()

        frontmostAppID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostAppID = app?.bundleIdentifier
        }
        microphone.onChange = { [weak self] recorder in
            self?.microphoneUser = recorder
            if let recorder {
                log.notice("Paused: \(recorder.bundleID, privacy: .public) is using the microphone")
            } else {
                log.notice("Microphone is free")
            }
        }
        updateMicrophoneWatching()

        hotKey = HotKey(keyCode: Self.shortcut.keyCode, modifiers: Self.shortcut.modifiers) { [weak self] in
            self?.isEnabled.toggle()
        }
        hasShortcut = hotKey != nil
        DispatchQueue.main.async { self.updateDockBadge() }  // the Dock tile isn't ready during launch
    }

    var selectedOption: SoundOption? {
        soundOptions.first { $0.id == soundID }
    }

    /// Whether the selected sound has recordings of keys being let go.
    var hasReleaseSounds: Bool {
        engine?.bank?.hasReleaseSounds ?? false
    }

    // MARK: Keys

    private func handleKey(_ keyCode: Int, phase: KeyPhase) {
        guard isEnabled, phase == .down || playsKeyUp, microphoneUser == nil,
              !quietApps.contains(where: { $0.id == frontmostAppID })
        else { return }
        engine?.play(keyCode: keyCode, phase: phase)
    }

    /// The Dock icon says when Clacky is off, since the shortcut can turn it off from anywhere.
    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = isEnabled ? nil : "Off"
    }

    private func startMonitoring() {
        if monitor.start() {
            hasPermission = true
            log.notice("Listening for keys")
            return
        }
        log.notice("Waiting for Input Monitoring access")
        KeyMonitor.requestPermission()
        // The tap can't be created until the user flips the switch in System Settings, so keep checking.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, self.monitor.start() else { return }
            self.hasPermission = true
            log.notice("Listening for keys")
            timer.invalidate()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    /// A new key tap and a restarted sound engine.
    private func startFresh() {
        log.notice("Starting fresh after sleep")
        if hasPermission {
            monitor.stop()
            if !monitor.start() {
                hasPermission = false
                startMonitoring()
            }
        }
        engine?.restart()
    }

    func openInputMonitoringSettings() {
        KeyMonitor.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: Output

    private func refreshOutputOptions() {
        outputOptions = AudioDevices.outputs().map { OutputOption(id: $0.uid, name: $0.name) }
        // A chosen output that's unplugged stays in the list, so the picker still shows the choice.
        if !outputChoice.isEmpty, !outputOptions.contains(where: { $0.id == outputChoice }) {
            let name = UserDefaults.standard.string(forKey: Key.outputName) ?? "Chosen output"
            outputOptions.append(OutputOption(id: outputChoice, name: "\(name) (not connected)"))
        }
    }

    private func refreshOutputStatus() {
        guard let engine else { return }
        activeOutputName = engine.activeOutput?.name
        let chosenName = UserDefaults.standard.string(forKey: Key.outputName) ?? "The chosen output"
        if let active = engine.activeOutput {
            if !outputChoice.isEmpty, active.uid != outputChoice {
                outputStatus = "\(chosenName) isn't connected, so Clacky is playing through \(active.name)."
            } else if let unplayable = engine.unplayableOutput {
                outputStatus = "\(unplayable.name) can't play sound, so Clacky is playing through \(active.name)."
            } else if isAudioStalled {
                outputStatus = "\(active.name) isn't responding yet. Clacky will start playing as soon as it does."
            } else {
                outputStatus = nil
            }
            log.notice("Playing through \(active.name, privacy: .public)")
        } else {
            let name = engine.unplayableOutput?.name ?? "Your Mac's sound output"
            outputStatus = "\(name) can't play sound right now, and no other output works. Clacky will keep trying."
            log.notice("No output can play")
        }
    }

    // MARK: Staying quiet

    /// Why Clacky is paused right now, if it's because of the microphone.
    var microphoneMessage: String? {
        guard let recorder = microphoneUser else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // Calls in a browser record from a helper process (com.google.Chrome.helper); name the browser.
        let app = apps.first { $0.processIdentifier == recorder.pid }
            ?? apps.first { app in app.bundleIdentifier.map { recorder.bundleID.hasPrefix($0) } ?? false }
        if let name = app?.localizedName {
            return "Paused while \(name) is using the microphone."
        }
        return "Paused while the microphone is on."
    }

    /// Whether this Mac can tell when another app is recording (macOS 14 and later).
    var canWatchMicrophone: Bool { MicrophoneWatcher.isSupported }

    private func updateMicrophoneWatching() {
        if quietWhileMicOn {
            microphone.start()
        } else {
            microphone.stop()
        }
    }

    /// Apps that are open now and could be added to the quiet list.
    var appsToQuiet: [QuietApp] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> QuietApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                  !quietApps.contains(where: { $0.id == id })
            else { return nil }
            return QuietApp(id: id, name: app.localizedName ?? id)
        }
        return Array(Set(apps)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func quiet(_ app: QuietApp) {
        saveQuietApps(quietApps.filter { $0.id != app.id } + [app])
    }

    func unquiet(_ app: QuietApp) {
        saveQuietApps(quietApps.filter { $0.id != app.id })
    }

    /// Picks any app from the Applications folder, open or not.
    func chooseAppToQuiet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Stay Quiet"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        quiet(QuietApp(id: id, name: FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")))
    }

    private func saveQuietApps(_ apps: [QuietApp]) {
        let byID = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        UserDefaults.standard.set(byID, forKey: Key.quietApps)
        quietApps = Self.sorted(byID)
    }

    private static func sorted(_ byID: [String: String]) -> [QuietApp] {
        byID.map { QuietApp(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Sounds

    /// Previews once the user stops changing a setting, rather than on every step of a slider.
    func previewSoon() {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.preview() }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Types a few home-row keys and a space so a newly picked sound can be heard right away.
    func preview() {
        for (index, keyCode) in [0, 1, 2, 3, 49].enumerated() {
            let pressedAt = DispatchTime.now() + Double(index) * 0.12
            DispatchQueue.main.asyncAfter(deadline: pressedAt) { [weak self] in
                self?.engine?.play(keyCode: keyCode, phase: .down)
            }
            DispatchQueue.main.asyncAfter(deadline: pressedAt + 0.07) { [weak self] in
                guard let self, self.playsKeyUp else { return }
                self.engine?.play(keyCode: keyCode, phase: .up)
            }
        }
    }

    func reloadPacks() {
        try? FileManager.default.createDirectory(at: Self.packsFolder, withIntermediateDirectories: true)
        let packFolders = packFolders()

        soundOptions = SwitchProfile.all.map { SoundOption(id: "synth:" + $0.id, name: $0.name, summary: $0.summary) }
            + packFolders.map { folder in
                // A pack can describe itself in description.txt; otherwise say where it came from.
                let described = (try? String(contentsOf: folder.appendingPathComponent("description.txt"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return SoundOption(id: "pack:" + folder.lastPathComponent, name: folder.lastPathComponent,
                                   summary: described.flatMap { $0.isEmpty ? nil : $0 } ?? "Sound pack from your Sound Packs folder.")
            }

        // Recordings may have changed on disk; synthesized banks never do.
        banks = banks.filter { $0.key.hasPrefix("synth:") }
        if soundOptions.contains(where: { $0.id == soundID }) {
            applySelectedSound()
        } else if let first = soundOptions.first {
            soundID = first.id
        } else {
            engine?.bank = nil
            errorMessage = "No sounds yet. Add a folder of recordings via Sound Packs Folder, then Reload Packs."
        }
    }

    /// Reloads only when packs were added, removed or renamed; changed recordings still need Reload.
    private func reloadPacksIfFoldersChanged() {
        let onDisk = Set(packFolders().map { "pack:" + $0.lastPathComponent })
        let listed = Set(soundOptions.map(\.id).filter { $0.hasPrefix("pack:") })
        if onDisk != listed { reloadPacks() }
    }

    /// The app's own packs plus the user's, by name; the user's win.
    private func packFolders() -> [URL] {
        var byName: [String: URL] = [:]
        for parent in [Self.bundledPacksFolder, Self.packsFolder].compactMap({ $0 }) {
            let folders = ((try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for folder in folders { byName[folder.lastPathComponent] = folder }
        }
        return byName.values.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func openPacksFolder() {
        NSWorkspace.shared.open(Self.packsFolder)
    }

    private func applySelectedSound() {
        do {
            let bank = try bank(for: soundID)
            bank.tone = Float(tone)
            bank.variesByKey = variesByKey
            engine?.bank = bank
            objectWillChange.send()  // hasReleaseSounds depends on the bank
            if engine != nil { errorMessage = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bank(for id: String) throws -> SoundBank {
        if let cached = banks[id] { return cached }
        let bank: SoundBank
        if id.hasPrefix("pack:") {
            guard let folder = packFolders().first(where: { "pack:" + $0.lastPathComponent == id }) else {
                throw SoundSelectionError.unavailable
            }
            bank = try SoundBank.loadPack(at: folder)
        } else if let profile = SwitchProfile.named(String(id.dropFirst("synth:".count))) {
            bank = SoundBank.synthesized(profile)
        } else {
            throw SoundSelectionError.unavailable
        }
        banks[id] = bank
        return bank
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}
