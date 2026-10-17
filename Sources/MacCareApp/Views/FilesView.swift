import SwiftUI
import MacCareSystem
import ImageIO
import MacCareCore

/// Moje pliki: mapa dysku (lista + wykres bąbelkowy) oraz największe pliki. Tylko odczyt.
struct FilesView: View {
    @EnvironmentObject var model: AppModel
    private var map: DiskMapStore { model.diskMap }
    @State private var tab = Tab.map
    private var large: [FileEntry] { map.largeFiles ?? [] }
    private var largeLoading: Bool { map.largeLoading }
    enum Tab: String, CaseIterable { case map = "Mapa dysku", large = "Duże pliki", duplicates = "Duplikaty", similar = "Podobne zdjęcia" }

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .init("MacCareScreenshotStartFiles"))) { _ in start() }   // tylko tryb zrzutów
            .onReceive(NotificationCenter.default.publisher(for: .init("MacCareScreenshotFilesTab"))) { n in
                switch n.object as? String { case "large": tab = .large; case "duplicates": tab = .duplicates; case "similar": tab = .similar; default: tab = .map }
            }   // tylko tryb zrzutów
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase(.files) {
        case .start:
            ModuleStart(module: .files, scanTitle: String(localized: "Skanuj"), onScan: { start() }, extra: {
                Button { chooseFolder() } label: { Label("Wybierz folder…", systemImage: "folder") }.buttonStyle(.soft)
                Text("Domyślnie: Twój folder domowy. Skan tylko czyta.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
            })
        case .scanning:
            ModuleStart(module: .files, scanTitle: String(localized: "Skanuj"), scanning: true, stage: String(localized: "Liczę rozmiary folderów…")) {}
        case .result:
            result
        }
    }

    /// Widok wyniku pokazujemy od razu: lista w stałej kolejności z rozmiarami dopisywanymi na bieżąco (skan całego HOME trwa minuty), mapa po skanie.
    /// `force`: przycisk „Skanuj” = świeży pomiar; wybór innego folderu korzysta z pamięci wyników (W1).
    private func start(force: Bool = true) {
        Task { await map.scan(force: force) }
        model.setPhase(.files, .result)                 // W2: bez progu „po 3 węzłach” – od razu stały widok z postępem (wiersze + pasek), mapa pojawia się po skanie
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = String(localized: "Skanuj")
        if p.runModal() == .OK, let u = p.url { openRoot(u.path) }
    }

    private func openRoot(_ path: String) {
        // Nowy korzeń = nowy magazyn; prosty sposób: przejdź do folderu przez stos ścieżek.
        map.jump(to: path)
        start(force: false)
    }

    private var result: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { model.restart(.files) } label: { Label("Zacznij od nowa", systemImage: "chevron.left") }
                    .buttonStyle(.soft).fixedSize()
                if tab == .map { Breadcrumbs(map: map) } else { Spacer(minLength: 0) }
                if tab == .map {
                    Button { chooseFolder() } label: { Label("Inny folder…", systemImage: "folder") }.buttonStyle(.soft).fixedSize()
                    Button { map.refreshCurrent() } label: { Label("Odśwież", systemImage: "arrow.clockwise") }.buttonStyle(.soft).fixedSize()
                        .disabled(map.scanning || map.refreshing).help("Policz ten folder ponownie (domyślnie pokazujemy wynik z pamięci)")
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(map.scanning ? String(localized: "Razem: liczę…") : String(localized: "Razem: \(ByteFormat.string(map.total))")).font(Theme.Typo.body.weight(.semibold)).foregroundStyle(Theme.Palette.text)
                        if let t = map.lastMeasuredAt {
                            Text(map.refreshing ? String(localized: "odświeżam…") : String(localized: "zmierzono \(Self.measuredLabel(t))")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                                .help("Rozmiary z pomiaru o \(t.formatted(date: .omitted, time: .shortened)) – kliknij „Odśwież”, aby policzyć ponownie.")
                        }
                    }.fixedSize()
                }
                SegmentedSwitch(selection: $tab, options: Tab.allCases, title: { $0.title }, module: .files, width: 520, accessibilityName: String(localized: "Widok Moich plików"))
            }
            switch tab {
            case .map: MapSection(map: model.diskMap, model: model)
            case .large: largeView
            case .duplicates: DuplicatesSection(map: model.diskMap, model: model)
            case .similar: SimilarPhotosSection(map: model.diskMap, model: model)
            }
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 16)
        .onChange(of: tab) { _, t in if t == .large && map.largeFiles == nil { loadLarge() } }
        .task { if map.lastMeasuredAt != nil, !map.scanning, !map.refreshing { await map.scan() } }     // F4: zapamiętany wynik – odśwież w tle, jeśli folder się zmienił albo wynik jest stary
    }

    // MARK: Duże pliki
    /// Audyt 2 (3.3): wynik niepełny jest oznaczony – jak w Duplikatach i Podobnych zdjęciach.
    static func largeFilesNote(_ c: DiskAnalyzer.Completeness) -> String? {
        if c.timedOut { return String(localized: "Wynik niepełny: przeszukiwanie przerwano po limicie czasu – część folderów nie została sprawdzona.") }
        if c.unreadableDirectories > 0 { return String(localized: "Wynik niepełny: brak dostępu do \(c.unreadableDirectories) folderów (np. bez Pełnego dostępu do dysku).") }
        return nil
    }

    private var largeView: some View {
        SurfaceCard(padding: 0, radius: 24) {
            VStack(spacing: 0) {
                HStack { Text("Największe pliki (≥ 500 MB, bez ~/Library)").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text); Spacer()
                    if largeLoading { ProgressView().controlSize(.small) } else { Button("Odśwież") { loadLarge(force: true) }.buttonStyle(.soft) } }
                    .padding(14)
                if let note = Self.largeFilesNote(map.largeFilesCompleteness) {
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
                }
                Divider().opacity(0.3)
                List(large) { f in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((f.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1)
                            Text("\(tildePath(f.path)) · zmiana \(f.modified.formatted(date: .abbreviated, time: .omitted)) · ostatnio użyty \(f.accessed.formatted(date: .abbreviated, time: .omitted))")
                                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Pill(text: f.kind.label, color: Theme.Palette.textSecondary)
                        Text(ByteFormat.string(f.size)).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text)
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }.buttonStyle(.soft)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if large.isEmpty && !largeLoading { Text(map.largeFilesCompleteness.isComplete ? String(localized: "Brak plików spełniających kryteria.") : String(localized: "Nie znaleziono – ale wynik jest niepełny (patrz wyżej).")).foregroundStyle(Theme.Palette.textSecondary) } }
            }
        }
    }

    /// „21:05” dla dzisiejszego pomiaru, „14 paź, 21:05” dla starszego (zapamiętany wynik z poprzedniej sesji).
    static func measuredLabel(_ t: Date) -> String {
        Calendar.current.isDateInToday(t) ? t.formatted(date: .omitted, time: .shortened) : t.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func loadLarge(force: Bool = false) {
        Task { await map.loadLargeFiles(provider: model.provider, force: force) }
    }
}

/// Zakładka „Duplikaty” (P1-7): identyczna treść (SHA-256), pliki użytkownika ≥ 1 MB w bieżącym folderze mapy. Szukanie uruchamia użytkownik; tylko odczyt.
/// Usuwanie wyłącznie przez „Przenieś do Kosza” dla zaznaczonych (W5, tryb Edycja); ostatniej kopii w grupie nie da się zaznaczyć.
struct DuplicatesSection: View {
    @ObservedObject var map: DiskMapStore
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            SurfaceCard(padding: 0, radius: 24) {
                VStack(spacing: 0) {
                    header.padding(14)
                    Divider().opacity(0.3)
                    content
                }
            }
            .frame(maxHeight: .infinity)
            if let r = map.duplicates, !r.complete {
                Text("Wynik częściowy: przekroczono limit czasu lub liczby plików – nie wszystkie pliki zostały porównane.").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplikaty – pliki o identycznej treści (≥ 1 MB)").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text("Folder: \(tildePath(map.duplicatesRoot ?? map.rootPath)) · bez danych programów, projektów i bibliotek. Szukanie tylko czyta pliki.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
            }
            Spacer()
            if map.duplicatesLoading { ProgressView().controlSize(.small) }
            Button(map.duplicates == nil ? String(localized: "Szukaj duplikatów") : String(localized: "Szukaj ponownie")) { Task { await map.findDuplicates(force: map.duplicates != nil) } }
                .buttonStyle(.soft).disabled(map.duplicatesLoading).fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        if map.duplicatesLoading {
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(.linear).frame(maxWidth: 360)
                Text("Porównuję pliki – przy dużych folderach może to potrwać kilka minut.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = map.duplicates {
            if r.groups.isEmpty {
                Text("Nie znaleziono duplikatów wśród \(Plural.counted(r.candidateFiles, one: "pliku", few: "plików", many: "plików")).").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text(summary(r)).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                        ForEach(r.groups) { g in group(g) }
                    }.padding(12)
                }
            }
        } else {
            Text("Kliknij „Szukaj duplikatów”, aby porównać pliki w tym folderze.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ r: DuplicateFinder.ScanResult) -> String {
        let total = r.groups.reduce(UInt64(0)) { $0 + $1.reclaimableEstimate }
        return String(localized: "\(Plural.counted(r.groups.count, one: "grupa", few: "grupy", many: "grup")) · do odzyskania do \(ByteFormat.string(total)) (po usunięciu nadmiarowych kopii i opróżnieniu Kosza)")
    }

    private func group(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(Plural.counted(g.paths.count, one: "kopia", few: "kopie", many: "kopii")) · \(ByteFormat.string(g.fileSize)) każda").font(Theme.Typo.body.weight(.semibold)).foregroundStyle(Theme.Palette.text)
                Spacer()
                Text("do odzyskania ≈ \(ByteFormat.string(g.reclaimableEstimate))").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            if !g.clonedPaths.isEmpty {
                Text("Część kopii to klony APFS – współdzielą dane, ich usunięcie nie zwolni miejsca.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(g.paths, id: \.self) { p in row(p, g) }
        }
        .padding(10)
        .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    private func row(_ p: String, _ g: DuplicateGroup) -> some View {
        let allowed = map.canToggle(p, in: g)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { map.selected.contains(p) }, set: { _ in map.toggle(path: p, size: g.fileSize) }))
                .labelsHidden().toggleStyle(.largeCheckbox).disabled(!allowed)
                .help(allowed ? String(localized: "Zaznacz kopię do przeniesienia do Kosza") : String(localized: "To ostatnia niezaznaczona kopia – jedna musi zostać"))
                .accessibilityLabel("Zaznacz \((p as NSString).lastPathComponent)")
            VStack(alignment: .leading, spacing: 1) {
                Text((p as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle)
                Text(tildePath((p as NSString).deletingLastPathComponent) + (FileStat.of(p).map { String(localized: " · zmiana \($0.modified.formatted(date: .abbreviated, time: .omitted))") } ?? ""))
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }.buttonStyle(.soft)
        }
    }

    private var footer: some View {
        let n = map.selected.count
        return HStack(spacing: 12) {
            if let r = model.lastReport, r.tool == "trash_selected" {
                Text(r.message).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(r.success ? Theme.Palette.ok : Theme.Palette.warning).lineLimit(2)
            } else {
                Text(n == 0 ? String(localized: "Zaznacz nadmiarowe kopie. Jedna kopia z każdej grupy zawsze zostaje.") : String(localized: "Zaznaczone (we wszystkich widokach): \(Plural.elements(n)) · \(ByteFormat.string(map.selectedTotal))"))
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Button { Task { await model.proposeTrashSelected(includeCloud: false) } } label: {
                Label(n == 0 ? String(localized: "Przenieś do Kosza") : String(localized: "Przenieś do Kosza (\(n) · \(ByteFormat.string(map.selectedTotal)))"), systemImage: "trash")
            }
            .buttonStyle(.prominent(.files, large: true))
            .disabled(n == 0 || !model.canTrashSelected)
            .help(model.canTrashSelected ? String(localized: "Przenosi zaznaczone kopie do Kosza macOS – przywrócisz je w Finderze (Kosz → Odłóż).")
                                         : (model.isReadOnlyMode ? String(localized: "Dostępne w trybie Edycja (przełącznik u góry).") : model.previewHint))
        }
    }
}

/// Zakładka „Podobne zdjęcia” (P2-13, część): zdjęcia o bardzo podobnym wyglądzie (dHash, różnica ≤ 5/64 bitów) – np. serie, zmniejszone kopie, zrzuty.
/// Szukanie uruchamia użytkownik; tylko odczyt. Usuwanie wyłącznie przez „Przenieś do Kosza” (W5), ostatniego zdjęcia w grupie nie da się zaznaczyć.
struct SimilarPhotosSection: View {
    @ObservedObject var map: DiskMapStore
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            SurfaceCard(padding: 0, radius: 24) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Podobne zdjęcia (JPEG, HEIC, PNG…, od 100 KB)").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                            Text("Folder: \(tildePath(map.similarRoot ?? map.rootPath)). Porównanie wyglądu miniatur – podobne to nie zawsze zbędne (np. dwa ujęcia tej samej sceny). Szukanie tylko czyta pliki.")
                                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                        }
                        Spacer()
                        if map.similarLoading { ProgressView().controlSize(.small) }
                        Button(map.similar == nil ? String(localized: "Szukaj podobnych") : String(localized: "Szukaj ponownie")) { Task { await map.findSimilar(force: map.similar != nil) } }
                            .buttonStyle(.soft).disabled(map.similarLoading).fixedSize()
                    }.padding(14)
                    Divider().opacity(0.3)
                    content
                }
            }
            .frame(maxHeight: .infinity)
            if let r = map.similar, !r.complete {
                Text("Wynik częściowy: przekroczono limit czasu lub liczby zdjęć – nie wszystkie zdjęcia zostały porównane.").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
            }
            HStack {
                Text(map.selected.isEmpty ? String(localized: "Zaznacz zdjęcia do usunięcia. Jedno zdjęcie z każdej grupy zawsze zostaje.") : String(localized: "Zaznaczone (we wszystkich widokach): \(Plural.elements(map.selected.count)) · \(ByteFormat.string(map.selectedTotal))"))
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button { Task { await model.proposeTrashSelected(includeCloud: false) } } label: {
                    Label(map.selected.isEmpty ? String(localized: "Przenieś do Kosza") : String(localized: "Przenieś do Kosza (\(map.selected.count) · \(ByteFormat.string(map.selectedTotal)))"), systemImage: "trash")
                }
                .buttonStyle(.prominent(.files, large: true))
                .disabled(map.selected.isEmpty || !model.canTrashSelected)
                .help(model.canTrashSelected ? String(localized: "Przenosi zaznaczone zdjęcia do Kosza macOS – przywrócisz je w Finderze.") : (model.isReadOnlyMode ? String(localized: "Dostępne w trybie Edycja (przełącznik u góry).") : model.previewHint))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if map.similarLoading {
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(.linear).frame(maxWidth: 360)
                Text("Porównuję miniatury zdjęć…").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = map.similar {
            if r.groups.isEmpty {
                Text("Nie znaleziono podobnych zdjęć wśród \(Plural.counted(r.imagesChecked, one: "zdjęcia", few: "zdjęć", many: "zdjęć")).").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("\(Plural.counted(r.groups.count, one: "grupa", few: "grupy", many: "grup")) podobnych zdjęć (sprawdzono \(r.imagesChecked))").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                        ForEach(Array(r.groups.enumerated()), id: \.offset) { _, g in group(g) }
                    }.padding(12)
                }
            }
        } else {
            Text("Kliknij „Szukaj podobnych”, aby porównać zdjęcia w tym folderze.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func group(_ g: [FileEntry]) -> some View {
        let paths = g.map(\.path)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(g, id: \.path) { f in
                    let allowed = map.canToggle(f.path, inGroup: paths)
                    VStack(alignment: .leading, spacing: 4) {
                        Thumbnail(path: f.path).frame(width: 120, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { map.selected.contains(f.path) }, set: { _ in map.toggle(path: f.path, size: f.size) }))
                                .labelsHidden().toggleStyle(.largeCheckbox).disabled(!allowed)
                                .help(allowed ? String(localized: "Zaznacz zdjęcie do przeniesienia do Kosza") : String(localized: "To ostatnie niezaznaczone zdjęcie z grupy – jedno musi zostać"))
                                .accessibilityLabel("Zaznacz \((f.path as NSString).lastPathComponent)")
                            VStack(alignment: .leading, spacing: 0) {
                                Text((f.path as NSString).lastPathComponent).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle)
                                Text(ByteFormat.string(f.size)).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }.frame(width: 120, alignment: .leading)
                    }
                    .contextMenu { Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } }
                }
            }.padding(10)
        }
        .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }
}

/// Miniatura z pliku (ImageIO, ≤ 240 px) – ładowana w tle.
struct Thumbnail: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Theme.Palette.surface
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: "photo").foregroundStyle(Theme.Palette.textTertiary) }
        }
        .task(id: path) {
            let p = path
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 240, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

/// Okruszki ścieżki mapy dysku (jedna linia, przewijana poziomo – nigdy nie wypycha reszty paska).
struct Breadcrumbs: View {
    @ObservedObject var map: DiskMapStore
    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(map.path.enumerated()), id: \.offset) { i, p in
                        let last = i == map.path.count - 1
                        Button((p as NSString).lastPathComponent.isEmpty ? "/" : (p as NSString).lastPathComponent) { Motion.perform(.snappy) { map.go(to: i) } }.buttonStyle(.plain)
                            .foregroundStyle(last ? Theme.Palette.text : Theme.Palette.textSecondary)
                            .font(.system(size: 14, weight: last ? .semibold : .regular)).actionTarget()
                        if !last { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Palette.textSecondary) }
                    }
                }
            }
            if map.scanning { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wykres bąbelkowy: wypełnia kartę, kolor = rodzaj zawartości, etykiety tylko wewnątrz bąbli (2 linie, środek skracany).
/// Mniejsze bąble: nazwa w podpowiedzi i na liście. Zaznaczenie na liście podświetla bąbel i odwrotnie.
struct BubbleChart: View {
    @ObservedObject var map: DiskMapStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let bubbles = map.bubbles()
            let (placed, _) = BubbleLayout.place(bubbles.map { $0.circle }, in: geo.size)
            ZStack {
                ForEach(Array(zip(bubbles, placed).enumerated()), id: \.element.0.id) { _, pair in
                    bubble(pair.0, pair.1)
                }
                if bubbles.isEmpty { Text("Liczę rozmiary…").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private func bubble(_ b: DiskMapStore.Bubble, _ p: BubbleLayout.Placed) -> some View {
        let hl = b.node.map { map.highlighted == $0.path || map.selected.contains($0.path) } ?? false
        ZStack {
            Circle().fill(b.category.fillColor)
            Circle().stroke(hl ? Theme.Palette.text : b.category.outlineColor(), lineWidth: hl ? 4 : 1.5)
            if let r = p.labelRect {
                VStack(spacing: 1) {
                    Text(b.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(ByteFormat.string(b.size)).font(.system(size: 11.5, weight: .medium).monospacedDigit()).lineLimit(1)
                }
                .foregroundStyle(b.category.labelColor)
                .frame(width: r.width, height: r.height)
            }
        }
        .frame(width: p.radius * 2, height: p.radius * 2)
        .contentShape(Circle())
        .position(p.center)
        .animation(reduceMotion ? nil : .snappy(duration: 0.45), value: p.center)          // stały `id` bąbla ⇒ rosną i przesuwają się płynnie zamiast skakać
        .animation(reduceMotion ? nil : .snappy(duration: 0.45), value: p.radius)
        .help(b.tooltip)
        .onTapGesture(count: 2) { if let n = b.node { Motion.perform(.snappy) { map.open(n) } } }
        .onTapGesture { map.highlighted = b.node?.path }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(b.label), \(ByteFormat.string(b.size)), \(b.category.label)")
    }
}

enum MapChartStyle: String { case bubbles, treemap; static let key = "map.chartStyle" }

/// F11 (Radix): mapa prostokątów – pole ∝ rozmiar (`Treemap.squarify`); te same dane, kolory i gesty co bąbelki.
struct TreemapChart: View {
    @ObservedObject var map: DiskMapStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let items = map.bubbles()
            let rects = Treemap.squarify(items.map { Double($0.size) }, in: TreemapRect(x: 0, y: 0, width: Double(geo.size.width), height: Double(geo.size.height)))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(items, rects)), id: \.0.id) { item, r in
                    tile(item, r)
                }
                if items.isEmpty { Text("Liczę rozmiary…").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private func tile(_ b: DiskMapStore.Bubble, _ r: TreemapRect) -> some View {
        let hl = b.node.map { map.highlighted == $0.path || map.selected.contains($0.path) } ?? false
        let w = max(0, r.width - 3), h = max(0, r.height - 3)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(b.category.fillColor)
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(hl ? Theme.Palette.text : b.category.outlineColor(), lineWidth: hl ? 3 : 1)
            if w > 64 && h > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(ByteFormat.string(b.size)).font(.system(size: 11.5, weight: .medium).monospacedDigit()).lineLimit(1)
                }
                .foregroundStyle(b.category.labelColor)
                .padding(6)
            }
        }
        .frame(width: w, height: h)
        .offset(x: r.x + 1.5, y: r.y + 1.5)
        .animation(reduceMotion ? nil : .snappy(duration: 0.45), value: r)
        .contentShape(Rectangle())
        .help(b.tooltip)
        .onTapGesture(count: 2) { if let n = b.node { Motion.perform(.snappy) { map.open(n) } } }
        .onTapGesture { map.highlighted = b.node?.path }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(b.label), \(ByteFormat.string(b.size)), \(b.category.label)")
    }
}

/// Legenda kolorów: kategorie obecne w bieżącym folderze + ich łączna zajętość.
struct MapLegend: View {
    @ObservedObject var map: DiskMapStore
    var body: some View {
        FlowRow {
            ForEach(map.legend(), id: \.category) { item in
                HStack(spacing: 6) {
                    Circle().fill(item.category.fillColor).overlay(Circle().stroke(item.category.outlineColor(), lineWidth: 1.5)).frame(width: 12, height: 12)
                    Text(item.category.label).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.text)
                    Text(ByteFormat.string(item.size)).font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.trailing, 6)
            }
            Text("Kolor = przeważający rodzaj zawartości").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Sekcja mapy dysku (osobny widok, żeby obserwować `DiskMapStore`).
/// P1-4: wynik mapy jest niepełny (brak uprawnień) – mówimy o tym zamiast pokazywać zaniżone rozmiary jako pełne.
struct IncompleteScanBar: View {
    let text: String
    let openSettings: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Palette.warning)
            Text(text).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Pełny dostęp do dysku…", action: openSettings).buttonStyle(.soft).fixedSize()
                .help("Otwiera Ustawienia systemowe → Prywatność i ochrona → Pełny dostęp do dysku. MacCare niczego tam nie zmienia – decyzja należy do Ciebie.")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
        .accessibilityElement(children: .combine)
    }
}

struct MapSection: View {
    @EnvironmentObject private var disk: LiveDiskFacts                              // audyt 2 (4.5): tylko dysk startowy, nie pomiary co 2 s
    @ObservedObject var map: DiskMapStore
    @ObservedObject var model: AppModel
    /// Osobny przełącznik „Także pliki w chmurze” (domyślnie wyłączony – pliki w chmurze są wtedy pomijane).
    @State private var includeCloud = false
    /// F11: bąbelki albo prostokąty (preferencja wyglądu – nie tryb wykonania).
    @AppStorage(MapChartStyle.key) private var chartStyle = MapChartStyle.bubbles.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.45) }

    var body: some View {
        VStack(spacing: 12) {
            if !map.scanning, let msg = map.incompleteMessage { IncompleteScanBar(text: msg) { model.openFullDiskAccessSettings() } }
            HStack(spacing: 16) {
                SurfaceCard(padding: 0) { list }
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: 460)
                SurfaceCard(padding: 12) {
                    Group {
                        if map.scanning { scanProgressCard }
                        else {
                            VStack(spacing: 10) {
                                HStack {
                                    Spacer()
                                    SegmentedSwitch(selection: $chartStyle, options: [MapChartStyle.bubbles.rawValue, MapChartStyle.treemap.rawValue],
                                                    title: { $0 == MapChartStyle.treemap.rawValue ? String(localized: "Prostokąty") : String(localized: "Bąbelki") },
                                                    module: .files, width: 240, accessibilityName: String(localized: "Widok mapy"))
                                }
                                Group {
                                    if chartStyle == MapChartStyle.treemap.rawValue { TreemapChart(map: map) } else { BubbleChart(map: map) }
                                }
                                .frame(maxHeight: .infinity)
                                MapLegend(map: map).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                    .animation(motion, value: map.scanning)
                }
                .frame(minWidth: 380, maxWidth: .infinity)
            }
            .id(map.current)                                              // zmiana folderu = krótkie przejście zoom (wejście/powrót)
            .transition(reduceMotion ? .identity : .scale(scale: 0.97).combined(with: .opacity))
            .frame(maxHeight: .infinity)
            if let r = model.lastReport, r.tool == "trash_selected" { trashReport(r) }
            diskBar
        }
        .animation(motion, value: map.current)
        .onChange(of: map.cloudSelected.isEmpty) { _, empty in if empty { includeCloud = false } }
    }

    /// Lista w STAŁEJ kolejności podczas skanu (alfabetycznej, rozmiary dopisywane na bieżąco); po skanie sortowanie wg rozmiaru jednym animowanym przejściem.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(map.displayRows) { r in
                    if let n = r.node { row(n) } else { pendingRow(r) }
                }
                if !map.scanning, let gone = map.removedSinceBaseline() { removedSection(gone.items, since: gone.since) }
            }
            .padding(8)
            .animation(motion, value: map.displayRows.map(\.id))
        }
    }

    /// F12: co zniknęło od wcześniejszego pomiaru – tylko informacja (elementów już nie ma, więc nie da się ich zaznaczyć ani otworzyć).
    private func removedSection(_ items: [DiskMapStore.Removed], since: Date) -> some View {
        let date = since.formatted(.dateTime.day().month(.abbreviated))
        let total = items.reduce(UInt64(0)) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Zniknęło od \(date): \(Plural.elements(items.count)) · \(ByteFormat.string(total))"))
                .font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
            ForEach(items.prefix(8), id: \.name) { r in
                HStack {
                    Text(r.name).strikethrough().font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text("−" + ByteFormat.string(r.size)).font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.ok)
                }
            }
            if items.count > 8 { Text(String(localized: "i \(items.count - 8) więcej")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func pendingRow(_ r: ScanRow) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: .constant(false)).labelsHidden().toggleStyle(.largeCheckbox).disabled(true).help("Dostępne po policzeniu")
            Image(systemName: "folder").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle)
                Text("liczę…").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: 6)
            ProgressView().controlSize(.small).frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, 5).padding(.horizontal, 8).frame(height: 46)
    }

    /// Karta postępu zamiast mapy: mapa pojawia się raz, po policzeniu wszystkich elementów (bez skakania układu).
    private var scanProgressCard: some View {
        let p = map.progress ?? ScanProgress(done: 0, total: 0, latest: nil)
        return VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("Liczę rozmiary…").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
            Group {
                if p.total == 0 { ProgressView().progressViewStyle(.linear) }                 // dopóki nie znamy liczby pozycji, pasek jest nieokreślony; potem zawsze zgodny z „Policzono X z Y” (także 0%)
                else { ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) }
            }.frame(maxWidth: 360)
            Text(p.total == 0 ? String(localized: "Czytam zawartość folderu…") : String(localized: "Policzono \(p.done) z \(p.total) pozycji")).font(Theme.Typo.body.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
            if let l = p.latest { Text("Ostatnio: \(l)").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 360) }
            Text("Mapa pojawi się po policzeniu wszystkich elementów.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    static func changeLabel(_ c: DiskMapStore.SizeChange) -> String {
        let date = c.since.formatted(.dateTime.day().month(.abbreviated))
        if c.isNew { return String(localized: "nowy od \(date)") }
        let amount = (c.delta > 0 ? "+" : "−") + ByteFormat.string(c.delta.magnitude)
        return String(localized: "\(amount) od \(date)")
    }

    private func row(_ n: MapNode) -> some View {
        let on = map.highlighted == n.path
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { map.selected.contains(n.path) }, set: { _ in map.toggle(n) })).labelsHidden().toggleStyle(.largeCheckbox)
            Image(systemName: n.isDirectory && n.category == .other ? "folder.fill" : n.category.symbol)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(n.category.labelColor)
                .frame(width: 28, height: 28)
                .background(n.category.fillColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(n.category.outlineColor(), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(n.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle)
                Text(n.isDirectory ? "\(Plural.elements(n.items)) · \(n.category.label)" : n.category.label)
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text(ByteFormat.string(n.size)).font(Theme.Typo.body.monospacedDigit().weight(.medium)).foregroundStyle(Theme.Palette.text)
                    .lineLimit(1).fixedSize()
                if let c = map.change(for: n) {                                           // F11: zmiana od wcześniejszego pomiaru
                    Text(Self.changeLabel(c)).font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(c.delta > 0 ? Theme.Palette.warning : Theme.Palette.ok)
                        .lineLimit(1).fixedSize()
                        .help(String(localized: "Zmiana rozmiaru od pomiaru z \(c.since.formatted(date: .abbreviated, time: .shortened))"))
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
            if n.isDirectory {
                Button { Motion.perform(.snappy) { map.open(n) } } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Palette.textSecondary).frame(width: 32, height: 32).contentShape(Rectangle()) }.accessibilityLabel("Otwórz folder \(n.name)")
                    .buttonStyle(.plain).help("Otwórz folder")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.Palette.surfaceAlt : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(on ? Theme.Palette.stroke : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { map.highlighted = n.path }
        .contextMenu {
            Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)]) }
            if n.isDirectory { Button("Otwórz folder na mapie") { Motion.perform(.snappy) { map.open(n) } } }
            Divider()
            if model.canTrashSelected {
                Button("Przenieś do Kosza (zaznaczone: \(Plural.elements(map.selected.union([n.path]).count)))…") {
                    if !map.selected.contains(n.path) { map.toggle(n) }                       // element z menu jest częścią zaznaczenia
                    Task { await model.proposeTrashSelected(includeCloud: includeCloud) }
                }
            } else {
                Button("Przenieś do Kosza – tylko w trybie Edycja") {}.disabled(true)
                Button("Włącz edycję…") { model.requestEditMode() }
            }
        }
    }

    /// Duży przycisk „Przenieś do Kosza (N · rozmiar)”: aktywny tylko w trybie Edycja i przy niepustym zaznaczeniu (w odczycie widoczny, z wyjaśnieniem i skrótem „Włącz edycję…”).
    private var trashButton: some View {
        let n = map.selected.count
        return Button { Task { await model.proposeTrashSelected(includeCloud: includeCloud) } } label: {
            Label(n == 0 ? String(localized: "Przenieś do Kosza") : String(localized: "Przenieś do Kosza (\(n) · \(ByteFormat.string(map.selectedTotal)))"), systemImage: "trash")
        }
        .buttonStyle(.prominent(.files, large: true))
        .disabled(n == 0 || !model.canTrashSelected)
        .help(model.canTrashSelected ? String(localized: "Przenosi zaznaczone elementy do Kosza macOS – przywrócisz je w Finderze (Kosz → Odłóż). Nic nie jest kasowane na stałe.")
                                     : (model.isReadOnlyMode ? String(localized: "Dostępne w trybie Edycja (przełącznik u góry).") : model.previewHint))
    }

    /// Wynik ostatniego przeniesienia do Kosza: sukces, WYNIK CZĘŚCIOWY (nie sukces) albo porażka; zmierzona zmiana wolnego miejsca i uwaga, że miejsce wróci po opróżnieniu Kosza.
    private func trashReport(_ r: OperationReport) -> some View {
        let color = r.success ? Theme.Palette.ok : (r.partial ? Theme.Palette.warning : Theme.Palette.critical)
        let title = r.success ? String(localized: "Przeniesiono do Kosza") : (r.partial ? String(localized: "Częściowo – nie wszystko trafiło do Kosza") : String(localized: "Nie przeniesiono do Kosza"))
        return SurfaceCard(padding: 12, radius: 18) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: r.success ? "checkmark.circle.fill" : (r.partial ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")).font(.system(size: 20)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                    Text(r.message).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let d = r.measuredDelta {
                        Text("Zmierzona zmiana wolnego miejsca: \(d >= 0 ? "+" : "−")\(ByteFormat.string(UInt64(abs(d)))) – miejsce wróci po opróżnieniu Kosza w Finderze.")
                            .font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if !r.trashedPaths.isEmpty {
                    Button("Pokaż w Koszu") { NSWorkspace.shared.activateFileViewerSelecting(r.trashedPaths.map { URL(fileURLWithPath: $0) }) }.buttonStyle(.soft)
                }
                Button { model.filesReportDismissed() } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.accessibilityLabel("Zamknij raport")
                    .buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary).help("Zamknij")
            }
        }
    }

    /// Stopka: pasek zajętości dysku + zaznaczenie i akcje. W wąskim oknie układa się pionowo (`ViewThatFits`), więc przycisk nigdy nie wychodzi poza okno.
    private var diskBar: some View {
        let v = disk.bootVolume ?? model.bootVolumeQuick                // stopka pokazuje dysk od razu, bez czekania na pierwszy pełny pomiar systemu
        let disk = VStack(alignment: .leading, spacing: 5) {
            Text(v.map { String(localized: "\($0.name): zajęte \(ByteFormat.string($0.total - $0.availableImportant)) z \(ByteFormat.string($0.total))") } ?? String(localized: "Dysk"))
                .font(Theme.Typo.body.weight(.semibold)).foregroundStyle(Theme.Palette.text)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.surfaceAlt).overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 1))
                    if let v { Capsule().fill(AppModule.files.foreground).frame(width: max(8, g.size.width * CGFloat(1 - v.freeFraction))) }
                }
            }.frame(height: 10).frame(minWidth: 160)
        }
        let selection = VStack(alignment: .trailing, spacing: 6) {
            Text("Zaznaczono: \(map.selected.count) · \(ByteFormat.string(map.selectedTotal))").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: 10) {
                Button("Pokaż zaznaczone w Finderze") {
                    NSWorkspace.shared.activateFileViewerSelecting(map.selectedPaths.map { URL(fileURLWithPath: $0) })
                }.buttonStyle(.soft).disabled(map.selected.isEmpty)
                trashButton
            }
            if !map.cloudSelected.isEmpty {
                Toggle("Także pliki w chmurze – usunie je też z chmury (\(map.cloudSelected.count))", isOn: $includeCloud).toggleStyle(.largeCheckbox)
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning)
                    .help("Wśród zaznaczonych są pliki w chmurze (iCloud/File Provider). Bez tego przełącznika zostaną pominięte.")
            }
            if !model.canTrashSelected {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.Palette.textSecondary)
                    Text(model.isReadOnlyMode ? String(localized: "Tylko odczyt – żeby przenosić pliki do Kosza, włącz tryb Edycja.") : model.previewHint)
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if model.isReadOnlyMode { Button("Włącz edycję…") { model.requestEditMode() }.buttonStyle(.soft) }
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { disk; selection }
            VStack(alignment: .leading, spacing: 10) { disk; selection }
        }
    }
}
