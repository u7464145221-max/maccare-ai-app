import AppKit
import SwiftUI
import ImageIO
import Combine
import MacCareCore

#if DEBUG || MACCARE_SCREENSHOTS
// P3-3 (AUD-ARCH-2): sterownik zrzutów jest tylko w buildzie debug i w buildzie do zrzutów (`build_app.sh --screenshots`).
// Wydanie (`build_app.sh` bez flagi) dostaje pusty zamiennik na końcu pliku – bez kodu zapisującego pliki i bez `dlsym`.

/// Tryb dokumentacyjny: `MacCareApp --screenshots <katalog> [--mode main|history]`.
/// Aplikacja sama renderuje własne okno do PNG (`NSView.cacheDisplay`) – nie wymaga uprawnienia „Nagrywanie ekranu”.
/// Tryb `history` wykonuje pełny przepływ czyszczenia **wyłącznie na syntetycznym katalogu domowym** (odmawia, gdy to prawdziwy $HOME).
@MainActor
enum ScreenshotDriver {
    private static var pageWatch: AnyCancellable?

    /// Uruchomienie do zrzutów ekranu (`--screenshots`) – wtedy aplikacja nie łączy się z siecią (np. sprawdzanie aktualizacji).
    static var isRequested: Bool { CommandLine.arguments.contains("--screenshots") }

    /// Audyt 2 (pkt 2.1): HOME porównywany po kanonizacji (jak `isRealHome` w AppModel) – „$HOME/” lub dowiązanie to wciąż prawdziwy HOME.
    /// Tryby mutujące wymagają dodatkowo Kosza zastępczego (nigdy prawdziwego Kosza).
    static func isSyntheticHome(_ model: AppModel) -> Bool {
        PathTools.canonical(model.home) != PathTools.canonical(NSHomeDirectory()) && model.usesSubstituteTrash
    }

    static func runIfRequested(model: AppModel) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("start (okna: \(NSApp.windows.count))")
        pageWatch = model.$module.sink { log("model.module → \($0.rawValue)") }
        let mode = args.firstIndex(of: "--mode").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "main"

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        bringToFront()
        log("po bringToFront (okna: \(NSApp.windows.map { "\($0.isVisible ? "V" : "-")\(type(of: $0))" }))")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if mode == "history" { await historyScenario(model: model, dir: dir) }
        else if mode == "ui" { await uiScenario(model: model, dir: dir) }
        else if mode == "ui2" { await ui2Scenario(model: model, dir: dir) }
        else if mode == "u1" { await u1Scenario(model: model, dir: dir) }
        else if mode == "t6d" { await t6dScenario(model: model, dir: dir) }
        else if mode == "w1" { await w1Scenario(model: model, dir: dir) }
        else if mode == "w2" { await w2Scenario(model: model, dir: dir) }
        else if mode == "w3" { await w3Scenario(model: model, dir: dir) }
        else if mode == "w4" { await w4Scenario(model: model, dir: dir) }
        else if mode == "w5" { await w5Scenario(model: model, dir: dir) }
        else if mode == "w7" { await w7Scenario(model: model, dir: dir) }
        else if mode == "w8" { await w8Scenario(model: model, dir: dir) }
        else { await mainScenario(model: model, dir: dir) }
        log("GOTOWE → \(dir.path)")
        exit(0)
    }

    // MARK: Scenariusz „ui”: nowy układ okna (prawdziwe dane, tylko odczyt)
    private static func uiScenario(model: AppModel, dir: URL) async {
        let prefix = CommandLine.arguments.firstIndex(of: "--prefix").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "ui"
        func both(_ name: String) async {
            NSApp.appearance = NSAppearance(named: .darkAqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-ciemny", dir)
            NSApp.appearance = NSAppearance(named: .aqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-jasny", dir)
            NSApp.appearance = nil
        }
        model.module = .smartScan
        await model.refreshLive(); await model.refreshFindings()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await both("smartscan-start")
        await model.smartScan()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await both("smartscan-wynik")

        model.open(.cleanup)
        model.restart(.cleanup)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("porzadki-start")
        await model.scanCleanup()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await both("porzadki-wynik")
        model.cleanupFocus = nil
        withAnimation { model.cleanupDetail = true }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("porzadki-szczegoly")
        await model.proposeCleanup()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture("\(prefix)-porzadki-podglad-ciemny", dir, includeSheet: true)
        await model.dismissSheet()
    }

    /// T6d: ten sam stan danych w trybie Prostym i Profesjonalnym (jasny + ciemny). Tylko odczyt; syntetyczny HOME dla Porządków.
    private static func t6dScenario(model: AppModel, dir: URL) async {
        func both(_ prefix: String, _ name: String, sheet: Bool = false) async {
            NSApp.appearance = NSAppearance(named: .darkAqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-ciemny", dir, includeSheet: sheet)
            NSApp.appearance = NSAppearance(named: .aqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-jasny", dir, includeSheet: sheet)
            NSApp.appearance = nil
        }
        await model.refreshLive(); await model.refreshFindings()
        await model.scanCleanup()                       // wspólny stan danych dla obu trybów
        for (mode, prefix) in [(ViewMode.simple, "ux-prosty"), (ViewMode.pro, "ux-pro")] {
            model.setViewMode(mode)
            model.open(.smartScan); model.restart(.smartScan)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(prefix, "panel")
            await model.smartScan()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(prefix, "smartscan")
            model.open(.cleanup); model.restart(.cleanup)
            await model.scanCleanup()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(prefix, "porzadki")
            model.cleanupFocus = nil
            withAnimation { model.cleanupDetail = true }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await both(prefix, "porzadki-szczegoly")
            model.cleanupDetail = false
            model.open(.performance)
            await model.scanPerformance()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(prefix, "wydajnosc")
            model.open(.protection)
            await model.scanProtection()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(prefix, "ochrona")
            if mode == .pro {
                model.open(.performance)
                try? await Task.sleep(nanoseconds: 800_000_000)
                model.requestDetailedSensors()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await both(prefix, "czujniki-zgoda", sheet: true)
                model.cancelDetailedSensorsConsent()
            }
        }
    }

    /// U1 (czytelność i kolorystyka): kluczowe ekrany w obu motywach – prawdziwe dane, tylko odczyt.
    private static func u1Scenario(model: AppModel, dir: URL) async {
        let prefix = CommandLine.arguments.firstIndex(of: "--prefix").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "u1"
        func both(_ name: String) async {
            NSApp.appearance = NSAppearance(named: .darkAqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-ciemny", dir)
            NSApp.appearance = NSAppearance(named: .aqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-jasny", dir)
            NSApp.appearance = nil
        }
        model.setViewMode(.pro)                      // zrzuty U1 w trybie Profesjonalnym (pełny pasek boczny, w tym Moje pliki)
        model.module = .smartScan
        await model.refreshLive(); await model.refreshFindings()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await both("panel")
        await model.smartScan()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await both("smartscan")
        model.open(.cleanup); model.restart(.cleanup)
        await model.scanCleanup()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await both("porzadki")
        model.cleanupFocus = nil
        withAnimation { model.cleanupDetail = true }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("porzadki-szczegoly")
        model.open(.protection)
        await model.scanProtection()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("ochrona")
        model.open(.performance)
        await model.scanPerformance()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("wydajnosc")
        model.open(.files)
        try? await Task.sleep(nanoseconds: 800_000_000)
        NotificationCenter.default.post(name: .init("MacCareScreenshotStartFiles"), object: nil)
        for _ in 0..<55 { try? await Task.sleep(nanoseconds: 1_000_000_000); if !model.diskMap.scanning && model.diskMap.nodes.count > 3 { break } }
        log("mapa: ścieżka=\(model.diskMap.path) węzłów=\(model.diskMap.nodes.count) skanuje=\(model.diskMap.scanning) faza=\(model.phase(.files))")
        try? await Task.sleep(nanoseconds: 1_500_000_000)             // dopuszcza dokończenie animacji przełączenia fazy i zwinięcia paska bocznego
        log("mapa po 1,5 s: faza=\(model.phase(.files))")
        await both("mapa")
    }

    private static func ui2Scenario(model: AppModel, dir: URL) async {
        let prefix = CommandLine.arguments.firstIndex(of: "--prefix").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "ui"
        func both(_ name: String) async {
            NSApp.appearance = NSAppearance(named: .darkAqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-ciemny", dir)
            NSApp.appearance = NSAppearance(named: .aqua); try? await Task.sleep(nanoseconds: 700_000_000); capture("\(prefix)-\(name)-jasny", dir)
            NSApp.appearance = nil
        }
        await model.refreshLive(); await model.refreshFindings()
        model.open(.protection)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await both("ochrona-start")
        await model.scanProtection()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("ochrona-wynik")
        model.open(.performance)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await model.scanPerformance()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await both("wydajnosc-wynik")
        model.open(.files)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await both("pliki-start")
        NotificationCenter.default.post(name: .init("MacCareScreenshotStartFiles"), object: nil)
        try? await Task.sleep(nanoseconds: 50_000_000_000)
        log("mapa: ścieżka=\(model.diskMap.path) węzłów=\(model.diskMap.nodes.count) skanuje=\(model.diskMap.scanning)")
        await both("pliki-mapa")
    }

    // MARK: Scenariusz 1: prawdziwe dane, tylko odczyt (arkusz zatwierdzenia jest anulowany, nic nie jest wykonywane)
    private static func mainScenario(model: AppModel, dir: URL) async {
        model.module = .smartScan
        await model.smartScan()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await model.refreshLive()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        capture("iter1-panel", dir)
        scrollMain(to: 0.5); try? await Task.sleep(nanoseconds: 900_000_000)
        capture("iter1-panel-wykres", dir)
        scrollMain(to: 1.0); try? await Task.sleep(nanoseconds: 900_000_000)
        capture("iter1-panel-ustalenia", dir)
        scrollMain(to: 0)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(nanoseconds: 800_000_000)
        capture("iter1-panel-ciemny", dir)
        NSApp.appearance = nil

        model.module = .cleanup
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await model.scanCleanup()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture("iter1-czyszczenie", dir)
        logScanSummary(model)

        await model.proposeCleanup()             // tylko podgląd – po sekundzie anulujemy
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture("iter1-czyszczenie-zatwierdzenie", dir, includeSheet: true)
        await model.decline()
    }

    /// Podsumowanie skanu (tylko odczyt) – trafia do raportu w STATUS.md.
    private static func logScanSummary(_ model: AppModel) {
        guard let r = model.scanResult else { return }
        log("SCAN_SUMMARY elementów=\(r.candidates.count) reguł=\(r.scannedRules) odzyskiwalne=\(ByteFormat.string(r.totalReclaimable)) bezpieczne=\(ByteFormat.string(r.safeReclaimable)) bezDostępu=\(r.unreadableLocations.count) zaznaczone=\(model.selectedCandidates.count)")
        for (cat, items) in r.byCategory().sorted(by: { $0.1.reduce(0) { $0 + $1.reclaimableSize } > $1.1.reduce(0) { $0 + $1.reclaimableSize } }) {
            let alloc = items.reduce(0) { $0 + $1.allocatedSize }, rec = items.reduce(0) { $0 + $1.reclaimableSize }
            let safe = items.filter { $0.safeToRemove }
            log("SCAN_CATEGORY \(cat.label): elementów=\(items.count) zajęte=\(ByteFormat.string(alloc)) odzyskiwalne=\(ByteFormat.string(rec)) bezpieczne=\(safe.count) (\(ByteFormat.string(safe.reduce(0) { $0 + $1.reclaimableSize }))) uruchomioneAplikacje=\(items.filter { $0.ownerRunning }.count) doPrzejrzenia=\(items.filter { !$0.safeToRemove && !$0.ownerRunning }.count)")
        }
    }

    // MARK: Scenariusz 2: dane testowe (syntetyczny HOME), tylko podgląd – kwarantannę zasiewa skrypt, bo w trybie tylko do odczytu
    // aplikacja nie przenosi niczego do kwarantanny (ani nie zatwierdza operacji).
    private static func historyScenario(model: AppModel, dir: URL) async {
        guard isSyntheticHome(model) else { log("ODMOWA: tryb history działa tylko na syntetycznym HOME"); return }
        model.module = .cleanup
        await model.scanCleanup()
        await model.proposeCleanup()                                   // w trybie tylko do odczytu: sam podgląd
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture("iter1-czyszczenie-podglad-synthetic", dir, includeSheet: true)
        await model.dismissSheet()
        await model.smartScan()
        model.module = .history
        for (tab, name) in [(HistoryTab.scans, "skany"), (.operations, "operacje"), (.quarantine, "kwarantanna")] {
            model.historyTab = tab
            model.reloadHistory()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            capture("iter1-historia-\(name)-synthetic", dir)
        }
    }

    // MARK: Zlecenia właściciela (zrzuty przed/po – `Scripts/screens_w.sh`)
    private static func argValue(_ name: String) -> String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    /// Czeka (do `limit` s), aż mapa skończy skan/odświeżanie i ma co najmniej `minNodes` węzłów.
    private static func waitMapIdle(_ model: AppModel, minNodes: Int = 1, limit: Int = 55) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<(limit * 5) {
            if !model.diskMap.scanning && !model.diskMap.refreshing && model.diskMap.nodes.count >= minNodes { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// W1: skan → zaznaczenie folderu → wejście w podfolder → powrót. Zrzut TUŻ po powrocie (30 ms): PRZED poprawką pusta mapa „Liczę rozmiary…” i „Zaznaczono: 0”,
    /// PO poprawce – pełna mapa z pamięci i zachowane zaznaczenie.
    private static func w1Scenario(model: AppModel, dir: URL) async {
        let prefix = argValue("--prefix") ?? "w1"
        model.setViewMode(.pro)
        model.module = .files
        try? await Task.sleep(nanoseconds: 800_000_000)
        NotificationCenter.default.post(name: .init("MacCareScreenshotStartFiles"), object: nil)
        await waitMapIdle(model, minNodes: 4)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let big = model.diskMap.nodes.first(where: { $0.isDirectory }) else { log("W1: brak folderu do wejścia"); return }
        model.diskMap.toggle(big)                                   // zaznaczenie na poziomie głównym
        NSApp.appearance = NSAppearance(named: .darkAqua); try? await Task.sleep(nanoseconds: 700_000_000)
        capture("\(prefix)-mapa-skan-ciemny", dir)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] {
            NSApp.appearance = NSAppearance(named: appearance)
            model.diskMap.open(big)
            await waitMapIdle(model)
            if suffix == "ciemny" { capture("\(prefix)-podfolder-ciemny", dir) }
            let t0 = Date()
            model.diskMap.go(to: 0)
            try? await Task.sleep(nanoseconds: 30_000_000)
            capture("\(prefix)-po-powrocie-\(suffix)", dir)
            log("W1 \(suffix): węzłów tuż po powrocie=\(model.diskMap.nodes.count) skanuje=\(model.diskMap.scanning) zaznaczono=\(model.diskMap.selected.count) (\(Int(Date().timeIntervalSince(t0) * 1000)) ms od go(to:))")
            await waitMapIdle(model)
        }
        NSApp.appearance = nil
    }

    /// W2: ładowanie mapy. Sekwencja zrzutów co 0,5 s od startu skanu (ciemny motyw) + liczniki publikacji `nodes` i przebudów układu bąbli w trakcie skanu.
    /// PRZED poprawką: widok skacze przy każdym policzonym folderze (kilkadziesiąt publikacji); PO: stały widok z postępem, mapa pojawia się raz.
    private static func w2Scenario(model: AppModel, dir: URL) async {
        let prefix = argValue("--prefix") ?? "w2"
        model.setViewMode(.pro)
        model.module = .files
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var publications = 0
        let sub = model.diskMap.$nodes.dropFirst().sink { _ in publications += 1 }
        let t0 = Date()
        NotificationCenter.default.post(name: .init("MacCareScreenshotStartFiles"), object: nil)
        var frame = 0
        while frame < 40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            capture(String(format: "\(prefix)-seq-%02d", frame), dir)
            frame += 1
            if !model.diskMap.scanning && model.diskMap.nodes.count > 3 && frame >= 6 { break }
        }
        sub.cancel()
        log("W2 skan: \(Int(Date().timeIntervalSince(t0) * 10)) dsek, zrzutów=\(frame), publikacji nodes=\(publications), węzłów=\(model.diskMap.nodes.count)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        capture("\(prefix)-wynik-ciemny", dir)
        NSApp.appearance = NSAppearance(named: .aqua); try? await Task.sleep(nanoseconds: 700_000_000)
        capture("\(prefix)-wynik-jasny", dir)
        NSApp.appearance = nil
    }

    /// Ustawia rozmiar zawartości okna (okno ma ukryty pasek tytułu, więc to rozmiar okna) i zwraca rozmiar faktycznie przyjęty przez system
    /// (poniżej minimalnego rozmiaru treści okno zostaje większe niż żądane – wtedy nazwy zrzutów niosą rozmiar rzeczywisty).
    private static func setWindowSize(_ w: Int, _ h: Int) async -> (width: Int, height: Int)? {
        guard let win = mainWindow() else { return nil }
        win.setContentSize(NSSize(width: w, height: h))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let c = win.contentView?.frame.size ?? .zero
        log("W3 okno: żądane \(w)×\(h), zawartość \(Int(c.width))×\(Int(c.height)), ramka \(Int(win.frame.width))×\(Int(win.frame.height)), skala \(win.backingScaleFactor), ekran \(win.screen.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "?")")
        guard c.width > 0, c.height > 0 else { return nil }
        return (Int(c.width), Int(c.height))
    }

    /// W5: „Przenieś do Kosza” w Moich plikach – zaznaczenie w odczycie (przycisk nieaktywny + „Włącz edycję…”), w Edycji (aktywny), arkusz zatwierdzenia z listą i sumą,
    /// wynik z korektą mapy oraz wynik CZĘŚCIOWY (jeden plik zmieniony po zaznaczeniu – prawdziwa weryfikacja tuż przed operacją). Wyłącznie syntetyczny HOME i zastępczy Kosz
    /// (`MACCARE_TRASH_DIR`) – prawdziwy Kosz użytkownika nie jest dotykany; sterownik odmawia pracy na prawdziwym HOME.
    /// Nowe widoki z 14.10.2026: skrót do „Moje pliki” po włączeniu Edycji w Prostym, Ochrona (ustalenie o aktualizacjach), skan niepełny, Duplikaty, Asystent.
    /// Tylko syntetyczny HOME; folder bez dostępu tworzony w nim i odblokowywany na końcu.
    private static func w7Scenario(model: AppModel, dir: URL) async {
        guard isSyntheticHome(model) else { log("ODMOWA: tryb w7 działa tylko na syntetycznym HOME"); return }
        let prefix = argValue("--prefix") ?? "w7"
        let (w, h) = (argValue("--sizes") ?? "1280x800").split(separator: ",").first.map { s -> (Int, Int) in
            let p = s.split(separator: "x").compactMap { Int($0) }; return p.count == 2 ? (p[0], p[1]) : (1280, 800) } ?? (1280, 800)
        guard let actual = await setWindowSize(w, h) else { log("W7: brak okna"); return }
        let size = "\(actual.width)x\(actual.height)"
        func both(_ name: String) async {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture("\(prefix)-\(size)-\(name)-\(suffix)", dir)
            }
            NSApp.appearance = nil
        }
        func settle(_ s: Double = 1.2) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        // 1) tryb Prosty + Edycja: pasek „Przejdź do Moje pliki”
        model.setViewMode(.simple); model.open(.smartScan); model.restart(.smartScan); await model.smartScan(); await settle(1.5)
        model.requestEditMode(); model.confirmEditMode(); await settle()
        log("W7 skrót: \(model.showFilesShortcut)")
        await both("prosty-edycja-skrot")
        model.leaveEditMode(); await settle(0.5)
        // 2) Ochrona – ustalenia (w tym oczekujące aktualizacje Apple, odczyt preferencji systemu)
        model.setViewMode(.pro); model.open(.protection); model.restart(.protection); await model.scanProtection(); await settle(2)
        log("W7 aktualizacje: \(model.snapshot?.updates?.pending.map(\.title) ?? [])")
        await both("ochrona-aktualizacje")
        // 3) Moje pliki – folder bez dostępu ⇒ „Skan niepełny”
        let fm = FileManager.default
        let locked = model.home + "/Zamkniety-synthetic"
        try? fm.createDirectory(atPath: locked + "/w-srodku", withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        model.open(.files)
        Task { await model.diskMap.scan(force: true) }
        model.setPhase(.files, .result)
        await waitMapIdle(model, minNodes: 4); await settle(1.5)
        log("W7 skan niepełny: \(model.diskMap.incompleteMessage ?? "brak")")
        await both("pliki-skan-niepelny")
        // 3b) F11: ta sama mapa jako prostokąty (preferencja wyglądu kopii zrzutowej – osobny identyfikator pakietu)
        let style = UserDefaults.standard
        style.set(MapChartStyle.treemap.rawValue, forKey: MapChartStyle.key); await settle(1.2)
        await both("pliki-prostokaty")
        style.set(MapChartStyle.bubbles.rawValue, forKey: MapChartStyle.key); await settle(0.5)
        // 4) Duplikaty
        NotificationCenter.default.post(name: .init("MacCareScreenshotFilesTab"), object: "duplicates"); await settle(0.8)
        await model.diskMap.findDuplicates(force: true); await settle(1.5)
        log("W7 duplikaty: grup \(model.diskMap.duplicates?.groups.count ?? -1)")
        await both("pliki-duplikaty")
        // 4b) Podobne zdjęcia – trzy syntetyczne JPEG-i (gradient + szum): dwa podobne, jeden odwrócony
        for (name, inverted, shift) in [("seria-1", false, 0), ("seria-2", false, 14), ("inne", true, 0)] {
            writeSyntheticPhoto(model.home + "/Zdjecia/\(name)-synthetic.jpg", inverted: inverted, shift: shift)
        }
        NotificationCenter.default.post(name: .init("MacCareScreenshotFilesTab"), object: "similar"); await settle(0.8)
        await model.diskMap.findSimilar(force: true); await settle(2)
        log("W7 podobne: grup \(model.diskMap.similar?.groups.count ?? -1), sprawdzono \(model.diskMap.similar?.imagesChecked ?? -1)")
        await both("pliki-podobne-zdjecia")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        // 5) Asystent – status lokalnego modelu (tylko lista modeli Ollamy, bez wnioskowania)
        model.open(.assistant); await model.assistant.refreshStatus(); await settle(1.5)
        log("W7 asystent: \(model.assistant.status)")
        await both("asystent")
        // 6) Aplikacje – inwentarz (tylko /System/Applications, odczyt) i możliwe pozostałości z syntetycznego HOME
        model.apps.roots = ["/System/Applications"]
        model.open(.apps); model.setPhase(.apps, .result)
        await model.apps.load(force: true); await settle(1.5)
        log("W7 aplikacje: \(model.apps.apps.count), pozostałości: \(model.apps.leftovers?.map(\.bundleID) ?? [])")
        await both("aplikacje")
        NSApp.appearance = nil
    }

    /// Syntetyczne „zdjęcie” JPEG 900×600 (gradient + szum, > 100 KB) – tylko do zrzutów, wyłącznie w syntetycznym HOME.
    private static func writeSyntheticPhoto(_ path: String, inverted: Bool, shift: Int) {
        let w = 900, h = 600
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        for y in 0..<h { for x in 0..<w {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let base = inverted ? 255 - x * 255 / (w - 1) : x * 255 / (w - 1)
            let v = UInt8(max(0, min(255, base + shift + Int(seed >> 28) - 8)))
            let i = (y * w + x) * 4; px[i] = v; px[i + 1] = UInt8(min(255, Int(v) / 2 + y / 5)); px[i + 2] = 255 - v; px[i + 3] = 255
        } }
        let img: CGImage? = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// W8 (F20–F22): pozostałości do Kosza (zaznaczenie, potwierdzenie, wynik), Historia → Pomiary, wybór danych przy odinstalowaniu, karta Powiadomień.
    /// Tylko syntetyczny HOME i atrapa Kosza (`MACCARE_TRASH_DIR`).
    private static func w8Scenario(model: AppModel, dir: URL) async {
        guard isSyntheticHome(model), ProcessInfo.processInfo.environment["MACCARE_TRASH_DIR"] != nil else { log("ODMOWA: tryb w8 działa tylko na syntetycznym HOME z MACCARE_TRASH_DIR"); return }
        let prefix = argValue("--prefix") ?? "w8"
        guard let actual = await setWindowSize(1280, 800) else { log("W8: brak okna"); return }
        let size = "\(actual.width)x\(actual.height)"
        func both(_ name: String, sheet: Bool = false) async {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture("\(prefix)-\(size)-\(name)-\(suffix)", dir, includeSheet: sheet)
            }
            NSApp.appearance = nil
        }
        func settle(_ s: Double = 1.2) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func apps(_ what: String) { NotificationCenter.default.post(name: .init("MacCareScreenshotApps"), object: what) }
        model.setViewMode(.pro)
        model.requestEditMode(); model.confirmEditMode(); await settle()
        model.apps.roots = [model.home + "/Applications"]
        model.open(.apps); model.setPhase(.apps, .result)
        await model.apps.load(force: true); await settle(1.5)
        log("W8 aplikacje: \(model.apps.apps.map(\.name)), pozostałości: \(model.apps.leftovers?.map(\.bundleID) ?? [])")
        apps("leftovers"); await settle()
        await both("pozostalosci-zaznaczone")
        let groups = (model.apps.leftovers ?? []).filter { $0.bundleID.hasPrefix("com.oldvendor") }
        await model.proposeLeftovers(paths: groups.flatMap { $0.safeItems.map(\.path) })                 // jak w interfejsie: bez „danych aplikacji”; await settle(1.8)
        log("W8 arkusz: \(model.sheet?.preview.title ?? "brak") | ostrzeżenia: \(model.sheet?.preview.warnings ?? [])")
        await both("pozostalosci-potwierdzenie", sheet: true)
        await model.approve(confirmed: []); await settle(2.5)
        log("W8 wynik: \(model.lastReport?.message ?? "brak")")
        apps("leftovers"); await settle()
        await both("pozostalosci-wynik")
        model.open(.history); model.historyTab = .measurements; model.reloadHistory(); await settle(1.5)
        log("W8 pomiary: \(model.benchmarks.map { "\($0.operation): \($0.overall.rawValue)" })")
        await both("historia-pomiary")
        model.open(.apps); await settle()
        if let a = model.apps.apps.first { apps(a.path); await settle(2) ; await both("odinstaluj-wybor", sheet: true); apps("none"); await settle() }
        else { log("W8: brak syntetycznej aplikacji") }
        model.open(.settings); await settle(1.5)
        await both("ustawienia")
        if let tall = await setWindowSize(1280, 1400) {                                    // karta Powiadomień jest niżej – wyższe okno zamiast przewijania
            await settle(1.2); log("W8 wysokie okno: \(tall.width)x\(tall.height)")
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] {
                NSApp.appearance = NSAppearance(named: appearance); try? await Task.sleep(nanoseconds: 700_000_000)
                capture("\(prefix)-\(tall.width)x\(tall.height)-ustawienia-powiadomienia-\(suffix)", dir)
            }
        }
        NSApp.appearance = nil
    }

    private static func w5Scenario(model: AppModel, dir: URL) async {
        guard isSyntheticHome(model), ProcessInfo.processInfo.environment["MACCARE_TRASH_DIR"] != nil else { log("ODMOWA: tryb w5 działa tylko na syntetycznym HOME z MACCARE_TRASH_DIR"); return }
        let prefix = argValue("--prefix") ?? "w5"
        guard let actual = await setWindowSize(1280, 800) else { log("W5: brak okna"); return }
        let size = "\(actual.width)x\(actual.height)"
        model.setViewMode(.pro)
        model.module = .files
        func both(_ name: String, sheet: Bool = false) async {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture("\(prefix)-\(size)-\(name)-\(suffix)", dir, includeSheet: sheet)
            }
            NSApp.appearance = nil
        }
        func settle(_ s: Double = 1.2) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func enter(_ folder: String) async {
            await waitMapIdle(model, minNodes: 1)
            guard let n = model.diskMap.nodes.first(where: { $0.name == folder }) else { log("W5: brak folderu \(folder)"); return }
            model.diskMap.open(n); await waitMapIdle(model)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        Task { await model.diskMap.scan(force: true) }                                    // to samo, co robi „Skanuj” – bez zależności od cyklu życia widoku
        model.setPhase(.files, .result)
        await waitMapIdle(model, minNodes: 4)
        await enter("Filmy")
        for n in model.diskMap.nodes.prefix(2) { model.diskMap.toggle(n) }
        await settle(1.5)
        log("W5 tryb: \(model.executionMode), zaznaczono \(model.diskMap.selected.count) (\(ByteFormat.string(model.diskMap.selectedTotal))), przycisk aktywny: \(model.canTrashSelected)")
        await both("odczyt-zaznaczenie")
        model.requestEditMode(); model.confirmEditMode(); await settle()
        log("W5 tryb: \(model.executionMode), przycisk aktywny: \(model.canTrashSelected)")
        await both("edycja-zaznaczenie")
        await model.proposeTrashSelected(); await settle(1.8)
        log("W5 arkusz: \(model.sheet?.preview.title ?? "brak")")
        await both("edycja-potwierdzenie", sheet: true)
        await model.approve(confirmed: []); await settle(2.5)
        log("W5 wynik: \(model.lastReport?.message ?? "brak") | pozostało na mapie: \(model.diskMap.nodes.count)")
        await both("wynik-sukces")
        // wynik częściowy: jeden z dwóch zaznaczonych plików zmienia się po zaznaczeniu i po podglądzie (mtime) – weryfikacja tuż przed operacją go zatrzymuje
        model.filesReportDismissed()
        model.diskMap.go(to: 0); await settle(0.8)
        await enter("Pobrane")
        let two = Array(model.diskMap.nodes.prefix(2))
        for n in two { model.diskMap.toggle(n) }
        await model.proposeTrashSelected(); await settle(1.5)
        if let changed = two.last { _ = utimes(changed.path, nil) }                       // „ktoś dotknął plik” po podglądzie (mtime = teraz)
        await model.approve(confirmed: []); await settle(2.5)
        log("W5 wynik częściowy: success=\(model.lastReport?.success ?? true) partial=\(model.lastReport?.partial ?? false) – \(model.lastReport?.message ?? "brak")")
        await both("wynik-czesciowy")
        NSApp.appearance = nil
    }

    /// W4: przełącznik Tylko odczyt ↔ Edycja – pasek u góry, arkusz potwierdzenia, Edycja z odliczaniem, podglądy z powodem blokady, Ustawienia,
    /// powrót po bezczynności (limit skrócony do 1 s tylko na potrzeby zrzutu). Tylko odczyt: w zakresie `.trashSelectedOnly` nie istnieje żadna operacja do wykonania.
    private static func w4Scenario(model: AppModel, dir: URL) async {
        // audyt 16.10 (P3): scenariusz włącza Edycję i tworzy oczekującą operację – wyłącznie na syntetycznym HOME (jak w5/w7/w8)
        guard isSyntheticHome(model) else { log("ODMOWA: tryb w4 działa tylko na syntetycznym HOME"); return }
        let prefix = argValue("--prefix") ?? "w4"
        let (w, h) = (argValue("--sizes") ?? "1280x800").split(separator: ",").first.map { s -> (Int, Int) in
            let p = s.split(separator: "x").compactMap { Int($0) }; return p.count == 2 ? (p[0], p[1]) : (1280, 800) } ?? (1280, 800)
        guard let actual = await setWindowSize(w, h) else { log("W4: brak okna"); return }
        let size = "\(actual.width)x\(actual.height)"
        model.setViewMode(.pro)
        await model.refreshLive(); await model.refreshFindings()
        func both(_ name: String, sheet: Bool = false) async {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture("\(prefix)-\(size)-\(name)-\(suffix)", dir, includeSheet: sheet)
            }
            NSApp.appearance = nil
        }
        func settle(_ s: Double = 1.2) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

        // 1) tylko odczyt (stan po uruchomieniu)
        model.open(.smartScan); model.restart(.smartScan); await model.smartScan(); await settle(1.5)
        log("W4 tryb po starcie: \(model.executionMode)")
        await both("odczyt-pasek")
        model.open(.cleanup); model.restart(.cleanup); await model.scanCleanup(); await settle(1.2)
        await model.proposeCleanup(); await settle(1.5)
        await both("odczyt-podglad", sheet: true)
        await model.dismissSheet()
        model.module = .settings; await settle()
        await both("odczyt-ustawienia")
        // 2) arkusz potwierdzenia (samo wybranie „Edycja” niczego nie włącza)
        model.requestEditMode(); await settle(1.5)
        log("W4 tryb przy otwartym potwierdzeniu: \(model.executionMode)")
        await both("edycja-potwierdzenie", sheet: true)
        // 3) Edycja włączona
        model.confirmEditMode(); await settle()
        log("W4 tryb po potwierdzeniu: \(model.executionMode)")
        model.open(.smartScan); await settle()
        await both("edycja-pasek")
        model.open(.cleanup); await settle(1.2)
        await model.proposeCleanup(); await settle(1.5)
        await both("edycja-podglad", sheet: true)
        await model.dismissSheet()
        model.module = .settings; await settle()
        await both("edycja-ustawienia")
        // 4) automatyczny powrót do odczytu (limit skrócony do 1 s wyłącznie na potrzeby zrzutu)
        model.executionState.idleLimit = 1
        await settle(3.0)
        log("W4 tryb po bezczynności: \(model.executionMode), komunikat: \(model.editNotice ?? "brak")")
        await both("po-bezczynnosci")
        // 5) każda zmiana trybu zostawia wpis w Historii → Dziennik operacji (kto, kiedy, zakres)
        model.module = .history
        model.historyTab = .operations
        model.reloadHistory()
        await settle(1.5)
        await both("historia-dziennik")
        NSApp.appearance = nil
    }

    /// W3: ten sam zestaw ekranów w dwóch rozmiarach okna (`--sizes 1280x800,1440x900`) i obu motywach. Tylko odczyt, syntetyczny HOME.
    private static func w3Scenario(model: AppModel, dir: URL) async {
        let prefix = argValue("--prefix") ?? "w3"
        let sizes: [(Int, Int)] = (argValue("--sizes") ?? "1280x800,1440x900").split(separator: ",").compactMap {
            let p = $0.split(separator: "x").compactMap { Int($0) }; return p.count == 2 ? (p[0], p[1]) : nil
        }
        model.setViewMode(.pro)
        await model.refreshLive(); await model.refreshFindings()
        let only = argValue("--only").map { Set($0.split(separator: ",").map(String.init)) }                  // np. --only pliki-mapa,historia (domyślnie wszystkie ekrany)
        let themes = argValue("--themes") ?? "both"                                                          // dark | light | both
        func both(_ size: String, _ name: String, sheet: Bool = false) async {
            if let only, !only.contains(name) { return }
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "ciemny"), (.aqua, "jasny")] where themes == "both" || (themes == "dark") == (suffix == "ciemny") {
                NSApp.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture("\(prefix)-\(size)-\(name)-\(suffix)", dir, includeSheet: sheet)
            }
            NSApp.appearance = nil
        }
        for (w, h) in sizes {
            guard let actual = await setWindowSize(w, h) else { log("W3: brak okna dla rozmiaru \(w)x\(h) – pomijam"); continue }
            let size = "\(actual.width)x\(actual.height)"
            if actual.width != w || actual.height != h { log("W3: system przyciął \(w)x\(h) do minimalnego rozmiaru okna \(size) – zrzuty z rozmiarem rzeczywistym") }
            model.open(.smartScan); model.restart(.smartScan)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await both(size, "smartscan-start")
            await model.smartScan()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(size, "smartscan-wynik")

            model.open(.cleanup); model.restart(.cleanup)
            await model.scanCleanup()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(size, "porzadki-wynik")
            model.cleanupFocus = nil
            withAnimation { model.cleanupDetail = true }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await both(size, "porzadki-szczegoly")
            await model.proposeCleanup()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(size, "porzadki-podglad", sheet: true)
            await model.dismissSheet()
            model.cleanupDetail = false

            model.open(.files); model.restart(.files)
            NotificationCenter.default.post(name: .init("MacCareScreenshotFilesTab"), object: "map")
            try? await Task.sleep(nanoseconds: 800_000_000)
            await both(size, "pliki-start")
            NotificationCenter.default.post(name: .init("MacCareScreenshotStartFiles"), object: nil)
            await waitMapIdle(model, minNodes: 4)
            if let n = model.diskMap.nodes.first(where: { $0.isDirectory }), !model.diskMap.selected.contains(n.path) { model.diskMap.toggle(n) }   // stopka z zaznaczeniem
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await both(size, "pliki-mapa")
            NotificationCenter.default.post(name: .init("MacCareScreenshotFilesTab"), object: "large")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await both(size, "pliki-duze")
            NotificationCenter.default.post(name: .init("MacCareScreenshotFilesTab"), object: "map")

            model.open(.performance)
            await model.scanPerformance()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(size, "wydajnosc")
            model.open(.protection)
            await model.scanProtection()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await both(size, "ochrona")
            model.module = .history
            model.historyTab = .quarantine
            model.reloadHistory()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await both(size, "historia")
            model.module = .settings
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await both(size, "ustawienia")
        }
        NSApp.appearance = nil
    }

    // MARK: Przechwytywanie
    /// Okno uruchomione z terminala bywa przesłonięte – wtedy SwiftUI wstrzymuje rysowanie i zrzut wychodzi pusty.
    private static func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.isVisible && !(w is NSPanel) { w.makeKeyAndOrderFront(nil); w.orderFrontRegardless() }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.attachedSheet != nil || ($0.isVisible && $0.contentView != nil && !($0 is NSPanel)) }
    }

    /// Obraz złożonego okna z WindowServera (to, co faktycznie widać). Dotyczy wyłącznie okien tej aplikacji – nie wymaga
    /// uprawnienia „Nagrywanie ekranu”. `cacheDisplay` nie łapie treści rysowanej przez SwiftUI (ScrollView/NavigationSplitView).
    private static func windowImage(_ w: NSWindow) -> NSImage? {
        guard w.windowNumber > 0, let cg = Self.createWindowImage(CGWindowID(w.windowNumber)) else { return nil }
        let scale = w.backingScaleFactor
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    /// `CGWindowListCreateImage` jest oznaczone jako przestarzałe (zalecany ScreenCaptureKit, który wymaga uprawnienia).
    /// To narzędzie dokumentacyjne robi zrzut wyłącznie własnych okien, więc wołamy je dynamicznie – bez ostrzeżenia kompilatora.
    /// Gdyby symbol zniknął z systemu, funkcja zwróci nil i zrzut zostanie pominięty (aplikacja działa normalnie).
    private static func createWindowImage(_ id: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return fn(.null, optionIncludingWindow, id, boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }

    // MARK: Przewijanie strony (SwiftUI ScrollView jest oparty na NSScrollView)
    private static func largestScrollView(in v: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ x: NSView) {
            if let sv = x as? NSScrollView, (sv.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = sv }
            x.subviews.forEach(walk)
        }
        walk(v)
        return best
    }

    /// Przewija główny obszar do ułamka `f` (0 = góra, 1 = dół).
    private static func scrollMain(to f: CGFloat) {
        guard let win = mainWindow(), let root = win.contentView, let sv = largestScrollView(in: root), let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        let y = doc.isFlipped ? maxY * f : maxY * (1 - f)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private static func capture(_ name: String, _ dir: URL, includeSheet: Bool = false) {
        bringToFront()
        guard let win = mainWindow(), var image = windowImage(win) else { log("brak okna dla \(name)"); return }
        if includeSheet, let sheet = win.attachedSheet, let simg = windowImage(sheet) {
            // Arkusz jest osobnym oknem – składamy go na zrzucie okna głównego w jego prawdziwym położeniu.
            let base = image
            let out = NSImage(size: base.size)
            out.lockFocus()
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let x = sheet.frame.minX - win.frame.minX
            let y = sheet.frame.minY - win.frame.minY
            simg.draw(in: NSRect(x: x, y: y, width: simg.size.width, height: simg.size.height))
            out.unlockFocus()
            image = out
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = dir.appendingPathComponent(name + ".png")
        try? png.write(to: url)
        log("zapisano \(url.lastPathComponent) (\(Int(image.size.width))×\(Int(image.size.height)) pt, \(png.count / 1024) kB)")
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data(("SCREENSHOT " + s + "\n").utf8)) }
}

#else
/// Wydanie: brak trybu zrzutów (P3-3).
@MainActor
enum ScreenshotDriver {
    static var isRequested: Bool { false }
    static func runIfRequested(model: AppModel) async {}
}
#endif
