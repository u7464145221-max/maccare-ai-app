import Foundation

/// Źródło danych diagnostycznych (implementacja na macOS: MacCareSystem; w testach: dane syntetyczne).
public protocol DiagnosticsProvider: Sendable {
    func snapshot() async -> SystemSnapshot
    func findings() async -> [Finding]
    func cleanupScan(categories: Set<CleanupCategory>?) async -> CleanupScanResult
    func largeFiles(minBytes: UInt64, olderThanDays: Int?, limit: Int) async -> [FileEntry]
    func crashSummary(process: String) async -> String?
    func benchmarkComparisons(limit: Int) async -> [BenchmarkComparison]
    /// Świeży skan Porządków do weryfikacji przed operacją (podgląd, wykonanie) – NIE zapisywany w Historii jako skan użytkownika
    /// (audyt 16.10, 3.8: jedna operacja dawała wcześniej trzy wpisy skanu).
    func verificationScan() async -> CleanupScanResult
}

public extension DiagnosticsProvider {
    func verificationScan() async -> CleanupScanResult { await cleanupScan(categories: nil) }
}

/// Operacje systemowe wymagające API macOS. Każda implementacja MUSI sama weryfikować cel (np. nazwę procesu).
public protocol SystemActions: Sendable {
    func quitApp(named: String, force: Bool) async throws -> String
    func disableUserLaunchAgent(label: String) async throws -> String
    func reindexSpotlight(volume: String) async throws -> String
    func flushDNSCache() async throws -> String
    func dnsDiagnostics() async -> String
    func openSettings(pane: String) async
    func runningApps() async -> [String]
}

public struct ActionError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

// MARK: - Narzędzia tylko do odczytu

public struct SystemOverviewTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "get_system_overview", description: String(localized: "Aktualne pomiary: CPU, pamięć, swap, dysk, I/O, bateria, temperatura. Zwraca listę dowodów z identyfikatorami."),
                                         kind: .read, risk: .none, limits: "Jedna migawka; brak historii.", reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        let s = await provider.snapshot()
        let ev = s.evidence().filter { !$0.id.hasPrefix("proc.") && !$0.id.hasPrefix("startup.item.") && !$0.id.hasPrefix("crash.") }
        return ToolResult(summary: ev.map { "[\($0.id)] \($0.label): \($0.value)" }.joined(separator: "\n"), evidence: ev)
    }
}

public struct FindingsTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "get_findings", description: String(localized: "Problemy wykryte przez deterministyczny silnik reguł (z poziomem pewności i dowodami)."),
                                         kind: .read, risk: .none, limits: String(localized: "Tylko znane reguły; brak wniosku ≠ brak problemu."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        let f = await provider.findings()
        if f.isEmpty { return ToolResult(summary: String(localized: "Silnik reguł nie wykrył problemów.")) }
        return ToolResult(summary: f.map { "- (\($0.severity.label), \($0.certainty.label)) \($0.title) — \($0.detail) [dowody: \($0.evidenceIDs.joined(separator: ", "))]" }.joined(separator: "\n"))
    }
}

public struct TopProcessesTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "get_top_processes", description: String(localized: "Aplikacje/procesy zużywające najwięcej zasobów (pogrupowane per aplikacja)."),
                                         parameters: [ToolParameter("sort_by", .string, "cpu lub memory", allowedValues: ["cpu", "memory"]),
                                                      ToolParameter("limit", .integer, "Liczba pozycji (1–20)", required: false, minimum: 1, maximum: 20)],
                                         kind: .read, risk: .none, limits: String(localized: "CPU to wartość chwilowa z jednego okresu próbkowania."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        let s = await provider.snapshot()
        let byCPU = a.string("sort_by") == "cpu"
        let g = s.appGroups().sorted { byCPU ? $0.cpuPercent > $1.cpuPercent : $0.memory > $1.memory }.prefix(a.int("limit") ?? 8)
        let lines = g.map { String(localized: "- \($0.name): CPU \(Int($0.cpuPercent))%, pamięć \(ByteFormat.string($0.memory)), procesów \($0.pids.count)\($0.allCurrentUser ? "" : " (systemowy)") [dowód: proc.\(byCPU ? "cpu" : "mem").\($0.name)]") }
        var header = String(localized: "Procesy użytkownika (pomiar dostępny tylko dla procesów bieżącego użytkownika")
        if let n = s.unmeasuredProcessCount, n > 0 { header += String(localized: "; niemierzalnych procesów systemowych: \(n) [dowód: proc.unmeasured]") }
        header += "):"
        return ToolResult(summary: ([header] + lines).joined(separator: "\n"), evidence: s.evidence().filter { $0.id.hasPrefix("proc.") })
    }
}

public struct CleanupScanTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "scan_cleanup", description: String(localized: "Skanuje dane do usunięcia wg listy dozwolonych reguł. Każdy element ma ryzyko i informację, czy jest bezpieczny."),
                                         parameters: [ToolParameter("category", .string, "Opcjonalna kategoria", required: false, allowedValues: CleanupCategory.allCases.map { $0.rawValue })],
                                         kind: .read, risk: .none, limits: String(localized: "Lokalizacje bez uprawnień są raportowane jako nieczytelne."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        let cat = a.string("category").flatMap(CleanupCategory.init(rawValue:))
        let r = await provider.cleanupScan(categories: cat.map { [$0] })
        var lines = r.byCategory().map { (c, items) in
            "- \(c.label): \(ByteFormat.string(items.reduce(0) { $0 + $1.reclaimableSize })) w \(items.count) elementach; bezpieczne: \(ByteFormat.string(items.filter { $0.safeToRemove }.reduce(0) { $0 + $1.reclaimableSize }))"
        }
        if !r.unreadableLocations.isEmpty { lines.append(String(localized: "Brak dostępu do: \(r.unreadableLocations.count) lokalizacji (uprawnienia).")) }
        return ToolResult(summary: lines.isEmpty ? String(localized: "Nie znaleziono danych do usunięcia.") : lines.joined(separator: "\n"),
                          data: .object(["safe_bytes": .number(Double(r.safeReclaimable)), "total_bytes": .number(Double(r.totalReclaimable))]))
    }
}

public struct LargeFilesTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "find_large_files", description: String(localized: "Największe pliki w katalogu domowym (bez ~/Library). Zwraca nazwy i rozmiary – nie czyta zawartości."),
                                         parameters: [ToolParameter("min_mb", .integer, "Minimalny rozmiar w MB", required: false, minimum: 10, maximum: 1_000_000),
                                                      ToolParameter("older_than_days", .integer, String(localized: "Tylko nieużywane od N dni"), required: false, minimum: 1, maximum: 3650),
                                                      ToolParameter("limit", .integer, String(localized: "Liczba wyników"), required: false, minimum: 1, maximum: 50)],
                                         kind: .read, risk: .none, limits: "Skanowanie ograniczone czasowo.", reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        let files = await provider.largeFiles(minBytes: UInt64(a.int("min_mb") ?? 500) * 1_000_000, olderThanDays: a.int("older_than_days"), limit: a.int("limit") ?? 15)
        let home = PathTools.home
        return ToolResult(summary: files.isEmpty ? String(localized: "Brak plików spełniających kryteria.") :
                            files.map { "- \($0.path.replacingOccurrences(of: home, with: "~")) — \(ByteFormat.string($0.size)), zmiana \($0.modified.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: "\n"))
    }
}

public struct CrashSummaryTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "read_crash_summary", description: String(localized: "Streszczenie raportów awarii/zawieszeń wskazanego procesu (typ wyjątku, wątek, moduł)."),
                                         parameters: [ToolParameter("process", .string, "Nazwa procesu", maxLength: 128)],
                                         kind: .read, risk: .none, limits: String(localized: "Tylko raporty użytkownika w ~/Library/Logs/DiagnosticReports."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        guard let s = await provider.crashSummary(process: a.string("process") ?? "") else { return ToolResult(summary: String(localized: "Brak raportów dla tego procesu.")) }
        return ToolResult(summary: s)
    }
}

public struct BenchmarkTool: AgentTool {
    let provider: DiagnosticsProvider
    public init(_ p: DiagnosticsProvider) { provider = p }
    public var spec: ToolSpec { ToolSpec(name: "compare_before_after", description: String(localized: "Wyniki pomiarów przed i po ostatnich operacjach, z oceną istotności statystycznej."),
                                         parameters: [ToolParameter("limit", .integer, "Liczba operacji", required: false, minimum: 1, maximum: 10)],
                                         kind: .read, risk: .none, limits: String(localized: "Wymaga wcześniejszego pomiaru bazowego."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        let c = await provider.benchmarkComparisons(limit: a.int("limit") ?? 3)
        return ToolResult(summary: c.isEmpty ? String(localized: "Brak operacji z pomiarem przed/po.") : c.map { $0.summary }.joined(separator: "\n\n"))
    }
}

public struct DNSDiagnosticsTool: AgentTool {
    let actions: SystemActions
    public init(_ a: SystemActions) { actions = a }
    public var spec: ToolSpec { ToolSpec(name: "diagnose_dns", description: String(localized: "Konfiguracja DNS tego Maca (serwery, domeny wyszukiwania) – bez wysyłania zapytań."), kind: .read, risk: .none,
                                         permissions: [.none], limits: String(localized: "Nie zmienia ustawień."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult { ToolResult(summary: await actions.dnsDiagnostics()) }
}

public struct OpenSettingsTool: AgentTool {
    let actions: SystemActions
    public init(_ a: SystemActions) { actions = a }
    public var spec: ToolSpec { ToolSpec(name: "open_security_settings", description: String(localized: "Otwiera właściwy panel Ustawień systemowych (użytkownik sam zmienia ustawienie)."),
                                         parameters: [ToolParameter("pane", .string, "Panel", allowedValues: ["sip", "gatekeeper", "filevault", "firewall", "fda", "login_items", "updates", "accessibility"])],
                                         kind: .read, risk: .none, limits: String(localized: "Nie zmienia ustawień – tylko je pokazuje."), reversible: true) }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        await actions.openSettings(pane: a.string("pane") ?? "")
        return ToolResult(summary: String(localized: "Otwarto panel ustawień."))
    }
}

// MARK: - Narzędzia wykonujące operacje

/// Przenosi wskazane elementy z wyników skanowania do kwarantanny (lub Kosza wg reguły).
/// Ścieżki MUSZĄ pochodzić z bieżącego skanu – AI nie może wskazać dowolnego pliku.
public struct QuarantineCleanupTool: AgentTool {
    let provider: DiagnosticsProvider
    let quarantine: QuarantineStore
    let trash: TrashService
    let home: String
    let tempDir: String
    public init(provider: DiagnosticsProvider, quarantine: QuarantineStore, trash: TrashService, home: String = PathTools.home, tempDir: String = NSTemporaryDirectory()) {
        self.provider = provider; self.quarantine = quarantine; self.trash = trash; self.home = home; self.tempDir = tempDir
    }
    public var spec: ToolSpec { ToolSpec(name: "quarantine_cleanup_items",
        description: String(localized: "Usuwa wybrane elementy z wyników skanowania czyszczenia: odtwarzalne → kwarantanna (przywracalna 7 dni), pozostałe → Kosz. Nie obsługuje opróżniania Kosza."),
        parameters: [ToolParameter("paths", .stringArray, String(localized: "Ścieżki elementów z wyników scan_cleanup"), maxLength: 1024, maxItems: 500),
                     ToolParameter("only_safe", .boolean, String(localized: "Pomiń elementy wymagające przejrzenia"), required: false)],
        kind: .action, risk: .low, permissions: [.none], limits: String(localized: "Tylko elementy z bieżącego skanu; pomija działające aplikacje; nigdy trwałe usuwanie."), reversible: true) }

    func resolve(_ a: ToolArguments) async -> (ok: [CleanupCandidate], rejected: [String]) {
        let scan = await provider.verificationScan()
        let byPath = Dictionary(scan.candidates.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let policy = PathPolicy(home: home, ruleRoots: CleanupCatalog.allowedRoots(home: home, tempDir: tempDir))
        var ok: [CleanupCandidate] = [], rej: [String] = []
        let onlySafe = a.bool("only_safe") ?? false
        for raw in a.strings("paths") {
            let p = policy.resolvedTarget(raw)
            guard let c = byPath[p] ?? byPath[raw] else { rej.append(String(localized: "\(raw): nie występuje w wynikach skanowania")); continue }
            guard policy.check(c.path, scope: .ruleCleanup).isAllowed else { rej.append(String(localized: "\(raw): odrzucone przez politykę ścieżek")); continue }
            if c.removal == .permanent { rej.append(String(localized: "\(raw): Kosz opróżnia się osobnym narzędziem")); continue }
            if c.ownerRunning { rej.append("\(raw): aplikacja \(c.owner) jest uruchomiona"); continue }
            if onlySafe && !c.safeToRemove { rej.append("\(raw): wymaga przejrzenia"); continue }
            ok.append(c)
        }
        return (ok, rej)
    }

    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let (ok, rej) = await resolve(a)
        let toTrash = ok.filter { $0.removal == .trash }
        return OperationPreview(title: String(localized: "Usunięcie \(PolishPlural.counted(ok.count, one: "elementu", few: "elementów", many: "elementów"))"), purpose: String(localized: "Zwolnienie miejsca na dysku"),
                                expectedEffect: String(localized: "Do odzyskania ok. \(ByteFormat.string(ok.reduce(0) { $0 + $1.reclaimableSize })). Miejsce z kwarantanny wraca po jej opróżnieniu (automatycznie po 7 dniach)."),
                                risk: ok.contains { $0.risk >= .medium } ? .medium : .low, reversible: true,
                                undoDescription: String(localized: "Elementy z kwarantanny przywrócisz w Historii; elementy z Kosza – z Findera (\(toTrash.count))."),
                                affectedItems: ok.map { $0.path.replacingOccurrences(of: home, with: "~") }, estimatedBytes: ok.reduce(0) { $0 + $1.reclaimableSize },
                                warnings: rej)
    }

    public var operation: MutatingOperation? { .quarantineMove }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.quarantineMove)
        let (ok, rej) = await resolve(a)
        let batch = UUID().uuidString
        var moved: UInt64 = 0, failed: [String] = [], entries: [JSONValue] = []
        for c in ok {
            do {
                if c.removal == .trash { _ = try trash.moveToTrash(c.path) }
                else { let e = try quarantine.quarantine(path: c.path, size: c.reclaimableSize, ruleID: c.ruleID, batchID: batch); entries.append(.string(e.id)) }
                moved += c.reclaimableSize
            } catch { failed.append("\(c.name): \(error.localizedDescription)") }
        }
        // P1-6 (AUD-UI-5/5b): sukces tylko wtedy, gdy COŚ przeniesiono i nic się nie nie powiodło; przeniesiono część ⇒ „częściowo” (nie sukces)
        let movedCount = ok.count - failed.count
        let partial = movedCount > 0 && (!failed.isEmpty || !rej.isEmpty)
        return ToolResult(summary: String(localized: "Przeniesiono \(PolishPlural.elements(movedCount)) (\(ByteFormat.string(moved))). Odrzucono: \(rej.count). Błędy: \(failed.count)."),
                          data: .object(["batch": .string(batch), "moved_bytes": .number(Double(moved)), "quarantine_ids": .array(entries),
                                         "rejected": .array(rej.map { .string($0) }), "failed": .array(failed.map { .string($0) }), "partial": .bool(partial)]),
                          success: movedCount > 0 && failed.isEmpty && rej.isEmpty)
    }
}

public struct EmptyTrashTool: AgentTool {
    let home: String
    public init(home: String = PathTools.home) { self.home = home }
    public var spec: ToolSpec { ToolSpec(name: "empty_trash", description: String(localized: "Trwale opróżnia Kosz użytkownika."), kind: .action, risk: .high, sensitive: [.destructive],
                                         limits: "Nieodwracalne. Tylko ~/.Trash.", reversible: false) }
    var trashPath: String { PathTools.canonical("~/.Trash", home: home) }
    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        // P1-2 (AUD-DEL-4): nieczytelny Kosz to NIE „pusty Kosz” – mówimy wprost, że nie mamy dostępu
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else {   // try? świadomie: nieczytelny Kosz ⇒ jawny komunikat (P1-2), nie „0 B”
            return OperationPreview(title: String(localized: "Opróżnienie Kosza – brak dostępu do Kosza"), purpose: String(localized: "Trwałe zwolnienie miejsca"),
                                    expectedEffect: String(localized: "Nic nie zostanie usunięte: MacCare nie może odczytać zawartości Kosza (uprawnienia lub Pełny dostęp do dysku)."), risk: .high, reversible: false,
                                    undoDescription: "—", affectedItems: [], warnings: [String(localized: "Brak dostępu do Kosza – opróżnij go w Finderze albo nadaj MacCare Pełny dostęp do dysku.")])
        }
        return OperationPreview(title: String(localized: "Opróżnienie Kosza (\(PolishPlural.elements(items.count)))"), purpose: String(localized: "Trwałe zwolnienie miejsca"),
                                expectedEffect: "Odzyskane zostanie ok. \(ByteFormat.string(DiskUsage.measure(trashPath).reclaimable)).", risk: .high, reversible: false,
                                undoDescription: String(localized: "NIE MOŻNA cofnąć."), affectedItems: Array(items.prefix(50)))
    }
    public var operation: MutatingOperation? { .emptyTrash }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.emptyTrash)
        let policy = PathPolicy(home: home, ruleRoots: [trashPath])
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else {   // try? świadomie: nieczytelny Kosz ⇒ jawny komunikat (P1-2), nie „0 B”
            return ToolResult(summary: String(localized: "Nie opróżniono Kosza: brak dostępu do jego zawartości (uprawnienia lub Pełny dostęp do dysku). Nic nie usunięto."),
                              data: .object(["freed_bytes": .number(0), "unreadable": .bool(true)]), success: false)
        }
        var freed: UInt64 = 0, failed = 0
        for k in contents {
            let p = trashPath + "/" + k
            guard policy.check(p, scope: .ruleCleanup).isAllowed else { failed += 1; continue }
            let u = DiskUsage.measure(p)
            do { try FileManager.default.removeItem(atPath: p); freed += u.reclaimable } catch { failed += 1 }
        }
        return ToolResult(summary: String(localized: "Opróżniono Kosz: \(ByteFormat.string(freed)). Nieusuniętych: \(failed)."), data: .object(["freed_bytes": .number(Double(freed)), "partial": .bool(failed > 0 && freed > 0)]),
                          success: failed == 0)
    }
}

public struct RestoreQuarantineTool: AgentTool {
    let quarantine: QuarantineStore
    public init(_ q: QuarantineStore) { quarantine = q }
    public var spec: ToolSpec { ToolSpec(name: "restore_from_quarantine", description: String(localized: "Przywraca elementy z kwarantanny na oryginalne miejsce."),
                                         parameters: [ToolParameter("ids", .stringArray, String(localized: "Identyfikatory wpisów kwarantanny"), maxLength: 64, maxItems: 500)],
                                         kind: .action, risk: .low, limits: String(localized: "Nie nadpisuje istniejących plików."), reversible: true) }
    public var operation: MutatingOperation? { .quarantineRestore }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.quarantineRestore)
        var ok = 0, errs: [String] = []
        for id in a.strings("ids") { do { try quarantine.restore(id); ok += 1 } catch { errs.append(error.localizedDescription) } }
        return ToolResult(summary: String(localized: "Przywrócono \(ok). Błędy: \(errs.count)."), data: .array(errs.map { .string($0) }), success: errs.isEmpty)
    }
}

/// Trwałe usunięcie wskazanych wpisów z kwarantanny MacCare (dane, które MacCare sam wcześniej tam przeniósł). Nieodwracalne.
public struct PurgeQuarantineTool: AgentTool {
    let quarantine: QuarantineStore
    public init(_ q: QuarantineStore) { quarantine = q }
    public var spec: ToolSpec { ToolSpec(name: "purge_quarantine", description: String(localized: "Trwale usuwa wskazane elementy z kwarantanny MacCare (nie ruszają one oryginalnych lokalizacji – te są już puste)."),
                                         parameters: [ToolParameter("ids", .stringArray, String(localized: "Identyfikatory wpisów kwarantanny"), maxLength: 64, maxItems: 500)],
                                         kind: .action, risk: .high, sensitive: [.destructive], limits: "Tylko wpisy z kwarantanny MacCare; nieodwracalne.", reversible: false) }
    func entries(_ a: ToolArguments) -> [QuarantineEntry] {
        let ids = Set(a.strings("ids"))
        return quarantine.entries.filter { ids.contains($0.id) }
    }
    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let es = entries(a)
        let missing = a.strings("ids").count - es.count
        return OperationPreview(title: String(localized: "Trwałe usunięcie \(PolishPlural.counted(es.count, one: "elementu", few: "elementów", many: "elementów")) z kwarantanny"), purpose: String(localized: "Zwolnienie miejsca zajętego przez kwarantannę"),
                                expectedEffect: String(localized: "Odzyskane zostanie ok. \(ByteFormat.string(es.reduce(0) { $0 + $1.size })). Elementów nie będzie można przywrócić."),
                                risk: .high, reversible: false, undoDescription: String(localized: "NIE MOŻNA cofnąć."),
                                affectedItems: es.map { $0.originalPath.replacingOccurrences(of: PathTools.home, with: "~") },
                                estimatedBytes: es.reduce(0) { $0 + $1.size },
                                warnings: missing > 0 ? [String(localized: "\(missing) wskazanych identyfikatorów nie istnieje w kwarantannie.")] : [])
    }
    public var operation: MutatingOperation? { .quarantinePurge }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.quarantinePurge)
        let es = entries(a)
        let out = quarantine.purgeDetailed(olderThan: nil, ids: Set(es.map { $0.id }))
        let removed = es.count - out.refused.count
        let refusedNote = out.refused.isEmpty ? "" : String(localized: " Odrzucono \(out.refused.count) wpisów wskazujących poza kwarantannę (uszkodzony lub podmieniony manifest) – nic z nich nie skasowano.")
        return ToolResult(summary: String(localized: "Trwale usunięto \(PolishPlural.elements(removed)) z kwarantanny (\(ByteFormat.string(out.freed))).\(refusedNote)"),
                          data: .object(["freed_bytes": .number(Double(out.freed)), "refused": .array(out.refused.map { .string($0) })]), success: out.refused.isEmpty)
    }
}

public struct QuitAppTool: AgentTool {
    let actions: SystemActions
    public init(_ a: SystemActions) { actions = a }
    public var spec: ToolSpec { ToolSpec(name: "quit_app", description: String(localized: "Prosi aplikację użytkownika o zamknięcie (jak ⌘Q). Wymuszenie tylko na wyraźne żądanie."),
                                         parameters: [ToolParameter("name", .string, String(localized: "Dokładna nazwa aplikacji z listy procesów"), maxLength: 128),
                                                      ToolParameter("force", .boolean, String(localized: "Wymuś zamknięcie (utrata niezapisanych danych)"), required: false)],
                                         kind: .action, risk: .medium, limits: String(localized: "Nie zamyka procesów systemowych ani chronionych."), reversible: true) }
    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let name = a.string("name") ?? ""
        let running = await actions.runningApps()
        var w: [String] = []
        if !running.contains(name) { w.append("Aplikacja „\(name)” nie jest uruchomiona – operacja nic nie zrobi.") }
        if ProcessGuard.protectedNames.contains(name) { w.append("Proces chroniony – operacja zostanie odrzucona.") }
        let force = a.bool("force") ?? false
        return OperationPreview(title: (force ? String(localized: "Wymuszone zamknięcie aplikacji \(name)") : String(localized: "Zamknięcie aplikacji \(name)")), purpose: String(localized: "Zwolnienie CPU/pamięci"),
                                expectedEffect: String(localized: "Aplikacja zakończy działanie; zasoby zostaną zwolnione."), risk: force ? .high : .medium, reversible: true,
                                undoDescription: String(localized: "Aplikację można uruchomić ponownie.") + (force ? String(localized: " Niezapisane dane zostaną utracone.") : String(localized: " Aplikacja może zapytać o zapis.")),
                                affectedItems: [name], warnings: w)
    }
    public var operation: MutatingOperation? { .quitApp }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.quitApp)
        let name = a.string("name") ?? ""
        guard !ProcessGuard.protectedNames.contains(name) else { throw ActionError(String(localized: "Proces chroniony: \(name)")) }
        return ToolResult(summary: try await actions.quitApp(named: name, force: a.bool("force") ?? false))
    }
}

public struct DisableLaunchAgentTool: AgentTool {
    let actions: SystemActions
    public init(_ a: SystemActions) { actions = a }
    public var spec: ToolSpec { ToolSpec(name: "disable_launch_agent", description: String(localized: "Wyłącza agenta autostartu użytkownika (launchctl bootout) i przenosi jego plist do kwarantanny."),
                                         parameters: [ToolParameter("label", .string, "Etykieta agenta (Label z plist)", maxLength: 256)],
                                         kind: .action, risk: .medium, limits: "Tylko ~/Library/LaunchAgents; nigdy elementy com.apple.* ani systemowe.", reversible: true) }
    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let l = a.string("label") ?? ""
        return OperationPreview(title: String(localized: "Wyłączenie autostartu \(l)"), purpose: String(localized: "Program przestanie uruchamiać się automatycznie"),
                                expectedEffect: "Agent zostanie zatrzymany, plik plist trafi do kwarantanny.", risk: .medium, reversible: true,
                                undoDescription: String(localized: "Przywróć plist z kwarantanny i zaloguj się ponownie."), affectedItems: [l],
                                warnings: l.hasPrefix("com.apple.") ? [String(localized: "Elementów Apple nie można wyłączyć.")] : [])
    }
    public var operation: MutatingOperation? { .disableLaunchAgent }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.disableLaunchAgent)
        let l = a.string("label") ?? ""
        guard !l.hasPrefix("com.apple.") else { throw ActionError(String(localized: "Elementów Apple nie wyłączam")) }
        return ToolResult(summary: try await actions.disableUserLaunchAgent(label: l))
    }
}

public struct ReindexSpotlightTool: AgentTool {
    let actions: SystemActions
    public init(_ a: SystemActions) { actions = a }
    public var spec: ToolSpec { ToolSpec(name: "reindex_spotlight", description: String(localized: "Inicjuje przebudowę indeksu Spotlight (mdutil -E). Uzasadnione, gdy wyszukiwanie nie znajduje plików lub mds stale obciąża CPU."),
                                         parameters: [ToolParameter("volume", .string, "Punkt montowania", allowedValues: ["/"])],
                                         kind: .action, risk: .medium, permissions: [.adminPassword], limits: String(localized: "Indeksowanie potrwa od kilkunastu minut do kilku godzin i chwilowo zwiększy obciążenie."), reversible: true) }
    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        OperationPreview(title: String(localized: "Przebudowa indeksu Spotlight"), purpose: String(localized: "Naprawa wyszukiwania Spotlight"), expectedEffect: String(localized: "Indeks zostanie usunięty i zbudowany od nowa. Do tego czasu wyszukiwanie będzie niepełne, a mds będzie używać CPU."),
                         risk: .medium, reversible: true, undoDescription: String(localized: "Indeks odbuduje się sam – nie da się go „przywrócić”, ale nie tracisz danych."), affectedItems: [a.string("volume") ?? "/"],
                         warnings: [String(localized: "Wymaga hasła administratora (okno systemowe).")])
    }
    public var operation: MutatingOperation? { .adminCommand }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.adminCommand)
        return ToolResult(summary: try await actions.reindexSpotlight(volume: a.string("volume") ?? "/"))
    }
}

public struct FlushDNSTool: AgentTool {
    let actions: SystemActions
    public init(_ a: SystemActions) { actions = a }
    public var spec: ToolSpec { ToolSpec(name: "flush_dns_cache", description: String(localized: "Czyści pamięć podręczną DNS (dscacheutil + mDNSResponder). Pomaga po zmianie DNS/hosts."),
                                         kind: .action, risk: .low, permissions: [.adminPassword], limits: String(localized: "Nie przyspiesza ogólnie systemu – rozwiązuje tylko nieaktualne wpisy DNS."), reversible: true) }
    public var operation: MutatingOperation? { .adminCommand }
    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.adminCommand)
        return ToolResult(summary: try await actions.flushDNSCache())
    }
}

public enum StandardTools {
    /// `appDataDirs`: katalogi danych MacCare (historia, kwarantanna) – `trash_selected` nigdy ich nie rusza.
    public static func registry(provider: DiagnosticsProvider, actions: SystemActions, quarantine: QuarantineStore, trash: TrashService,
                                home: String = PathTools.home, tempDir: String = NSTemporaryDirectory(), appDataDirs: [String] = [],
                                runningApps: @escaping @Sendable () async -> Set<String>? = { nil },
                                installedApps: @escaping @Sendable () async -> Set<String>? = { nil },
                                appKnownToSystem: @escaping @Sendable (String) -> Bool = { _ in true }) -> ToolRegistry {   // domyślnie „znana” ⇒ odmowa
        ToolRegistry([
            SystemOverviewTool(provider), FindingsTool(provider), TopProcessesTool(provider), CleanupScanTool(provider), LargeFilesTool(provider),
            CrashSummaryTool(provider), BenchmarkTool(provider), DNSDiagnosticsTool(actions), OpenSettingsTool(actions),
            QuarantineCleanupTool(provider: provider, quarantine: quarantine, trash: trash, home: home, tempDir: tempDir), EmptyTrashTool(home: home),
            RestoreQuarantineTool(quarantine), PurgeQuarantineTool(quarantine), QuitAppTool(actions), DisableLaunchAgentTool(actions), ReindexSpotlightTool(actions), FlushDNSTool(actions),
            TrashSelectedTool(trash: trash, home: home, tempDir: tempDir, appDataRoots: appDataDirs),
            TrashCleanupTool(provider: provider, trash: trash, home: home, tempDir: tempDir),
            UninstallAppTool(trash: trash, home: home, runningBundleIDs: runningApps),         // domyślnie stan nieznany ⇒ odmowa
            LeftoversTrashTool(trash: trash, home: home, installedBundleIDs: installedApps, runningBundleIDs: runningApps, appKnownToSystem: appKnownToSystem)
        ])
    }
}
