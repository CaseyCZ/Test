import SwiftUI
import UIKit
import SafariServices

@main
struct PlayCaptionIOSApp: App {
    @StateObject private var model = CaptionAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear { model.xbox.resumeLoginIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    model.xbox.setApplicationActive(phase == .active)
                }
        }
    }
}

@MainActor
final class CaptionAppModel: ObservableObject {
    @Published var status = "Připraveno"
    @Published var lastEnglish = ""
    @Published var lastCzech = ""
    @Published var frameCount = 0
    @Published var isRunning = false
    @Published var ocrMode: OCRMode = OCRMode(
        rawValue: UserDefaults.standard.string(forKey: "ocrMode") ?? ""
    ) ?? .classic {
        didSet { UserDefaults.standard.set(ocrMode.rawValue, forKey: "ocrMode") }
    }
    @Published var expandOnEmpty = UserDefaults.standard.bool(forKey: "expandOnEmpty") {
        didSet { UserDefaults.standard.set(expandOnEmpty, forKey: "expandOnEmpty") }
    }
    @Published var subtitleDuration: Double =
        (UserDefaults.standard.object(forKey: "subtitleDuration") as? Double) ?? 6 {
        didSet { UserDefaults.standard.set(subtitleDuration, forKey: "subtitleDuration") }
    }
    @Published var skipOldTranslations = UserDefaults.standard.bool(forKey: "skipOldTranslations") {
        didSet { UserDefaults.standard.set(skipOldTranslations, forKey: "skipOldTranslations") }
    }
    @Published var maxTranslationAge: Double =
        (UserDefaults.standard.object(forKey: "maxTranslationAge") as? Double) ?? 5 {
        didSet { UserDefaults.standard.set(maxTranslationAge, forKey: "maxTranslationAge") }
    }
    @Published var subtitleRegion: SubtitleRegion = SubtitleRegion(
        rawValue: UserDefaults.standard.string(forKey: "subtitleRegion") ?? ""
    ) ?? .center {
        didSet { UserDefaults.standard.set(subtitleRegion.rawValue, forKey: "subtitleRegion") }
    }
    @Published var filterMenuText = (UserDefaults.standard.object(forKey: "filterMenuText") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(filterMenuText, forKey: "filterMenuText") }
    }
    // Android-compatible manual OCR rectangle (normalized coordinates with
    // top-left origin). The default matches OblastTitulku.VYCHOZI.
    @Published var manualOCR = UserDefaults.standard.bool(forKey: "manualOCR") {
        didSet { UserDefaults.standard.set(manualOCR, forKey: "manualOCR") }
    }
    @Published var manualOCRLocked = UserDefaults.standard.bool(forKey: "manualOCRLocked") {
        didSet { UserDefaults.standard.set(manualOCRLocked, forKey: "manualOCRLocked") }
    }
    @Published var manualOCRBox: CGRect = {
        let fallback = CGRect(x: 0.10, y: 0.72, width: 0.80, height: 0.25)
        guard let data = UserDefaults.standard.data(forKey: "manualOCRBox"),
              let rect = try? JSONDecoder().decode(CGRect.self, from: data),
              rect.width >= 0.1, rect.height >= 0.04,
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1, rect.maxY <= 1
        else { return fallback }
        return rect
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(manualOCRBox) {
                UserDefaults.standard.set(data, forKey: "manualOCRBox")
            }
        }
    }
    @Published var outputX: Double = (UserDefaults.standard.object(forKey: "outputX") as? Double) ?? 0.5 {
        didSet { UserDefaults.standard.set(outputX, forKey: "outputX") }
    }
    @Published var outputBottom: Double = (UserDefaults.standard.object(forKey: "outputBottom") as? Double) ?? 0.93 {
        didSet { UserDefaults.standard.set(outputBottom, forKey: "outputBottom") }
    }
    @Published var outputWidth: Double = (UserDefaults.standard.object(forKey: "outputWidth") as? Double) ?? 0.62 {
        didSet { UserDefaults.standard.set(outputWidth, forKey: "outputWidth") }
    }
    @Published var outputFont: Double = (UserDefaults.standard.object(forKey: "outputFont") as? Double) ?? 1.0 {
        didSet { UserDefaults.standard.set(outputFont, forKey: "outputFont") }
    }
    @Published var outputLocked = UserDefaults.standard.bool(forKey: "outputLocked") {
        didSet { UserDefaults.standard.set(outputLocked, forKey: "outputLocked") }
    }
    // Independent yellow answer-choice region, equivalent to Android's Volby.
    // Disabled by default: dialogue OCR remains unchanged until user enables it.
    @Published var choicesEnabled = UserDefaults.standard.bool(forKey: "choicesEnabled") {
        didSet {
            UserDefaults.standard.set(choicesEnabled, forKey: "choicesEnabled")
            Task { await pipeline.resetOptions() }
            if !choicesEnabled {
                lastTranslatedChoiceItems = []
                lastChoicesSentAt = nil
                tv.sendChoices([], area: choicesArea, outputArea: choicesOutputArea)
            }
        }
    }
    @Published var choicesTextMode = UserDefaults.standard.bool(forKey: "choicesTextMode") {
        didSet { UserDefaults.standard.set(choicesTextMode, forKey: "choicesTextMode") }
    }
    @Published var choicesLocked = UserDefaults.standard.bool(forKey: "choicesLocked") {
        didSet { UserDefaults.standard.set(choicesLocked, forKey: "choicesLocked") }
    }
    @Published var choicesArea: CGRect = {
        let fallback = CGRect(x: 0.55, y: 0.45, width: 0.40, height: 0.35)
        guard let data = UserDefaults.standard.data(forKey: "choicesArea"),
              let rect = try? JSONDecoder().decode(CGRect.self, from: data),
              rect.width >= 0.1, rect.height >= 0.05,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= 1, rect.maxY <= 1
        else { return fallback }
        return rect
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(choicesArea) {
                UserDefaults.standard.set(data, forKey: "choicesArea")
            }
        }
    }
    /// Output rectangle for text recognized in the yellow region.
    /// This is independent of the green ordinary-dialogue output.
    @Published var choicesOutputArea: CGRect = {
        let fallback = CGRect(x: 0.07, y: 0.43, width: 0.43, height: 0.17)
        guard let data = UserDefaults.standard.data(forKey: "choicesOutputArea"),
              let rect = try? JSONDecoder().decode(CGRect.self, from: data),
              rect.width >= 0.10, rect.height >= 0.05,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= 1, rect.maxY <= 1
        else { return fallback }
        return rect
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(choicesOutputArea) {
                UserDefaults.standard.set(data, forKey: "choicesOutputArea")
            }
        }
    }
    /// Independent font scale for Czech translations of the yellow game-text area.
    /// Normal dialogue subtitles continue using outputFont.
    @Published var choicesOutputFont: Double = {
        let saved = UserDefaults.standard.object(forKey: "choicesOutputFont") as? Double ?? 1.0
        return saved.isFinite && (0.6...2.0).contains(saved) ? saved : 1.0
    }() {
        didSet { UserDefaults.standard.set(choicesOutputFont, forKey: "choicesOutputFont") }
    }
    @Published var choicesOutputLocked = UserDefaults.standard.bool(forKey: "choicesOutputLocked") {
        didSet { UserDefaults.standard.set(choicesOutputLocked, forKey: "choicesOutputLocked") }
    }

    @Published var lastChoices = ""
    @Published var logLines: [String] = []
    @Published var gameProfiles: [GameSubtitleProfile] = {
        guard let data = UserDefaults.standard.data(forKey: "gameProfiles"),
              let saved = try? JSONDecoder().decode([GameSubtitleProfile].self, from: data)
        else { return [] }
        return saved
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(gameProfiles) {
                UserDefaults.standard.set(data, forKey: "gameProfiles")
            }
        }
    }

    let tv = PlayCaptionTV()
    let xbox = XboxAuthorization()
    private let pipeline = CaptionPipeline()
    private var remotePlay: XboxRemotePlay?
    private var processingChoices = false
    private var processingOCR = false
    private var sessionRevision = 0
    // Cache only the translation already visible on TV. Moving the orange
    // rectangle must not trigger a fresh OCR/translation or show demo text.
    private var lastTranslatedChoiceItems: [String] = []
    private var lastTranslatedChoiceIsText = false
    private var lastChoicesSentAt: Date?

    init() {
        tv.onPairingData = { [weak self] fields in
            guard let self else { return }
            if self.xbox.importPairedXbox(fields) {
                self.write("Xbox přihlášení převzato z PlayCaption TV.")
            } else {
                self.write("Televize spárována; Microsoft účet přihlas zvlášť.")
            }
        }
    }

    func saveGameProfile(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let existingIndex = gameProfiles.firstIndex {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let profile = GameSubtitleProfile(
            id: existingIndex.map { gameProfiles[$0].id } ?? UUID(),
            name: name,
            region: subtitleRegion.rawValue,
            manualOCR: manualOCR,
            manualOCRLocked: manualOCRLocked,
            manualOCRBox: manualOCRBox,
            filterMenuText: filterMenuText,
            ocrMode: ocrMode.rawValue,
            expandOnEmpty: expandOnEmpty,
            outputX: outputX,
            outputBottom: outputBottom,
            outputWidth: outputWidth,
            outputFont: outputFont,
            outputLocked: outputLocked,
            choicesEnabled: choicesEnabled,
            choicesTextMode: choicesTextMode,
            choicesArea: choicesArea,
            choicesLocked: choicesLocked,
            choicesOutputArea: choicesOutputArea,
            choicesOutputLocked: choicesOutputLocked,
            choicesOutputFont: choicesOutputFont,
            subtitleDuration: subtitleDuration,
            skipOldTranslations: skipOldTranslations,
            maxTranslationAge: maxTranslationAge
        )
        if let existingIndex {
            gameProfiles[existingIndex] = profile
        } else {
            gameProfiles.append(profile)
        }
        write("Profil uložen: \(name)")
    }

    func applyGameProfile(_ profile: GameSubtitleProfile) {
        guard !isRunning else { return }
        subtitleRegion = SubtitleRegion(rawValue: profile.region) ?? .center
        manualOCR = profile.manualOCR
        manualOCRLocked = profile.manualOCRLocked
        manualOCRBox = profile.manualOCRBox
        filterMenuText = profile.filterMenuText
        ocrMode = OCRMode(rawValue: profile.ocrMode) ?? .classic
        expandOnEmpty = profile.expandOnEmpty
        outputX = profile.outputX
        outputBottom = profile.outputBottom
        outputWidth = profile.outputWidth
        outputFont = profile.outputFont
        outputLocked = profile.outputLocked
        choicesArea = profile.choicesArea
        choicesTextMode = profile.choicesTextMode
        choicesLocked = profile.choicesLocked
        choicesEnabled = profile.choicesEnabled
        if let rect = profile.choicesOutputArea { choicesOutputArea = rect }
        if let locked = profile.choicesOutputLocked { choicesOutputLocked = locked }
        choicesOutputFont = profile.choicesOutputFont ?? 1.0
        subtitleDuration = profile.subtitleDuration
        skipOldTranslations = profile.skipOldTranslations
        maxTranslationAge = profile.maxTranslationAge
        write("Načten profil: \(profile.name)")
    }

    func write(_ message: String) {
        logLines.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if logLines.count > 250 { logLines.removeFirst(logLines.count - 250) }
    }

    func start(_ console: XboxConsole) {
        guard !isRunning else { return }
        isRunning = true
        sessionRevision += 1
        let currentSession = sessionRevision
        processingOCR = false
        lastTranslatedChoiceItems = []
        lastChoicesSentAt = nil
        Task { await pipeline.resetDialogue() }
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Navazuji Xbox Remote Play…"
        write("Start Remote Play: \(console.name)")
        let play = XboxRemotePlay(authorization: xbox,
                                  minimumFrameInterval: ocrMode.minimumFrameInterval)
        remotePlay = play
        play.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self, self.sessionRevision == currentSession else { return }
                self.status = status
                self.write(status)
            }
        }
        play.onFrame = { [weak self] buffer in
            Task { @MainActor in
                guard let self, self.isRunning,
                      self.sessionRevision == currentSession else { return }
                self.frameCount += 1

                // Choices use an independent region and may be translated while
                // standard captions continue; don't block dialogue reading.
                if self.choicesEnabled && !self.processingChoices {
                    self.processingChoices = true
                    let area = self.choicesArea
                    let asText = self.choicesTextMode
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.processingChoices = false }
                        guard let englishChoices = await self.pipeline.recognizeOptions(
                            buffer, area: area, asText: asText
                        ) else { return }
                        var translated = [String]()
                        for option in englishChoices {
                            let item = await self.pipeline.translate(option)
                            guard self.isRunning, self.choicesEnabled else { return }
                            translated.append(item)
                        }
                        guard self.isRunning, self.choicesEnabled,
                              self.choicesArea == area,
                              self.choicesTextMode == asText else { return }
                        self.lastChoices = translated.joined(separator: " · ")
                        self.lastTranslatedChoiceItems = translated
                        self.lastTranslatedChoiceIsText = asText
                        self.lastChoicesSentAt = Date()
                        self.tv.sendChoices(translated, area: area, asText: asText,
                                            outputArea: self.choicesOutputArea,
                                            outputFont: self.choicesOutputFont)
                        self.write("Volby: \(translated.count) rozpoznaných položek")
                    }
                }

                // Keep recognition independent of network translation: a slow
                // request must not block OCR of the next short street dialogue.
                if !self.processingOCR {
                    self.processingOCR = true
                    let reading = await self.pipeline.recognize(
                        buffer, region: self.subtitleRegion,
                        manualArea: self.manualOCR ? self.manualOCRBox : nil,
                        filterMenus: self.filterMenuText,
                        mode: self.ocrMode,
                        expandOnEmpty: self.expandOnEmpty
                    )
                    self.processingOCR = false
                    if let reading, self.isRunning,
                       self.sessionRevision == currentSession {
                        self.lastEnglish = reading.english
                        self.write("OCR: \(reading.english)")
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let czech = await self.pipeline.translate(reading.english)
                            let isLatest = await self.pipeline.isCurrent(revision: reading.revision)
                            guard self.isRunning,
                                  self.sessionRevision == currentSession,
                                  isLatest else { return }
                            if self.skipOldTranslations &&
                               Date().timeIntervalSince(reading.capturedAt) > self.maxTranslationAge {
                                self.write("Příliš starý překlad byl přeskočen.")
                                return
                            }
                            self.lastCzech = czech
                            self.tv.sendSubtitle(czech,
                                                 duration: Int(self.subtitleDuration * 1000))
                            self.write("CZ: \(czech)")
                        }
                    }
                }
            }
        }
        Task {
            do { try await play.connect(console: console) }
            catch {
                self.status = "Remote Play: \(error.localizedDescription)"
                write("CHYBA Remote Play: \(error.localizedDescription)")
                stop()
            }
        }
    }

    /// Move the already-translated game text without altering the current OCR
    /// input, starting another translation or placing a sample over the game.
    @discardableResult
    func relocateActiveChoices() -> Bool {
        guard isRunning, choicesEnabled,
              !lastTranslatedChoiceItems.isEmpty,
              let sentAt = lastChoicesSentAt,
              Date().timeIntervalSince(sentAt) <= (lastTranslatedChoiceIsText ? 300 : 45)
        else { return false }
        tv.sendChoices(lastTranslatedChoiceItems, area: choicesArea,
                       asText: lastTranslatedChoiceIsText,
                       outputArea: choicesOutputArea,
                       outputFont: choicesOutputFont)
        return true
    }

    func stop() {
        sessionRevision += 1
        processingOCR = false
        remotePlay?.stop()
        remotePlay = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        tv.sendSubtitle("", duration: 0)
        tv.sendChoices([], area: choicesArea, outputArea: choicesOutputArea)
        lastTranslatedChoiceItems = []
        lastChoicesSentAt = nil
        lastChoices = ""
        status = "Zastaveno"
    }

    func shareLogs() -> String {
        (["PlayCaption iOS 0.2.0", "Stav: \(status)"] + logLines).joined(separator: "\n")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: CaptionAppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    PlayCaptionSection(title: "1 · Televize", symbol: "tv",
                                       subtitle: "Zde se zobrazují české titulky.") {
                        TVSelectionView(tv: model.tv)
                    }
                    PlayCaptionSection(title: "2 · Microsoft / Xbox", symbol: "gamecontroller.fill",
                                       subtitle: "Účet pro vzdálené hraní.") {
                        XboxAccountView(auth: model.xbox)
                    }
                    PlayCaptionSection(title: "3 · Vzdálené hraní", symbol: "dot.radiowaves.left.and.right",
                                       subtitle: "Vyber Xbox a spusť překlad.") {
                        XboxRemotePlayView(auth: model.xbox)
                    }

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("PlayCaption iOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Nastavení")
                }
            }
            .sheet(isPresented: $showSettings) {
                PlayCaptionSettingsView(model: model)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 12)
            Text("PlayCaption")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Xbox → české titulky → Google TV")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct PlayCaptionSection<Content: View>: View {
    let title: String
    let symbol: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 43, height: 43)
                    .background(Color.blue.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.065),
                    in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// Observe XboxAuthorization directly: the parent model does not forward its
/// objectWillChange notifications, so console discovery otherwise updates
/// the account card but leaves this section stuck at "Žádná konzole".
struct XboxRemotePlayView: View {
    @EnvironmentObject var model: CaptionAppModel
    @ObservedObject var auth: XboxAuthorization
    @AppStorage("selectedXboxServerID") private var selectedXboxServerID = ""

    // Never silently choose a console; people may own several Xboxes.
    // The same server ID remains selected after reloading the account.
    private var selectedConsole: XboxConsole? {
        auth.consoles.first(where: { $0.id == selectedXboxServerID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dostupné Xboxy: \(auth.consoles.count)")
                    .font(.subheadline)
                Spacer()
                Button {
                    Task { await auth.refreshConsoles() }
                } label: {
                    Label("Obnovit", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
                .disabled(!auth.signedIn || model.isRunning)
            }

            Menu {
                if auth.consoles.isEmpty {
                    Text("Zatím žádný Xbox")
                }
                ForEach(auth.consoles) { console in
                    Button {
                        selectedXboxServerID = console.id
                    } label: {
                        if selectedXboxServerID == console.id {
                            Label("\(console.name) · \(console.powerState)", systemImage: "checkmark")
                        } else {
                            Text("\(console.name) · \(console.powerState)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedConsole?.name ?? "Vyber Xbox")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(selectedConsole?.powerState ?? "Zvol konzoli pro překlad")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.white.opacity(0.075),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
            }
            .disabled(auth.consoles.isEmpty || model.isRunning)

            if auth.consoles.isEmpty {
                Text("Nenašla se žádná konzole. Klepni na Obnovit.")
                    .font(.caption).foregroundStyle(.orange)
            } else if auth.consoles.count == 1 {
                Text("Xbox služba vrátila jen jednu konzoli. Pokud používáš více Xboxů, klepni na Obnovit a ověř, že jsou pod tímto účtem povolené vzdálené funkce.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let selectedConsole {
                Text("Vybráno: \(selectedConsole.name) · \(selectedConsole.powerState)")
                    .font(.caption).foregroundStyle(.green)
            }

            Text(model.status).foregroundStyle(.secondary)
            HStack {
                Button("Spustit překlad") {
                    guard let console = selectedConsole else { return }
                    model.start(console)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedConsole == nil || model.isRunning)
                Button("Zastavit") { model.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning)
            }
            Text("Snímky: \(model.frameCount)\nEN: \(model.lastEnglish)\nCZ: \(model.lastCzech)")
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Během překladu nech iPhone odemčený a aplikaci otevřenou. iOS může spojení na pozadí pozastavit.")
                .font(.caption).foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if auth.signedIn && auth.consoles.isEmpty {
                await auth.refreshConsoles()
            }
        }
    }
}

struct TVSelectionView: View {
    @ObservedObject var tv: PlayCaptionTV
    @State private var test = "Ahoj! PlayCaption z iPhonu funguje."
    @State private var showDevices = false
    @State private var editIP = false
    @State private var editTest = false

    private var chosenIP: String {
        tv.ip.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var chosenDevice: PlayCaptionDevice? {
        tv.discovered.first(where: { $0.ip == chosenIP })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if chosenIP.isEmpty {
                Label("Zatím není vybraná televize", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 14))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "tv.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 46, height: 46)
                        .background(Color.blue.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chosenDevice?.name ?? "Vybraná televize")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(chosenIP)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Vybraná televize")
                }
                .padding(13)
                .background(Color.blue.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(Color.blue.opacity(0.7), lineWidth: 1.5))
            }

            HStack(spacing: 8) {
                Button {
                    showDevices = true
                    tv.discover()
                } label: {
                    Label("Vyhledat televize", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showDevices = true
                    editIP = true
                    tv.discover()
                } label: {
                    Label("Změnit", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }

            if showDevices {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Televize v síti")
                        .font(.subheadline.bold())
                    if tv.discovered.isEmpty {
                        Text("Zatím žádná nalezená televize. Můžeš zadat IP ručně.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tv.discovered) { device in
                        Button {
                            tv.ip = device.ip
                            showDevices = false
                            editIP = false
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.subheadline.bold())
                                    Text(device.ip)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chosenIP == device.ip {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    Button(editIP ? "Skrýt ruční zadání" : "Zadat IP televize ručně") {
                        editIP.toggle()
                    }
                    .font(.subheadline)
                    if editIP {
                        TextField("IP televize (např. 192.168.1.20)", text: $tv.ip)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit { showDevices = false; editIP = false }
                        Button("Hotovo") {
                            showDevices = false
                            editIP = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 13))
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("Párování iPhonu s televizí", systemImage: "link")
                    .font(.subheadline.bold())
                if tv.receiverPaired {
                    Label(tv.receiverConnected
                          ? "Spárováno · připojeno k TV"
                          : "Spárováno · spojení zatím nepotvrzeno",
                          systemImage: tv.receiverConnected
                          ? "checkmark.circle.fill" : "clock")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tv.receiverConnected ? .green : .orange)
                    Button("Zrušit uložené párování") {
                        tv.forgetReceiver()
                    }
                    .font(.caption)
                    .tint(.secondary)
                }
                // Re-pairing must remain available even if an old token survives
                // reinstalling the independent TV APK in the iPhone Keychain.
                // A new six-digit PIN safely replaces only this TV's saved token.
                Text(tv.receiverPaired && !tv.receiverConnected
                     ? "Po přeinstalaci TV aplikace klepni na TV na „Spárovat iPhone“ a zadej nový šestimístný kód. Staré spárování se přepíše."
                     : "Na TV zvol „Spárovat iPhone“ a zadej aktuální šestimístný kód. Nejde o přihlášení k Xboxu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("6místný kód z TV", text: $tv.receiverCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: tv.receiverCode) { _, newValue in
                            tv.receiverCode = String(newValue.filter { $0.isNumber }.prefix(6))
                        }
                    Button(tv.receiverPaired ? "Spárovat znovu" : "Spárovat") {
                        tv.pairReceiver()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(chosenIP.isEmpty || tv.receiverCode.count != 6)
                }
                Text(tv.receiverStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .background(Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 13))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tv.receiverConnected
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tv.receiverConnected ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tv.receiverConnected
                         ? "Televize potvrdila spojení"
                         : "Příjem titulků na TV zatím nepotvrzen")
                        .font(.subheadline.bold())
                    Text("Na TV použij režim „S mobilem“ a potom testovací titulek.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                tv.sendSubtitle(test, duration: 8_000, preview: true)
            } label: {
                Label("Odeslat zkušební titulek", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(chosenIP.isEmpty)

            DisclosureGroup("Upravit text zkušebního titulku", isExpanded: $editTest) {
                TextField("Zkušební titulek", text: $test)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
            }
            .font(.caption)
            .tint(.secondary)

            Text(tv.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MicrosoftSignInSafari: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct XboxAccountView: View {
    @ObservedObject var auth: XboxAuthorization
    @State private var showMicrosoftBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !auth.signedIn {
                if auth.currentCode == nil {
                    Button("Přihlásit Microsoft účet") {
                        Task { await auth.beginLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                if let code = auth.currentCode {
                    Text("Na stránce Microsoftu zadej tento kód:")
                    Text(code.userCode)
                        .font(.title.monospaced().bold())
                        .textSelection(.enabled)
                    HStack {
                        Button("Kopírovat kód") {
                            UIPasteboard.general.string = code.userCode
                        }
                        .buttonStyle(.bordered)
                        Button("Otevřít Microsoft") {
                            showMicrosoftBrowser = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    Text("Po přihlášení zavři prohlížeč tlačítkem Hotovo. Aplikace bude pokračovat se stejným kódem.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Znovu ověřit přihlášení") {
                        auth.resumeLoginIfNeeded()
                    }
                    .font(.caption)
                }
            } else {
                Label("Účet přihlášen", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.green.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 10) {
                    Button {
                        Task { await auth.refreshConsoles() }
                    } label: {
                        Label("Načíst moje konzole", systemImage: "gamecontroller")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button {
                        auth.signOut()
                    } label: {
                        Label("Odhlásit", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            Text(auth.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showMicrosoftBrowser, onDismiss: {
            auth.resumeLoginIfNeeded()
        }) {
            if let code = auth.currentCode, let url = URL(string: code.verificationURL),
               url.scheme?.lowercased() == "https" {
                MicrosoftSignInSafari(url: url)
            }
        }
    }
}
