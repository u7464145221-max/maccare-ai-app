import Foundation

/// Odcisk elementu w chwili zaznaczenia (lstat – bez podążania za dowiązaniami): urządzenie, inode, rozmiar, mtime i rodzaj.
/// Narzędzie porównuje go ponownie TUŻ przed przeniesieniem do Kosza – jeśli element został podmieniony albo zmieniony, nie jest ruszany.
public struct FileFingerprint: Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    /// `timeIntervalSince1970` jako wzorzec bitowy – porównanie dokładne, bez zaokrągleń tekstowych.
    public var mtimeBits: UInt64
    public var isDirectory: Bool
    public var isSymlink: Bool

    public init(_ st: FileStat) {
        device = st.device; inode = st.inode; size = st.logicalSize; mtimeBits = st.modified.timeIntervalSince1970.bitPattern
        isDirectory = st.isDirectory; isSymlink = st.isSymlink
    }

    public init?(path: String) {
        guard let st = FileStat.of(path) else { return nil }
        self.init(st)
    }

    /// `urządzenie:inode:rozmiar:mtime:rodzaj` (rodzaj: d = katalog, l = dowiązanie, f = plik).
    public var encoded: String { "\(device):\(inode):\(size):\(String(mtimeBits, radix: 16)):\(isDirectory ? "d" : (isSymlink ? "l" : "f"))" }

    public init?(encoded: String) {
        let f = encoded.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, let d = UInt64(f[0]), let i = UInt64(f[1]), let s = UInt64(f[2]), let m = UInt64(f[3], radix: 16), ["d", "l", "f"].contains(f[4]) else { return nil }
        device = d; inode = i; size = s; mtimeBits = m; isDirectory = f[4] == "d"; isSymlink = f[4] == "l"
    }
}

/// „Przenieś do Kosza” dla elementów zaznaczonych RĘCZNIE w „Moje pliki” (W5). Zawsze systemowy Kosz (`TrashService`), nigdy trwałe usunięcie – element można przywrócić w Finderze.
///
/// Zabezpieczenia: wywołuje wyłącznie użytkownik (`userOnly`) i tylko w trybie Edycja (`ExecutionGuard`, operacja `.trashSelected`); ścieżki przechodzą `PathPolicy` w zakresie
/// `.userSelected`; element musi nadal być tym samym obiektem co przy zaznaczeniu (odcisk lstat: urządzenie, inode, rozmiar, mtime) – sprawdzane w podglądzie i jeszcze raz tuż
/// przed każdym przeniesieniem; pliki w chmurze wymagają osobnego przełącznika; częściowa porażka nigdy nie jest „sukcesem”.
public struct TrashSelectedTool: AgentTool {
    /// Najwięcej elementów w jednej operacji (audyt 2, 3.10 – jak w Porządkach).
    public static let maxItems = 500

    let trash: TrashService
    let home: String
    let tempDir: String
    let appDataRoots: [String]
    /// Rozpoznawanie plików w chmurze (iCloud Drive/File Provider). Domyślnie: obszar chmury po ścieżce albo `isUbiquitousItem`; testy podstawiają własne.
    let isCloud: @Sendable (String) -> Bool

    public init(trash: TrashService, home: String = PathTools.home, tempDir: String = NSTemporaryDirectory(), appDataRoots: [String] = [],
                isCloud: (@Sendable (String) -> Bool)? = nil) {
        self.trash = trash; self.home = home; self.tempDir = tempDir; self.appDataRoots = appDataRoots
        self.isCloud = isCloud ?? Self.defaultCloudProbe(home: home)
    }

    /// Plik w chmurze: iCloud Drive/File Provider, folder znanego dostawcy (Dropbox, Google Drive, OneDrive…), plik nieobecny na dysku (dataless)
    /// – `PathPolicy.isCloudLocation` – albo `isUbiquitousItem` (m.in. Pulpit i Dokumenty synchronizowane z iCloud).
    public static func defaultCloudProbe(home: String) -> @Sendable (String) -> Bool {
        return { path in
            PathPolicy.isCloudLocation(path, home: home)
                || Self.ubiquitousOrUnknown(path)
        }
    }

    /// Audyt 16.10: odczyt metadanych NIEUDANY ⇒ traktujemy jak chmurę (usunięcie pliku iCloud kasuje go na wszystkich urządzeniach – bezpieczniej wymagać
    /// świadomego dołączenia). Brak wartości `isUbiquitousItem` (zwykły plik spoza iCloud – system zwraca wtedy nil) ⇒ nie chmura.
    static func ubiquitousOrUnknown(_ path: String) -> Bool {
        do { return try URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem ?? false }
        catch { return true }
    }

    public var userOnly: Bool { true }
    public var operation: MutatingOperation? { .trashSelected }

    public var spec: ToolSpec {
        ToolSpec(name: "trash_selected",
                 description: String(localized: "Przenosi do systemowego Kosza pliki i foldery zaznaczone RĘCZNIE przez użytkownika w „Moje pliki” (nigdy trwałe usunięcie; elementy można przywrócić w Finderze)."),
                 parameters: [ToolParameter("paths", .stringArray, String(localized: "Ścieżki zaznaczone przez użytkownika"), maxLength: 2048, maxItems: TrashSelectedTool.maxItems),
                              ToolParameter("fingerprints", .stringArray, String(localized: "Odciski elementów z chwili zaznaczenia (urządzenie:inode:rozmiar:mtime:rodzaj), w kolejności ścieżek"), required: false, maxLength: 160, maxItems: TrashSelectedTool.maxItems),
                              ToolParameter("include_cloud", .boolean, String(localized: "Zezwól także na pliki w chmurze (usunie je też z chmury) – osobny przełącznik użytkownika"), required: false)],
                 kind: .action, risk: .medium,
                 limits: String(localized: "Tylko katalog domowy na wolumenie startowym; nigdy katalogi systemowe, ~/Library poza regułami, pakiety aplikacji, biblioteki Zdjęć/Muzyki, katalog domowy i jego foldery pierwszego poziomu jako całość ani dane MacCare. Zawsze do Kosza (odwracalne)."),
                 reversible: true)
    }

    // MARK: Plan (wspólny dla podglądu i wykonania)
    struct Item { let raw: String; let target: String; let fingerprint: FileFingerprint; let isCloud: Bool }
    /// `skipped`: pominięte z powodu ZASAD (polityka ścieżek, chmura bez przełącznika, duplikat, zagnieżdżenie) – widoczne już w podglądzie jako ostrzeżenia.
    /// `changed`: element zmienił się po zaznaczeniu albo zniknął – przy wykonaniu liczone jako PORAŻKA (wynik „częściowo”), bo użytkownik zatwierdził operację na tym elemencie.
    struct Plan { var accepted: [Item] = []; var skipped: [(path: String, reason: String)] = []; var changed: [(path: String, reason: String)] = [] }

    func policy(includeCloud: Bool) -> PathPolicy {
        PathPolicy(home: home, ruleRoots: CleanupCatalog.allowedRoots(home: home, tempDir: tempDir), appDataRoots: appDataRoots)
    }

    func plan(_ a: ToolArguments) -> Plan {
        let includeCloud = a.bool("include_cloud") ?? false
        let pol = policy(includeCloud: includeCloud)
        let paths = a.strings("paths"), prints = a.strings("fingerprints")
        let homeDevice = FileStat.of(pol.home)?.device
        var plan = Plan()
        var seen = Set<String>()
        for (i, raw) in paths.enumerated() {
            if case .denied(let why) = pol.check(raw, scope: .userSelected) { plan.skipped.append((raw, why)); continue }
            let target = pol.resolvedTarget(raw)
            guard !seen.contains(target) else { plan.skipped.append((raw, "ten sam element zaznaczony dwa razy")); continue }
            guard let st = FileStat.of(target) else { plan.changed.append((raw, String(localized: "element już nie istnieje (zmieniony od chwili zaznaczenia)"))); continue }
            if let hd = homeDevice, st.device != hd { plan.skipped.append((raw, String(localized: "leży na innym wolumenie niż katalog domowy – Kosz działa tam inaczej"))); continue }
            let now = FileFingerprint(st)
            if i < prints.count, !prints[i].isEmpty {
                guard let selected = FileFingerprint(encoded: prints[i]) else { plan.changed.append((raw, "uszkodzony odcisk zaznaczenia")); continue }
                if selected != now { plan.changed.append((raw, "zmieniony od chwili zaznaczenia (inny plik albo zmieniony rozmiar/data) – zaznacz go ponownie")); continue }
            }
            let cloud = isCloud(target)
            if cloud && !includeCloud {
                plan.skipped.append((raw, String(localized: "plik w chmurze (iCloud/File Provider) – przeniesienie do Kosza usunie go także z chmury; włącz osobny przełącznik „Także pliki w chmurze”"))); continue
            }
            seen.insert(target)
            plan.accepted.append(Item(raw: raw, target: target, fingerprint: now, isCloud: cloud))
        }
        // zaznaczony folder i element w jego wnętrzu: wchodzi tylko folder (element jest jego częścią)
        let targets = plan.accepted.map(\.target)
        let nested = Set(plan.accepted.filter { it in targets.contains { $0 != it.target && PathTools.isWithin(it.target, $0) } }.map(\.target))
        if !nested.isEmpty {
            plan.skipped += plan.accepted.filter { nested.contains($0.target) }.map { ($0.raw, String(localized: "wchodzi w skład zaznaczonego folderu – zostanie przeniesiony razem z nim")) }
            plan.accepted.removeAll { nested.contains($0.target) }
        }
        return plan
    }

    private func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    // MARK: Podgląd (bez skutków ubocznych)
    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let plan = plan(a)
        guard !plan.accepted.isEmpty else {
            let why = (plan.skipped + plan.changed).prefix(5).map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }.joined(separator: "; ")
            let reason = why.isEmpty ? String(localized: "Nic nie zaznaczono.") : why
            throw ActionError(String(localized: "Żaden z zaznaczonych elementów nie może zostać przeniesiony do Kosza. \(reason)"))
        }
        var total: UInt64 = 0
        var lines: [String] = []
        var truncated = false
        for it in plan.accepted {
            var seen = Set<FileID>()
            let u = DiskUsage.measure(it.target, deadline: Date().addingTimeInterval(4), seen: &seen)
            total += u.allocated
            if u.unreadable > 0 { truncated = true }
            lines.append("\(tilde(it.target)) · \(ByteFormat.string(u.allocated))\(it.isCloud ? " · w chmurze" : "")")
        }
        var warnings = (plan.skipped + plan.changed).map { String(localized: "Pominięto „\(($0.path as NSString).lastPathComponent)”: \($0.reason)") }
        if plan.accepted.contains(where: \.isCloud) { warnings.insert(String(localized: "Uwaga: wśród elementów są pliki w chmurze – przeniesienie do Kosza usunie je także z chmury (na innych urządzeniach)."), at: 0) }
        if truncated { warnings.append(String(localized: "Nie wszystkie elementy dało się w pełni odczytać – rozmiar jest przybliżony.")) }
        let n = plan.accepted.count
        return OperationPreview(
            title: String(localized: "Przeniesienie do Kosza: \(PolishPlural.elements(n)) (\(ByteFormat.string(total)))"),
            purpose: String(localized: "Usunięcie wskazanych przez Ciebie plików i folderów z dysku (do Kosza macOS)"),
            expectedEffect: String(localized: "\(PolishPlural.elements(n)) trafi do Kosza (\(ByteFormat.string(total))). Miejsce na dysku wróci dopiero po opróżnieniu Kosza w Finderze."),
            risk: .medium, reversible: true,
            undoDescription: String(localized: "W Finderze: Kosz → zaznacz element → Odłóż (Put Back). Nic nie jest usuwane na stałe."),
            affectedItems: lines, estimatedBytes: total, warnings: warnings)
    }

    // MARK: Wykonanie
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.trashSelected)
        let plan = plan(a)
        let pol = policy(includeCloud: a.bool("include_cloud") ?? false)
        var moved: [JSONValue] = [], failed: [JSONValue] = []
        var movedBytes: UInt64 = 0
        var failedNames: [String] = []
        for c in plan.changed {                                                      // zmienione po zaznaczeniu/podglądzie = porażka, nie „pominięcie”
            failed.append(.object(["path": .string(c.path), "reason": .string(c.reason)])); failedNames.append((c.path as NSString).lastPathComponent)
        }
        for it in plan.accepted {
            let name = (it.target as NSString).lastPathComponent
            // Audyt 16.10 (3.5): Edycja mogła wygasnąć w trakcie operacji wieloelementowej – kolejne elementy zostają na miejscu (jak w pozostałych narzędziach Kosza).
            guard ExecutionGuard.allows(.trashSelected) else {
                failed.append(.object(["path": .string(it.target), "reason": .string(String(localized: "tryb Edycja wygasł – nic nie ruszono"))])); failedNames.append(name); continue
            }
            var seen = Set<FileID>()
            let bytes = DiskUsage.measure(it.target, deadline: Date().addingTimeInterval(15), seen: &seen).allocated
            // Ponowna weryfikacja TUŻ przed przeniesieniem (lstat, bez podążania za dowiązaniami): ta sama ścieżka po kanonizacji katalogu nadrzędnego
            // (nikt nie podmienił katalogu dowiązaniem) i ten sam odcisk (inode, rozmiar, mtime) co przy zaznaczeniu.
            guard pol.resolvedTarget(it.raw) == it.target, let st = FileStat.of(it.target), FileFingerprint(st) == it.fingerprint else {
                failed.append(.object(["path": .string(it.target), "reason": .string(String(localized: "zmieniony tuż przed przeniesieniem – nic nie ruszono"))])); failedNames.append(name); continue
            }
            do {
                let dest = try trash.moveToTrash(it.target)
                movedBytes += bytes
                moved.append(.object(["path": .string(it.target), "trash_path": .string(dest ?? ""), "bytes": .number(Double(bytes))]))
            } catch {
                failed.append(.object(["path": .string(it.target), "reason": .string(error.localizedDescription)])); failedNames.append(name)
            }
        }
        let skippedJSON: [JSONValue] = plan.skipped.map { .object(["path": .string($0.path), "reason": .string($0.reason)]) }
        let skippedNote = plan.skipped.isEmpty ? "" : String(localized: " Pominięto \(plan.skipped.count) (nie spełniały zasad bezpieczeństwa lub zmieniły się od zaznaczenia).")
        let attempted = plan.accepted.count + plan.changed.count
        let partial = !moved.isEmpty && !failed.isEmpty
        let summary: String
        if failed.isEmpty && !moved.isEmpty {
            summary = String(localized: "Przeniesiono do Kosza: \(PolishPlural.elements(moved.count)) (\(ByteFormat.string(movedBytes))). Możesz je przywrócić w Finderze (Kosz → Odłóż).\(skippedNote)")
        } else if partial {
            summary = String(localized: "Częściowo: do Kosza trafiło \(moved.count) z \(attempted) (\(ByteFormat.string(movedBytes))); nie udało się: \(failedNames.prefix(5).joined(separator: ", ")).\(skippedNote)")
        } else {
            let names = failedNames.prefix(5).joined(separator: ", "), failed = failedNames.isEmpty ? "" : String(localized: " Nie udało się: \(names).")
            summary = String(localized: "Nic nie trafiło do Kosza.\(failed)\(skippedNote)")
        }
        return ToolResult(summary: summary,
                          data: .object(["moved": .array(moved), "failed": .array(failed), "skipped": .array(skippedJSON), "bytes_moved": .number(Double(movedBytes)), "partial": .bool(partial)]),
                          success: failed.isEmpty && !moved.isEmpty)
    }
}
