import Foundation

/// Porządki przez systemowy Kosz (decyzja właściciela 15.10.2026, zakres Edycji `.trashOperations`). Wyłącznie z interfejsu (`userOnly`) – asystent ani
/// automaty go nie wywołują. Każda pozycja: świeży skan przy podglądzie i przy wykonaniu, polityka ścieżek `.ruleCleanup`, aplikacja-właściciel nie działa,
/// nie „trwałe usuwanie”; tuż przed przeniesieniem ponowne sprawdzenie (ta sama ścieżka po kanonizacji katalogu nadrzędnego, nie dowiązanie, polityka).
/// Zawsze Kosz (przywracalne z Findera: Kosz → Odłóż) – także pozycje, które w katalogu reguł idą do kwarantanny (ta czeka na poprawki bezpieczeństwa).
public struct TrashCleanupTool: AgentTool {
    let provider: DiagnosticsProvider
    let trash: TrashService
    let home: String
    let tempDir: String
    public init(provider: DiagnosticsProvider, trash: TrashService, home: String = PathTools.home, tempDir: String = NSTemporaryDirectory()) {
        self.provider = provider; self.trash = trash; self.home = home; self.tempDir = tempDir
    }

    public var userOnly: Bool { true }
    public var operation: MutatingOperation? { .cleanupToTrash }
    public var spec: ToolSpec {
        ToolSpec(name: "trash_cleanup_items",
                 description: String(localized: "Przenosi do systemowego Kosza pozycje zaznaczone przez użytkownika w Porządkach (pamięć podręczna, logi, pliki tymczasowe…). Nigdy trwałe usuwanie; elementy przywrócisz w Finderze."),
                 parameters: [ToolParameter("paths", .stringArray, String(localized: "Ścieżki elementów z wyników skanu Porządków"), maxLength: 1024, maxItems: 500)],
                 kind: .action, risk: .low, permissions: [.none],
                 limits: String(localized: "Tylko elementy z bieżącego skanu Porządków; pomija działające aplikacje; zawsze do Kosza."), reversible: true)
    }

    var policy: PathPolicy { PathPolicy(home: home, ruleRoots: CleanupCatalog.allowedRoots(home: home, tempDir: tempDir)) }

    func resolve(_ a: ToolArguments) async -> (ok: [CleanupCandidate], rejected: [String]) {
        let scan = await provider.verificationScan()
        let byPath = Dictionary(scan.candidates.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let pol = policy
        var ok: [CleanupCandidate] = [], rej: [String] = []
        for raw in a.strings("paths") {
            let p = pol.resolvedTarget(raw)
            guard let c = byPath[p] ?? byPath[raw] else { rej.append(String(localized: "\(raw): nie występuje w wynikach skanowania")); continue }
            guard pol.check(c.path, scope: .ruleCleanup).isAllowed else { rej.append(String(localized: "\(raw): odrzucone przez politykę ścieżek")); continue }
            if c.removal == .permanent { rej.append(String(localized: "\(raw): Kosz opróżnia się osobnym narzędziem")); continue }
            if c.ownerRunning { rej.append(String(localized: "\(raw): aplikacja \(c.owner) jest uruchomiona")); continue }
            ok.append(c)
        }
        return (ok, rej)
    }

    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let (ok, rej) = await resolve(a)
        let bytes = ok.reduce(UInt64(0)) { $0 + $1.allocatedSize }
        return OperationPreview(title: String(localized: "Porządki: \(PolishPlural.counted(ok.count, one: "element", few: "elementy", many: "elementów")) do Kosza"),
                                purpose: String(localized: "Zwolnienie miejsca na dysku"),
                                expectedEffect: String(localized: "\(ByteFormat.string(bytes)) trafi do Kosza. Miejsce na dysku wróci dopiero po opróżnieniu Kosza w Finderze."),
                                risk: ok.contains { $0.risk >= .medium } ? .medium : .low, reversible: true,
                                undoDescription: String(localized: "W Finderze: Kosz → zaznacz element → Odłóż (Put Back). Nic nie jest usuwane na stałe."),
                                affectedItems: ok.map { $0.path.replacingOccurrences(of: home, with: "~") }, estimatedBytes: bytes, warnings: rej)
    }

    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.cleanupToTrash)
        let (ok, rej) = await resolve(a)                                                   // świeży skan: stan aplikacji i ścieżek z chwili wykonania
        let pol = policy
        var moved: [JSONValue] = [], failed: [JSONValue] = []
        var movedBytes: UInt64 = 0
        var failedNames: [String] = []
        for c in ok {
            // Edycja mogła wygasnąć w trakcie długiej operacji – kolejnej zmiany nie zaczynamy (wynik częściowy).
            guard ExecutionGuard.allows(.cleanupToTrash) else {
                failed.append(.object(["path": .string(c.path), "reason": .string(String(localized: "tryb Edycja wygasł – nic nie ruszono"))])); failedNames.append(c.name); continue
            }
            // Tuż przed przeniesieniem: ta sama ścieżka po kanonizacji katalogu nadrzędnego, element istnieje i nie jest dowiązaniem, polityka nadal pozwala.
            guard pol.resolvedTarget(c.path) == c.path, let st = FileStat.of(c.path), !st.isSymlink, pol.check(c.path, scope: .ruleCleanup).isAllowed else {
                failed.append(.object(["path": .string(c.path), "reason": .string(String(localized: "zmieniony tuż przed przeniesieniem – nic nie ruszono"))])); failedNames.append(c.name); continue
            }
            do {
                let dest = try trash.moveToTrash(c.path)
                movedBytes += c.allocatedSize
                moved.append(.object(["path": .string(c.path), "trash_path": .string(dest ?? ""), "bytes": .number(Double(c.allocatedSize))]))
            } catch {
                failed.append(.object(["path": .string(c.path), "reason": .string(error.localizedDescription)])); failedNames.append(c.name)
            }
        }
        let partial = !moved.isEmpty && !failed.isEmpty
        let summary: String
        if failed.isEmpty && !moved.isEmpty {
            summary = String(localized: "Przeniesiono do Kosza: \(PolishPlural.elements(moved.count)) (\(ByteFormat.string(movedBytes))). Możesz je przywrócić w Finderze (Kosz → Odłóż).")
        } else if partial {
            let names = failedNames.prefix(5).joined(separator: ", ")
            summary = String(localized: "Częściowo: do Kosza trafiło \(moved.count) z \(ok.count) (\(ByteFormat.string(movedBytes))); nie udało się: \(names).")
        } else {
            summary = String(localized: "Nic nie trafiło do Kosza.")
        }
        let rejected: [JSONValue] = rej.map { .string($0) }
        return ToolResult(summary: summary,
                          data: .object(["moved": .array(moved), "failed": .array(failed), "rejected": .array(rejected), "bytes_moved": .number(Double(movedBytes)), "partial": .bool(partial)]),
                          success: failed.isEmpty && !moved.isEmpty)
    }
}
