import SwiftUI
import UIKit

@main
struct PlayCaptionIOSApp: App {
    @StateObject private var model = CaptionAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
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
    @State private var selection: XboxConsole?

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
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Konzole", selection: $selection) {
                                Text("Vyber Xbox").tag(Optional<XboxConsole>.none)
                                ForEach(model.xbox.consoles) { c in
                                    Text("\(c.name) · \(c.powerState)").tag(Optional(c))
                                }
                            }
                            .tint(.white)
                            Text(model.status).foregroundStyle(.secondary)
                            HStack {
                                Button("Spustit překlad") {
                                    if let console = selection { model.start(console) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .disabled(selection == nil || model.isRunning)
                                Button("Zastavit") { model.stop() }
                                    .buttonStyle(.bordered)
                                    .disabled(!model.isRunning)
                            }
                            Text("Snímky: \(model.frameCount)\nEN: \(model.lastEnglish)\nCZ: \(model.lastCzech)")
                                .font(.footnote.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Během překladu nech iPhone odemčený a aplikaci otevřenou. iOS může spojení na pozadí pozastavit.")
                                .font(.caption).foregroundStyle(.orange)
                        }.frame(maxWidth: .infinity, alignment: .leading)
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
            TextField("Zkušební titulek", text: $test)
            Button("Odeslat zkušební titulek") {
                tv.sendSubtitle(test, duration: 8_000)
            }.buttonStyle(.borderedProminent).tint(.red)
            Text(tv.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct XboxAccountView: View {
    @ObservedObject var auth: XboxAuthorization
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !auth.signedIn {
                Button("Přihlásit Microsoft účet") {
                    Task { await auth.beginLogin() }
                }.buttonStyle(.borderedProminent).tint(.red)
                if let code = auth.currentCode {
                    Text("Otevři microsoft.com/link a zadej:")
                    Text(code.userCode)
                        .font(.title.monospaced().bold())
                        .textSelection(.enabled)
                    Link("Otevřít Microsoft", destination: URL(string: code.verificationURL)!)
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
    }
}
