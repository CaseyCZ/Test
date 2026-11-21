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
    @Published var logLines: [String] = []

    let tv = PlayCaptionTV()
    let xbox = XboxAuthorization()
    private let pipeline = CaptionPipeline()
    private var remotePlay: XboxRemotePlay?

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

    func write(_ message: String) {
        logLines.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if logLines.count > 250 { logLines.removeFirst(logLines.count - 250) }
    }

    func start(_ console: XboxConsole) {
        guard !isRunning else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Navazuji Xbox Remote Play…"
        write("Start Remote Play: \(console.name)")
        let play = XboxRemotePlay(authorization: xbox)
        remotePlay = play
        play.onStatus = { [weak self] s in
            Task { @MainActor in self?.status = s; self?.write(s) }
        }
        play.onFrame = { [weak self] buffer in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.frameCount += 1
                if let english = await self.pipeline.recognize(buffer) {
                    self.lastEnglish = english
                    self.write("OCR: \(english)")
                    let czech = await self.pipeline.translate(english)
                    guard self.isRunning else { return }
                    self.lastCzech = czech
                    self.tv.sendSubtitle(czech, duration: 6_000)
                    self.write("CZ: \(czech)")
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

    func stop() {
        remotePlay?.stop()
        remotePlay = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        tv.sendSubtitle("", duration: 0)
        status = "Zastaveno"
    }

    func shareLogs() -> String {
        (["PlayCaption iOS 0.1.0", "Stav: \(status)"] + logLines).joined(separator: "\n")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: CaptionAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 17) {
                    header
                    GroupBox("1 · Televize PlayCaption") {
                        TVSelectionView(tv: model.tv)
                    }
                    GroupBox("2 · Microsoft / Xbox") {
                        XboxAccountView(auth: model.xbox)
                    }
                    GroupBox("3 · Vzdálené hraní") {
                        XboxRemotePlayView(auth: model.xbox)
                    }
                    GroupBox("Diagnostika") {
                        VStack(alignment: .leading) {
                            ScrollView {
                                Text(model.logLines.suffix(40).joined(separator: "\n"))
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 160)
                            ShareLink(item: model.shareLogs()) {
                                Label("Sdílet anonymizovaný log", systemImage: "square.and.arrow.up")
                            }
                            Text("Log nezahrnuje přihlašovací tokeny ani kódy.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding()
            }
            .navigationTitle("PlayCaption iOS")
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 37)).foregroundStyle(.red)
            Text("PlayCaption").font(.largeTitle.bold())
            Text("Xbox → české titulky → Google TV")
                .font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 9)
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
                HStack {
                    Label(selectedConsole?.name ?? "Vyber Xbox", systemImage: "gamecontroller.fill")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.gray.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                TextField("IP televize (např. 192.168.1.20)", text: $tv.ip)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Button("Najít") { tv.discover() }.buttonStyle(.bordered)
            }
            if !tv.discovered.isEmpty {
                ForEach(tv.discovered) { device in
                    Button { tv.ip = device.ip } label: {
                        Label("\(device.name) · \(device.ip)", systemImage: "tv")
                    }
                }
            }
            Divider()
            Text("Volitelné párování / převzetí Xbox účtu z TV")
                .font(.subheadline.bold())
            Button("1 · Vyžádat párovací kód na TV") { tv.requestPairing() }
                .buttonStyle(.bordered)
            HStack {
                TextField("Čtyřmístný kód z televize", text: $tv.pairingCode)
                    .keyboardType(.numberPad)
                Button("2 · Spárovat") { tv.confirmPairing() }
                    .buttonStyle(.borderedProminent)
            }
            Text(tv.pairingStatus)
                .font(.caption)
                .foregroundStyle(tv.isPaired ? .green : .secondary)
            Divider()
            TextField("Zkušební titulek", text: $test)
            Button("Odeslat zkušební titulek") {
                tv.sendSubtitle(test, duration: 8_000, preview: true)
            }.buttonStyle(.borderedProminent).tint(.red)
            Text("Zkušební titulek se zobrazí i v menu Google TV (režim úpravy polohy).")
                .font(.caption).foregroundStyle(.secondary)
            Text(tv.message).font(.caption).foregroundStyle(.secondary)
        }
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
        VStack(alignment: .leading, spacing: 10) {
            if !auth.signedIn {
                if auth.currentCode == nil {
                    Button("Přihlásit Microsoft účet") {
                        Task { await auth.beginLogin() }
                    }.buttonStyle(.borderedProminent).tint(.red)
                }
                if let code = auth.currentCode {
                    Text("Na stránce Microsoftu zadej tento kód:")
                    Text(code.userCode)
                        .font(.title.monospaced().bold())
                        .textSelection(.enabled)
                    HStack {
                        Button("Kopírovat kód") {
                            UIPasteboard.general.string = code.userCode
                        }.buttonStyle(.bordered)
                        Button("Otevřít Microsoft") {
                            showMicrosoftBrowser = true
                        }.buttonStyle(.borderedProminent).tint(.red)
                    }
                    Text("Po přihlášení zavři prohlížeč tlačítkem Hotovo. Aplikace bude pokračovat se stejným kódem.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Znovu ověřit přihlášení") { auth.resumeLoginIfNeeded() }
                        .font(.caption)
                }
            } else {
                Text("Účet přihlášen").foregroundStyle(.green)
                HStack {
                    Button("Načíst moje konzole") { Task { await auth.refreshConsoles() } }
                    Button("Odhlásit") { auth.signOut() }.foregroundStyle(.red)
                }
            }
            Text(auth.status).font(.caption).foregroundStyle(.secondary)
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
