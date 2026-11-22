import SwiftUI

/// Mirrors the Android PlayCaption phone's miniature 16:9 television:
/// blue = OCR input area, green = Czech subtitle output, yellow = game responses.
struct SubtitleSettingsView: View {
    @ObservedObject var model: CaptionAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Area = .reading
    @State private var orangePreviewTask: Task<Void, Never>?

    private enum Area: String, CaseIterable {
        case reading = "Čtení"
        case output = "Zobrazení"
        case choices = "Volby odpovědí"
        case outputChoices = "Překlad herních textů"
    }

    /// Green rectangle represents where the TV places Czech captions.
    private var outputRect: CGRect {
        let h = CGFloat(0.12 * model.outputFont)
        let w = CGFloat(model.outputWidth)
        let x = CGFloat(model.outputX)
        let y = CGFloat(model.outputBottom)
        return CGRect(x: x - w / 2, y: y - h, width: w, height: h)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Zvol oblast, kterou chceš upravit, a posuň ji v náhledu televize. Každá oblast má vlastní nastavení.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Modrá – odkud číst dialogy", systemImage: "square.dashed")
                            .foregroundStyle(.blue)
                        Label("Zelená – kam zobrazit české dialogy", systemImage: "square.dashed")
                            .foregroundStyle(.green)
                        Label("Žlutá – odkud číst volby / herní text", systemImage: "square.dashed")
                            .foregroundStyle(.yellow)
                        Label("Oranžová – kam zobrazit překlad žluté oblasti",
                              systemImage: "square.dashed")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 12))

                    Picker("Co upravovat", selection: $editing) {
                        Text("Modrá").tag(Area.reading)
                        Text("Zelená").tag(Area.output)
                        Text("Žlutá").tag(Area.choices)
                        Text("Oranžová").tag(Area.outputChoices)
                    }
                    .pickerStyle(.segmented)

                    television
                    Text("Dotkni se místa v náhledu, kam chceš posunout vybraný rámeček. Změny se ukládají automaticky.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if editing == .reading {
                        readControls
                    } else if editing == .output {
                        outputControls
                    } else if editing == .choices {
                        choicesControls
                    } else {
                        choicesOutputControls
                    }
                }
                .padding(16)
            }
            .onDisappear { orangePreviewTask?.cancel() }
            .navigationTitle("Oblasti titulků")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
    }

    private var television: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.09, green: 0.11, blue: 0.17))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.gray.opacity(0.65), lineWidth: 2)

                // A simplified TV layout like the Android preview.
                rectangle(outputRect, color: .green,
                          name: "České titulky", selected: editing == .output,
                          size: geo.size)
                if model.manualOCR {
                    rectangle(model.manualOCRBox, color: .blue,
                              name: "Čtení titulků", selected: editing == .reading,
                              size: geo.size)
                } else {
                    Text("OCR: automaticky")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(8)
                }
                if model.choicesEnabled {
                    rectangle(model.choicesArea, color: .yellow,
                              name: model.choicesTextMode ? "Text" : "Volby",
                              selected: editing == .choices,
                              size: geo.size)
                    rectangle(model.choicesOutputArea, color: .orange,
                              name: "Český překlad",
                              selected: editing == .outputChoices,
                              size: geo.size)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = min(1, max(0, value.location.x / max(1, geo.size.width)))
                            let y = min(1, max(0, value.location.y / max(1, geo.size.height)))
                            moveSelected(toX: x, y: y)
                        }
                        .onEnded { _ in
                            showOnTV()
                        })
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func rectangle(_ rect: CGRect, color: Color, name: String,
                           selected: Bool, size: CGSize) -> some View {
        Text(name)
            .font(.caption2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(selected ? .black : color)
            .frame(width: max(28, rect.width * size.width),
                   height: max(18, rect.height * size.height))
            .background(color.opacity(selected ? 0.85 : 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color, style: StrokeStyle(
                        lineWidth: selected ? 3 : 2,
                        dash: selected ? [] : [7, 4]))
            )
            .position(x: rect.midX * size.width, y: rect.midY * size.height)
            .allowsHitTesting(false)
    }

    private func moveSelected(toX x: CGFloat, y: CGFloat) {
        if editing == .reading {
            guard model.manualOCR, !model.manualOCRLocked else { return }
            var rect = model.manualOCRBox
            rect.origin.x = max(0, min(1 - rect.width, x - rect.width / 2))
            rect.origin.y = max(0, min(1 - rect.height, y - rect.height / 2))
            model.manualOCRBox = rect
        } else if editing == .output {
            guard !model.outputLocked else { return }
            let width = CGFloat(model.outputWidth)
            let h = CGFloat(0.12 * model.outputFont)
            model.outputX = Double(max(width / 2, min(1 - width / 2, x)))
            model.outputBottom = Double(max(h, min(1, y + h / 2)))
        } else if editing == .choices {
            guard model.choicesEnabled, !model.choicesLocked else { return }
            var rect = model.choicesArea
            rect.origin.x = max(0, min(1 - rect.width, x - rect.width / 2))
            rect.origin.y = max(0, min(1 - rect.height, y - rect.height / 2))
            model.choicesArea = rect
        } else {
            guard model.choicesEnabled, !model.choicesOutputLocked else { return }
            var rect = model.choicesOutputArea
            rect.origin.x = max(0, min(1 - rect.width, x - rect.width / 2))
            rect.origin.y = max(0, min(1 - rect.height, y - rect.height / 2))
            model.choicesOutputArea = rect
            scheduleOrangeRelocation()
        }
    }

    private var readControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modrý rámeček – odkud číst titulky")
                .font(.headline)
            Picker("Způsob čtení", selection: $model.manualOCR) {
                Text("Automaticky").tag(false)
                Text("Ručně").tag(true)
            }
            .pickerStyle(.segmented)

            if model.manualOCR {
                Toggle("Zamknout oblast čtení", isOn: $model.manualOCRLocked)
                if !model.manualOCRLocked {
                    Text("Šířka: \(Int(model.manualOCRBox.width * 100)) %")
                    Slider(value: Binding(
                        get: { Double(model.manualOCRBox.width) },
                        set: { updateOCRSize(width: CGFloat($0), height: nil) }
                    ), in: 0.20...1.0)
                    Text("Výška: \(Int(model.manualOCRBox.height * 100)) %")
                    Slider(value: Binding(
                        get: { Double(model.manualOCRBox.height) },
                        set: { updateOCRSize(width: nil, height: CGFloat($0)) }
                    ), in: 0.05...0.60)
                }
                Button("Ukázat modrý rámeček na televizi") {
                    model.tv.showOCRRegion(model.manualOCRBox, visible: true)
                }.buttonStyle(.bordered)
            } else {
                Picker("Výchozí oblast", selection: $model.subtitleRegion) {
                    ForEach(SubtitleRegion.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }.pickerStyle(.menu)
                Text("Automatika čte spodní část obrazu. Pokud se překládají tlačítka nebo mapa, přepni na ruční oblast a vyber jen místo s dialogy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Filtrovat položky herního menu", isOn: $model.filterMenuText)
            Text("Filtr může odstranit také dialog psaný velkými písmeny. Lze ho kdykoli vypnout.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Obnovit oblast podle Androidu") {
                model.manualOCRBox = CGRect(x: 0.10, y: 0.72,
                                            width: 0.80, height: 0.25)
                showOnTV()
            }.font(.subheadline)
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zelený rámeček – kam poslat české titulky")
                .font(.headline)
            Toggle("Zamknout polohu českých titulků", isOn: $model.outputLocked)
            if !model.outputLocked {
                Text("Šířka titulků: \(Int(model.outputWidth * 100)) %")
                Slider(value: $model.outputWidth, in: 0.30...0.95)
                Text("Velikost písma: \(Int(model.outputFont * 100)) %")
                Slider(value: $model.outputFont, in: 0.70...1.80)
            }
            Button("Ukázat české titulky na TCL") {
                showOnTV()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            Button("Obnovit výchozí polohu") {
                model.outputX = 0.5
                model.outputBottom = 0.93
                model.outputWidth = 0.62
                model.outputFont = 1
                showOnTV()
            }.font(.subheadline)
            Text("Tato poloha se přenáší se všemi českými titulky. Funguje s původní aplikací PlayCaption na TCL.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var choicesControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Žlutý rámeček – volby odpovědí a herní texty")
                .font(.headline)
            Toggle("Překládat volby / texty", isOn: $model.choicesEnabled)
            if model.choicesEnabled {
                Picker("Typ obsahu", selection: $model.choicesTextMode) {
                    Text("Volby odpovědí").tag(false)
                    Text("Text (dopisy, SMS)").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Zamknout žlutý rámeček", isOn: $model.choicesLocked)
                if !model.choicesLocked {
                    Text("Šířka: \(Int(model.choicesArea.width * 100)) %")
                    Slider(value: Binding(
                        get: { Double(model.choicesArea.width) },
                        set: { updateChoicesSize(width: CGFloat($0), height: nil) }
                    ), in: 0.10...1.0)
                    Text("Výška: \(Int(model.choicesArea.height * 100)) %")
                    Slider(value: Binding(
                        get: { Double(model.choicesArea.height) },
                        set: { updateChoicesSize(width: nil, height: CGFloat($0)) }
                    ), in: 0.10...1.0)
                }
                Button("Ukázat žlutý rámeček na TCL") {
                    model.tv.sendChoices([], area: model.choicesArea,
                                         asText: model.choicesTextMode, showFrame: true,
                                         outputArea: model.choicesOutputArea)
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                if !model.lastChoices.isEmpty {
                    Text("Poslední rozpoznané: \(model.lastChoices)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Obnovit výchozí oblast podle Androidu") {
                    model.choicesArea = CGRect(x: 0.55, y: 0.45,
                                               width: 0.40, height: 0.35)
                    showOnTV()
                }.font(.subheadline)
                Text("Polohu českého překladu nastav v oranžové oblasti. Naše vlastní TV aplikace ji podporuje nezávisle na žluté oblasti.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Experimentální režim: iPhone už umí číst a posílat volby nebo text do původního PlayCaption. Zatím ale neurčuje, která možnost je ve hře zvýrazněná; to doplníme po testu.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Volby jsou vypnuté, takže OCR dál čte pouze oblast dialogových titulků.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var choicesOutputControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Oranžový rámeček – kam zobrazit překlad herních textů")
                .font(.headline)
            Text("Žlutý rámeček určuje, odkud se anglický text čte. Oranžový určuje jeho české zobrazení na TCL C835.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.choicesEnabled {
                Toggle("Zamknout oranžový rámeček", isOn: $model.choicesOutputLocked)
                if !model.choicesOutputLocked {
                    Text("Šířka: \(Int(model.choicesOutputArea.width * 100)) %")
                    Slider(value: Binding(
                        get: { Double(model.choicesOutputArea.width) },
                        set: { updateChoicesOutputSize(width: CGFloat($0), height: nil) }
                    ), in: 0.20...0.95)
                    Text("Výška: \(Int(model.choicesOutputArea.height * 100)) %")
                    Slider(value: Binding(
                        get: { Double(model.choicesOutputArea.height) },
                        set: { updateChoicesOutputSize(width: nil, height: CGFloat($0)) }
                    ), in: 0.08...0.40)
                }
                Button("Ukázat oranžový překlad na TCL") {
                    showOnTV()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Button("Obnovit výchozí polohu") {
                    model.choicesOutputArea = CGRect(x: 0.07, y: 0.43,
                                                     width: 0.43, height: 0.17)
                    showOnTV()
                }
                .font(.subheadline)
            } else {
                Text("Nejdříve zapni překlad herních textů ve žluté oblasti.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func updateChoicesOutputSize(width: CGFloat?, height: CGFloat?) {
        var area = model.choicesOutputArea
        let center = CGPoint(x: area.midX, y: area.midY)
        if let width { area.size.width = width }
        if let height { area.size.height = height }
        area.origin.x = max(0, min(1 - area.width, center.x - area.width / 2))
        area.origin.y = max(0, min(1 - area.height, center.y - area.height / 2))
        model.choicesOutputArea = area
        scheduleOrangeRelocation()
    }

    private func updateChoicesSize(width: CGFloat?, height: CGFloat?) {
        var area = model.choicesArea
        let center = CGPoint(x: area.midX, y: area.midY)
        if let width { area.size.width = width }
        if let height { area.size.height = height }
        area.origin.x = max(0, min(1 - area.width, center.x - area.width / 2))
        area.origin.y = max(0, min(1 - area.height, center.y - area.height / 2))
        model.choicesArea = area
    }

    private func updateOCRSize(width: CGFloat?, height: CGFloat?) {
        var area = model.manualOCRBox
        let center = CGPoint(x: area.midX, y: area.midY)
        if let width { area.size.width = width }
        if let height { area.size.height = height }
        area.origin.x = max(0, min(1 - area.width, center.x - area.width / 2))
        area.origin.y = max(0, min(1 - area.height, center.y - area.height / 2))
        model.manualOCRBox = area
    }

    // Debounce drag/slider changes while a game is running. When a game text
    // is already visible, move that same translation instead of showing a demo.
    private func scheduleOrangeRelocation() {
        guard model.isRunning else { return }
        orangePreviewTask?.cancel()
        orangePreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            model.relocateActiveChoices()
        }
    }

    private func showOnTV() {
        if editing == .reading {
            guard model.manualOCR else { return }
            model.tv.showOCRRegion(model.manualOCRBox, visible: true)
        } else if editing == .output {
            model.tv.sendSubtitle("Ukázka českých titulků", duration: 6000, preview: true)
        } else if editing == .choices {
            guard model.choicesEnabled else { return }
            model.tv.sendChoices([], area: model.choicesArea,
                                 asText: model.choicesTextMode, showFrame: true,
                                 outputArea: model.choicesOutputArea)
        } else {
            guard model.choicesEnabled else { return }
            // During a game, resend only the current real translation at its
            // new coordinates. The sample is reserved for idle preview mode.
            if model.isRunning {
                orangePreviewTask?.cancel()
                model.relocateActiveChoices()
                return
            }
            orangePreviewTask?.cancel()
            model.tv.sendChoices(["Ukázka českého překladu"],
                                 area: model.choicesArea, asText: true,
                                 showFrame: false, outputArea: model.choicesOutputArea)
            orangePreviewTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, !model.isRunning else { return }
                model.tv.sendChoices([], area: model.choicesArea,
                                     asText: model.choicesTextMode,
                                     outputArea: model.choicesOutputArea)
            }
        }
    }
}
