import SwiftUI

/// All advanced controls live here. The home screen intentionally stays simple.
struct PlayCaptionSettingsView: View {
    @ObservedObject var model: CaptionAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRegions = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showRegions = true
                    } label: {
                        SettingsRow(symbol: "rectangle.dashed", tint: .blue,
                                    title: "Oblasti obrazovky",
                                    detail: "Čtení dialogů, poloha titulků a herní volby")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        PlayCaptionOCRSettingsView(model: model)
                    } label: {
                        SettingsRow(symbol: "text.viewfinder", tint: .cyan,
                                    title: "Rozpoznávání OCR",
                                    detail: "Rychlost, krátké dialogy a filtrování")
                    }

                    NavigationLink {
                        PlayCaptionTranslationSettingsView(model: model)
                    } label: {
                        SettingsRow(symbol: "character.bubble", tint: .mint,
                                    title: "Překlad",
                                    detail: "Doba zobrazení a ochrana proti zpoždění")
                    }
                } header: {
                    Text("Titulky a překlad")
                }

                Section {
                    NavigationLink {
                        PlayCaptionAppearanceSettingsView(model: model)
                    } label: {
                        SettingsRow(symbol: "captions.bubble", tint: .green,
                                    title: "Vzhled titulků",
                                    detail: "Velikost, šířka, umístění a náhled")
                    }

                    NavigationLink {
                        PlayCaptionProfilesView(model: model)
                    } label: {
                        SettingsRow(symbol: "gamecontroller", tint: .orange,
                                    title: "Profily her",
                                    detail: "Uložení a obnovení nastavení pro každou hru")
                    }
                } header: {
                    Text("Přizpůsobení")
                }

                Section {
                    NavigationLink {
                        PlayCaptionDiagnosticsView(model: model)
                    } label: {
                        SettingsRow(symbol: "waveform.path.ecg", tint: .purple,
                                    title: "Diagnostika",
                                    detail: "Stav přenosu, testovací titulek a log")
                    }
                } footer: {
                    Text("PlayCaption iOS 0.2.0 · Testovací verze. Připojení k Xboxu i původní TV aplikace zůstávají beze změn.")
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hotovo") { dismiss() }
                }
            }
            .sheet(isPresented: $showRegions) {
                SubtitleSettingsView(model: model)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct PlayCaptionOCRSettingsView: View {
    @ObservedObject var model: CaptionAppModel

    var body: some View {
        Form {
            Section {
                Picker("Režim", selection: $model.ocrMode) {
                    ForEach(OCRMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(model.isRunning)

                Text(model.ocrMode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Rychlost čtení")
            } footer: {
                Text("Změnu režimu proveď před spuštěním překladu. Původní režim zachovává ověřenou rychlost čtení.")
            }

            Section("Rozpoznávání textu") {
                Toggle("Filtrovat herní menu", isOn: $model.filterMenuText)
                Toggle("Rozšířit oblast při nenalezení textu",
                       isOn: $model.expandOnEmpty)
                    .disabled(model.ocrMode == .classic || model.manualOCR)
                Text("Rozšířené hledání je experimentální: může zachytit i text mapy nebo HUD. Při ruční oblasti se neuplatňuje.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Aktuální oblast")
                    Spacer()
                    Text(model.manualOCR ? "Ručně vybraná" : model.subtitleRegion.title)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            Section {
                Button("Vrátit původní nastavení OCR") {
                    model.ocrMode = .classic
                    model.expandOnEmpty = false
                    model.filterMenuText = true
                }
                .disabled(model.isRunning)
            }
        }
        .navigationTitle("Rozpoznávání OCR")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlayCaptionTranslationSettingsView: View {
    @ObservedObject var model: CaptionAppModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Doba zobrazení")
                    Spacer()
                    Text("\(Int(model.subtitleDuration)) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.subtitleDuration, in: 3...10, step: 1)
                Text("Ovlivňuje délku odeslaného českého titulku na TV; nepřerušuje samotné rozpoznávání.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Zobrazení na TV")
            }

            Section {
                Toggle("Ignorovat zastaralé překlady", isOn: $model.skipOldTranslations)
                Text("Pokud se mezitím objeví jiná věta, starší překlad se nepřepíše přes aktuální. Volitelně lze vynechat i překlad, jehož načtení trvalo příliš dlouho.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.skipOldTranslations {
                    HStack {
                        Text("Maximální stáří")
                        Spacer()
                        Text("\(Int(model.maxTranslationAge)) s")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.maxTranslationAge, in: 2...8, step: 1)
                }
            } header: {
                Text("Zpoždění")
            }

            Section {
                Label("Překlad EN → CZ zatím používá stejnou online službu jako funkční verze.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Kontextové překlady a slovník jmen jsou další možná etapa, nikoliv funkce této verze.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Překlad")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlayCaptionAppearanceSettingsView: View {
    @ObservedObject var model: CaptionAppModel

    var body: some View {
        Form {
            Section("České titulky na televizi") {
                Toggle("Zamknout polohu", isOn: $model.outputLocked)
                HStack {
                    Text("Velikost písma")
                    Spacer()
                    Text("\(Int(model.outputFont * 100)) %")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.outputFont, in: 0.70...1.80)
                    .disabled(model.outputLocked)

                HStack {
                    Text("Šířka textového bloku")
                    Spacer()
                    Text("\(Int(model.outputWidth * 100)) %")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.outputWidth, in: 0.30...0.95)
                    .disabled(model.outputLocked)

                Button {
                    model.tv.sendSubtitle("Ukázka českých titulků", duration: 6_000, preview: true)
                } label: {
                    Label("Zobrazit náhled na televizi", systemImage: "tv")
                }
                .disabled(model.tv.ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                Text("Přesnou polohu zeleného rámečku nastavíš v „Oblasti obrazovky“.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Volba barev, obrysů nebo vlastního pozadí textu zatím v původní aplikaci pro TV podporovaná není. Tyto nefunkční ovladače sem nepřidáváme.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Vzhled titulků")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlayCaptionProfilesView: View {
    @ObservedObject var model: CaptionAppModel
    @State private var profileName = ""

    var body: some View {
        Form {
            Section {
                TextField("Název hry (např. GTA V)", text: $profileName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button {
                    model.saveGameProfile(named: profileName)
                    profileName = ""
                } label: {
                    Label("Uložit aktuální nastavení", systemImage: "square.and.arrow.down")
                }
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Nový profil / aktualizace")
            } footer: {
                Text("Stejný název aktualizuje existující profil. Ukládá OCR, rámečky, dobu zobrazení a filtry. Přihlašovací údaje se neukládají.")
            }

            Section {
                if model.gameProfiles.isEmpty {
                    Text("Žádné uložené profily.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.gameProfiles) { profile in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            Text(profile.ocrMode == OCRMode.classic.rawValue
                                 ? "Původní OCR" : "Vlastní nastavení OCR")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Použít") {
                            model.applyGameProfile(profile)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .disabled(model.isRunning)
                    }
                }
                .onDelete { indices in
                    model.gameProfiles.remove(atOffsets: indices)
                }
            } header: {
                Text("Uložené hry")
            } footer: {
                Text("Profil vyber před spuštěním hry. Smazání profilu nezmění právě používané nastavení. Pro smazání přejeď po řádku doleva.")
            }

            if model.isRunning {
                Section {
                    Label("Během běžícího překladu nelze měnit profil. Nejdřív zastav překlad.",
                          systemImage: "info.circle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Profily her")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlayCaptionDiagnosticsView: View {
    @ObservedObject var model: CaptionAppModel

    var body: some View {
        Form {
            Section("Stav") {
                LabeledContent("Xbox", value: model.isRunning ? "Překlad běží" : "Překlad neběží")
                LabeledContent("Poslední stav", value: model.status)
                LabeledContent("Snímky", value: "\(model.frameCount)")
                LabeledContent("Televize", value: model.tv.ip.isEmpty ? "Nevybrána" : model.tv.ip)
            }

            Section("Poslední rozpoznané titulky") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Anglicky").font(.caption).foregroundStyle(.secondary)
                    Text(model.lastEnglish.isEmpty ? "Zatím nic" : model.lastEnglish)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Česky").font(.caption).foregroundStyle(.secondary)
                    Text(model.lastCzech.isEmpty ? "Zatím nic" : model.lastCzech)
                        .textSelection(.enabled)
                }
            }

            Section("Testování") {
                Button {
                    model.tv.sendSubtitle("Zkušební titulek PlayCaption iOS", duration: 8_000, preview: true)
                } label: {
                    Label("Odeslat zkušební titulek na TV", systemImage: "tv")
                }
                .disabled(model.tv.ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                ScrollView {
                    Text(model.logLines.suffix(60).joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                ShareLink(item: model.shareLogs()) {
                    Label("Sdílet diagnostický log", systemImage: "square.and.arrow.up")
                }
                Button("Vymazat zobrazený log") {
                    model.logLines.removeAll()
                }
                .tint(.secondary)
            } header: {
                Text("Diagnostický log")
            } footer: {
                Text("Log může obsahovat texty z hry, IP televize a názvy konzolí. Před odesláním ho zkontroluj. Tokeny účtu se do logu záměrně nepřidávají.")
            }
        }
        .navigationTitle("Diagnostika")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Named, local-only snapshot. No TV pairing tokens or Xbox authentication.
struct GameSubtitleProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var region: String
    var manualOCR: Bool
    var manualOCRLocked: Bool
    var manualOCRBox: CGRect
    var filterMenuText: Bool
    var ocrMode: String
    var expandOnEmpty: Bool
    var outputX: Double
    var outputBottom: Double
    var outputWidth: Double
    var outputFont: Double
    var outputLocked: Bool
    var choicesEnabled: Bool
    var choicesTextMode: Bool
    var choicesArea: CGRect
    var choicesLocked: Bool
    /// Optional to preserve previously saved 0.2.0 game profiles.
    var choicesOutputArea: CGRect?
    var choicesOutputLocked: Bool?
    var subtitleDuration: Double
    var skipOldTranslations: Bool
    var maxTranslationAge: Double
}
