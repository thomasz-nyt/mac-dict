import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import MacDictCore
import SwiftUI

final class HotKeyManager {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4D444943 // MDIC

    private let id: UInt32
    private var reference: EventHotKeyRef?

    init(id: UInt32) {
        self.id = id
        Self.installHandlerIfNeeded()
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else { return false }
        Self.handlers[id] = handler
        return true
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        Self.handlers.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            guard let handler = HotKeyManager.handlers[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async(execute: handler)
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }
}

struct SelectedTextReader {
    enum Outcome {
        case text(String)
        case permissionRequired
        case unavailable
    }

    func read() -> Outcome {
        guard AXIsProcessTrustedWithOptions(nil) else {
            return .permissionRequired
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementValue: AnyObject?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedError == .success, let focusedElementValue else {
            return .unavailable
        }

        let focusedElement = focusedElementValue as! AXUIElement
        var selectedTextValue: AnyObject?
        let textError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )
        guard textError == .success,
              let selectedText = selectedTextValue as? String,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        return .text(selectedText)
    }

    @discardableResult
    func requestPermission() -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        enqueue(trimmed, language: language)
    }

    func speak(segments: [(language: String, text: String)]) {
        stop()
        for segment in segments where !segment.text.isEmpty {
            enqueue(segment.text, language: segment.language)
        }
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    private func enqueue(_ text: String, language: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice(language: language)
        let configuredRate = UserDefaults.standard.double(forKey: "speech.rate")
        utterance.rate = configuredRate == 0 ? 0.47 : Float(configuredRate)
        synthesizer.speak(utterance)
    }

    private func preferredVoice(language: String) -> AVSpeechSynthesisVoice? {
        let key = language.hasPrefix("zh") ? "speech.chineseVoice" : "speech.englishVoice"
        if let identifier = UserDefaults.standard.string(forKey: key),
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
            .first
            ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in isSpeaking = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            if !synthesizer.isSpeaking {
                isSpeaking = false
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in isSpeaking = false }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var query = ""
    @Published private(set) var result: LookupResult?
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var isECDICTInstalled = false
    @Published var focusSearchRequest = 0

    let recentQueries: RecentQueriesStore
    let speech: SpeechService

    private let coordinator: LookupCoordinator
    private let ecdict: ECDICTStore
    private var lookupTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var lookupID = UUID()

    private init() {
        let ecdict = ECDICTStore()
        self.ecdict = ecdict
        self.coordinator = LookupCoordinator(ecdict: ecdict)
        self.recentQueries = RecentQueriesStore()
        self.speech = SpeechService()
        refreshECDICTStatus()
    }

    func prepareTypedSearch() {
        query = ""
        suggestions = []
        errorMessage = nil
        focusSearchRequest += 1
    }

    func lookup(_ rawQuery: String) {
        guard let normalized = QueryNormalizer.normalize(rawQuery) else {
            errorMessage = "Enter one English word or a short phrase."
            return
        }
        query = normalized
        suggestions = []
        recentQueries.record(normalized)
        errorMessage = nil
        isLoading = true

        lookupTask?.cancel()
        let requestID = UUID()
        lookupID = requestID
        lookupTask = Task { [weak self] in
            guard let self else { return }
            if let cached = await coordinator.cachedResult(for: normalized), !Task.isCancelled {
                guard requestID == lookupID else { return }
                result = cached
            } else {
                result = nil
            }

            do {
                let finalResult = try await coordinator.lookup(normalized)
                guard !Task.isCancelled, requestID == lookupID else { return }
                result = finalResult
                if finalResult.english == nil {
                    errorMessage = "English definitions are unavailable; showing the local Chinese hint."
                }
            } catch is CancellationError {
                return
            } catch {
                guard requestID == lookupID else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if requestID == lookupID {
                isLoading = false
            }
        }
    }

    func scheduleSuggestions() {
        suggestionTask?.cancel()
        let currentQuery = query
        guard result == nil, currentQuery.count >= 2 else {
            suggestions = []
            return
        }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let values = await coordinator.suggestions(for: currentQuery)
            guard !Task.isCancelled, query == currentQuery else { return }
            suggestions = values
        }
    }

    func chooseSuggestion(_ suggestion: String) {
        query = suggestion
        lookup(suggestion)
    }

    func toggleFavorite() {
        recentQueries.toggleFavorite(result?.english?.word ?? query)
        objectWillChange.send()
    }

    func isFavorite() -> Bool {
        recentQueries.isFavorite(result?.english?.word ?? query)
    }

    func speakWord() {
        guard let result else { return }
        speech.speak(SpeechTextBuilder.headword(from: result), language: "en-US")
    }

    func speakEnglish() {
        guard let result, let text = SpeechTextBuilder.englishDefinition(from: result) else { return }
        speech.speak(text, language: "en-US")
    }

    func speakChinese() {
        guard let result, let text = SpeechTextBuilder.chineseHint(from: result) else { return }
        speech.speak(text, language: "zh-CN")
    }

    func speakFullEntry() {
        guard let result else { return }
        speech.speak(segments: SpeechTextBuilder.fullEntrySegments(from: result))
    }

    func stopSpeechAndCancelLookup() {
        lookupTask?.cancel()
        speech.stop()
    }

    func refreshECDICTStatus() {
        Task { [weak self] in
            guard let self else { return }
            isECDICTInstalled = await ecdict.isInstalled
        }
    }

    func clearEnglishCache() {
        Task { [cache] in
            try? await cache.removeAll()
        }
    }
}
        let cache = DictionaryCache()
            try? await cache.removeAll()
        }
    }
}
}

    func refreshECDICTStatus() {
        Task { [weak self] in
            guard let self else { return }
            isECDICTInstalled = await ecdict.isInstalled
        }
    }

    func clearEnglishCache() {
        Task { [coordinator] in
            _ = coordinator
            let cache = DictionaryCache()
            try? await cache.removeAll()
        }
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: NSPanel

    init(model: AppModel) {
        self.model = model
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.title = "MacDict"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 480, height: 400)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: SearchPanelView(model: model) { [weak self] in
                self?.close()
            }
        )
    }

    func show(focusSearch: Bool) {
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if focusSearch {
            model.focusSearchRequest += 1
        }
    }

    func close() {
        model.stopSpeechAndCancelLookup()
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopSpeechAndCancelLookup()
    }

    private func positionOnActiveScreen() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 56
        )
        panel.setFrameOrigin(origin)
    }
}

struct SearchPanelView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .background(.regularMaterial)
        .onChange(of: model.query) { _, _ in
            model.searchTextDidChange()
        }
        .onChange(of: model.focusSearchRequest) { _, _ in
            searchIsFocused = true
        }
        .onExitCommand(perform: onClose)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Type an English word or short phrase", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchIsFocused)
                .onSubmit { model.lookup(model.query) }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Look Up") {
                model.lookup(model.query)
            }
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            ResultView(model: model, result: result)
        } else if !model.suggestions.isEmpty {
            suggestionList
        } else if let error = model.errorMessage {
            ContentUnavailableView(
                "Lookup unavailable",
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(error)
            )
        } else {
            emptyState
        }
    }

    private var suggestionList: some View {
        List(model.suggestions, id: \.self) { suggestion in
            Button {
                model.chooseSuggestion(suggestion)
            } label: {
                HStack {
                    Text(suggestion)
                    Spacer()
                    Image(systemName: "arrow.turn.down.left")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("English first. Chinese when useful.")
                    .font(.title3.weight(.semibold))
                Text("Control–Option–D looks up selected text.\nControl–Option–Space opens this search box.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if !model.isECDICTInstalled {
                Label("Chinese hints are not installed yet", systemImage: "externaldrive.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct ResultView: View {
    @ObservedObject var model: AppModel
    let result: LookupResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                speechControls
                if let error = model.errorMessage {
                    Label(error, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let english = result.english {
                    englishSection(english)
                }
                if let chinese = result.chinese {
                    chineseSection(chinese)
                } else if !model.isECDICTInstalled {
                    chineseInstallMessage
                }
                sourceFooter
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.english?.word ?? result.query)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .textSelection(.enabled)
                if let phonetic = result.english?.phonetic ?? result.chinese?.phonetic {
                    Text(phonetic)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button {
                model.toggleFavorite()
            } label: {
                Image(systemName: model.isFavorite() ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .help(model.isFavorite() ? "Remove from favorites" : "Add to favorites")
        }
    }

    private var speechControls: some View {
        HStack(spacing: 8) {
            Button("Word", systemImage: "speaker.wave.2") {
                model.speakWord()
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("English", systemImage: "text.bubble") {
                model.speakEnglish()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(result.english?.firstDefinition == nil)

            Button("中文", systemImage: "character.bubble") {
                model.speakChinese()
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(result.chinese == nil)

            Button("Read Entry", systemImage: "play.circle") {
                model.speakFullEntry()
            }
            .keyboardShortcut("4", modifiers: .command)

            if model.speech.isSpeaking {
                Button("Stop", systemImage: "stop.fill") {
                    model.speech.stop()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func englishSection(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("English explanation", systemImage: "text.book.closed")
                .font(.headline)
            ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
                VStack(alignment: .leading, spacing: 10) {
                    Text(meaning.partOfSpeech.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    ForEach(Array(meaning.definitions.enumerated()), id: \.offset) { index, definition in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1). \(definition.text)")
                                .textSelection(.enabled)
                            if let example = definition.example {
                                Text("“\(example)”")
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if !definition.synonyms.isEmpty {
                                Text("Synonyms: \(definition.synonyms.prefix(6).joined(separator: ", "))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chineseSection(_ hint: ChineseHint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Chinese hint · ECDICT", systemImage: "character.book.closed.zh")
                .font(.headline)
            Text(hint.lines.joined(separator: "\n"))
                .font(.title3)
                .textSelection(.enabled)
            Text("A compact supporting gloss; it is not aligned to individual English senses.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var chineseInstallMessage: some View {
        Label(
            "Run Scripts/install-ecdict.py once to enable local Chinese hints.",
            systemImage: "externaldrive.badge.plus"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var sourceFooter: some View {
        if let entry = result.english {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                HStack(spacing: 6) {
                    Text("English data:")
                    if let source = entry.sourceURLs.first {
                        Link("Wiktionary via Free Dictionary API", destination: source)
                    } else {
                        Text("Free Dictionary API")
                    }
                    if let license = entry.license {
                        Text("·")
                        if let url = license.url {
                            Link(license.name, destination: url)
                        } else {
                            Text(license.name)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @AppStorage("speech.englishVoice") private var englishVoice = ""
    @AppStorage("speech.chineseVoice") private var chineseVoice = ""
    @AppStorage("speech.rate") private var speechRate = 0.47

    private var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
    }

    private var chineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-CN" }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
    }

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Selected text", value: "Control–Option–D")
                LabeledContent("Typed search", value: "Control–Option–Space")
            }

            Section("Speech") {
                Picker("English voice", selection: $englishVoice) {
                    Text("System default").tag("")
                    ForEach(englishVoices, id: \.identifier) { voice in
                        Text(voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                Picker("Mandarin voice", selection: $chineseVoice) {
                    Text("System default").tag("")
                    ForEach(chineseVoices, id: \.identifier) { voice in
                        Text(voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                HStack {
                    Text("Rate")
                    Slider(value: $speechRate, in: 0.32...0.60)
                    Text(speechRate.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local data") {
                LabeledContent("ECDICT Chinese hints") {
                    Text(model.isECDICTInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(model.isECDICTInstalled ? Color.green : Color.secondary)
                }
                HStack {
                    Button("Reveal App Data") { revealApplicationSupport() }
                    Button("Refresh ECDICT Status") { model.refreshECDICTStatus() }
                    Button("Clear English Cache") { model.clearEnglishCache() }
                    Button("Clear History", role: .destructive) { model.recentQueries.clearHistory() }
                }
            }

            Section("Privacy") {
                Text("Only submitted, uncached English queries are sent to api.dictionaryapi.dev. Selected surrounding text, history, favorites, and Chinese data stay on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = voice.quality == .enhanced ? " · Enhanced" : ""
        return "\(voice.name)\(quality)"
    }

    private func revealApplicationSupport() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacDict", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private let selectedTextReader = SelectedTextReader()
    private lazy var panelController = PanelController(model: model)
    private let selectedTextHotKey = HotKeyManager(id: 1)
    private let typedSearchHotKey = HotKeyManager(id: 2)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        registerHotKeys()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "character.book.closed",
            accessibilityDescription: "MacDict"
        )

        let menu = NSMenu()
        let selectedItem = NSMenuItem(
            title: "Look Up Selected Text",
            action: #selector(lookUpSelectedText),
            keyEquivalent: ""
        )
        selectedItem.target = self
        menu.addItem(selectedItem)

        let searchItem = NSMenuItem(
            title: "Type a Word…",
            action: #selector(showTypedSearch),
            keyEquivalent: ""
        )
        searchItem.target = self
        menu.addItem(searchItem)
        menu.addItem(.separator())

        let permissionItem = NSMenuItem(
            title: "Grant Accessibility Access…",
            action: #selector(grantAccessibilityAccess),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit MacDict",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func registerHotKeys() {
        let lookupSucceeded = selectedTextHotKey.register(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            self?.lookUpSelectedText()
        }
        let searchSucceeded = typedSearchHotKey.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            self?.showTypedSearch()
        }
        if !lookupSucceeded || !searchSucceeded {
            showTypedSearch()
            model.errorMessage = "A global shortcut is already in use. MacDict remains available from the menu bar."
        }
    }

    @objc private func lookUpSelectedText() {
        switch selectedTextReader.read() {
        case .text(let text):
            panelController.show(focusSearch: false)
            model.lookup(text)
        case .permissionRequired:
            model.prepareTypedSearch()
            panelController.show(focusSearch: true)
            model.errorMessage = "Accessibility permission is required to read selected text. Typed search still works."
        case .unavailable:
            model.prepareTypedSearch()
            panelController.show(focusSearch: true)
            model.errorMessage = "This app did not expose its selected text. Type or paste the word instead."
        }
    }

    @objc private func showTypedSearch() {
        model.prepareTypedSearch()
        panelController.show(focusSearch: true)
    }

    @objc private func grantAccessibilityAccess() {
        if !selectedTextReader.requestPermission() {
            selectedTextReader.openAccessibilitySettings()
        }
    }

    @objc private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@main
struct MacDictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: AppModel.shared)
                .frame(width: 520, height: 430)
        }
    }
}
