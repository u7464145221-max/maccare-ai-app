import Foundation

/// Pozostałości po odinstalowanych aplikacjach do Kosza (decyzja właściciela 15.10.2026, zakres Edycji `.trashOperations`). Tylko z interfejsu (`userOnly`).
/// Każdy element sprawdzany przy podglądzie i ponownie przy wykonaniu: wpis PIERWSZEGO poziomu w jednym z miejsc `LeftoverFinder.locations`, nazwa w postaci
/// identyfikatora pakietu, brak zainstalowanej lub działającej aplikacji tego identyfikatora (także pomocnika i producenta – `LeftoverFinder.isOwned`),
/// nie dowiązanie, ten sam odcisk co przy wyborze. Nieznany stan aplikacji (zainstalowanych lub działających) = odmowa. Zawsze Kosz, nigdy trwałe usuwanie.
public struct LeftoversTrashTool: AgentTool {
    let trash: TrashService
    let home: String
    /// Identyfikatory zainstalowanych aplikacji; nil = nie da się ustalić ⇒ odmowa.
    let installedBundleIDs: @Sendable () async -> Set<String>?
    /// Identyfikatory działających aplikacji (małe litery); nil = nie da się ustalić ⇒ odmowa.
    let runningBundleIDs: @Sendable () async -> Set<String>?
    /// Audyt 16.10 (2.2): czy system zna aplikację o tym identyfikatorze w dowolnym miejscu (LaunchServices) – wtedy to NIE jest pozostałość.
    let appKnownToSystem: @Sendable (String) -> Bool
    public init(trash: TrashService, home: String = PathTools.home, installedBundleIDs: @escaping @Sendable () async -> Set<String>?,
                runningBundleIDs: @escaping @Sendable () async -> Set<String>?, appKnownToSystem: @escaping @Sendable (String) -> Bool) {
        self.trash = trash; self.home = home; self.installedBundleIDs = installedBundleIDs; self.runningBundleIDs = runningBundleIDs
        self.appKnownToSystem = appKnownToSystem
    }

    public var userOnly: Bool { true }
    public var operation: MutatingOperation? { .leftoversToTrash }
    public var spec: ToolSpec {
        ToolSpec(name: "trash_app_leftovers",
                 description: String(localized: "Przenosi do systemowego Kosza zaznaczone pozostałości po aplikacjach, których już nie ma na Macu. Nigdy trwałe usuwanie; wszystko przywrócisz w Finderze."),
                 parameters: [ToolParameter("items", .stringArray, String(localized: "Zaznaczone pozostałości w ~/Library"), maxLength: 1024, maxItems: 128),
                              ToolParameter("fingerprints", .stringArray, String(localized: "Odciski elementów z chwili wyboru (w tej samej kolejności)"), maxLength: 256, maxItems: 128)],
                 kind: .action, risk: .medium, permissions: [.none],
                 limits: String(localized: "Tylko wpisy pierwszego poziomu w Application Support, pamięci podręcznej, Preferencjach, Kontenerach i Stanie okien, nazwane identyfikatorem aplikacji, której nie ma i która nie działa; zawsze do Kosza."),
                 reversible: true)
    }

    struct Item { var path: String; var bundleID: String; var location: String; var risky: Bool; var size: UInt64; var fingerprint: String }
    struct Plan { var items: [Item]; var refused: [String]; var globalRefusal: String? }

    func plan(_ a: ToolArguments) async -> Plan {
        let policy = PathPolicy(home: home)
        let canonHome = PathTools.canonical(home, home: home)
        let paths = a.strings("items"), prints = a.strings("fingerprints")
        var plan = Plan(items: [], refused: [], globalRefusal: nil)
        guard paths.count == prints.count else { plan.globalRefusal = String(localized: "Niespójne dane wyboru – odśwież listę"); return plan }
        guard let installed = await installedBundleIDs() else { plan.globalRefusal = String(localized: "Nie udało się ustalić listy zainstalowanych aplikacji – nic nie ruszono"); return plan }
        guard let running = await runningBundleIDs() else { plan.globalRefusal = String(localized: "Nie udało się sprawdzić, które aplikacje działają – nic nie ruszono"); return plan }
        let known = installed.union(running)
        for (raw, fp) in zip(paths, prints) {
            let p = policy.resolvedTarget(raw)
            let name = (p as NSString).lastPathComponent
            let parent = (p as NSString).deletingLastPathComponent
            guard let loc = LeftoverFinder.locations.first(where: { parent == canonHome + "/" + $0.rel || parent == home + "/" + $0.rel }) else {
                plan.refused.append(String(localized: "\(name): leży poza miejscami pozostałości")); continue
            }
            guard let id = LeftoverFinder.bundleID(fromEntryName: name) else { plan.refused.append(String(localized: "\(name): nazwa nie wskazuje aplikacji")); continue }
            guard !LeftoverFinder.isOwned(id, installed: known), !appKnownToSystem(id) else { plan.refused.append(String(localized: "\(name): aplikacja jest zainstalowana albo działa")); continue }
            guard policy.check(p, scope: .uninstall).isAllowed, let st = FileStat.of(p), !st.isSymlink else {
                plan.refused.append(String(localized: "\(name): niedozwolone miejsce, brak elementu albo dowiązanie")); continue
            }
            guard FileFingerprint(st).encoded == fp else { plan.refused.append(String(localized: "\(name): zmienił się od wyboru – odśwież listę")); continue }
            let risky = loc.rel.hasSuffix("Application Support") || loc.rel.hasSuffix("Containers")
            plan.items.append(Item(path: p, bundleID: id, location: loc.label, risky: risky, size: DiskUsage.measure(p).allocated, fingerprint: fp))
        }
        return plan
    }

    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let p = await plan(a)
        if let why = p.globalRefusal {
            return OperationPreview(title: String(localized: "Pozostałości po aplikacjach"), purpose: String(localized: "Zwolnienie miejsca po odinstalowanych aplikacjach"),
                                    expectedEffect: String(localized: "Nic nie zostanie zmienione."), risk: .low, reversible: true, undoDescription: "—",
                                    affectedItems: [], estimatedBytes: 0, warnings: [why])
        }
        let total = p.items.reduce(0) { $0 + $1.size }
        var warnings = p.refused
        if p.items.contains(where: { $0.risky }) { warnings.append(String(localized: "Wśród zaznaczonych są Application Support lub kontenery – mogą zawierać dokumenty i ustawienia, gdyby aplikacja wróciła.")) }
        return OperationPreview(title: String(localized: "Pozostałości po aplikacjach (\(PolishPlural.elements(p.items.count)))"),
                                purpose: String(localized: "Zwolnienie miejsca po odinstalowanych aplikacjach"),
                                expectedEffect: String(localized: "\(ByteFormat.string(total)) trafi do Kosza. Miejsce na dysku wróci dopiero po opróżnieniu Kosza w Finderze."),
                                risk: .medium, reversible: true,
                                undoDescription: String(localized: "W Finderze: Kosz → zaznacz element → Odłóż (Put Back). Nic nie jest usuwane na stałe."),
                                affectedItems: p.items.map { $0.path.replacingOccurrences(of: home, with: "~") }, estimatedBytes: total, warnings: warnings)
    }

    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.leftoversToTrash)
        let p = await plan(a)                                                               // wszystkie warunki sprawdzane na nowo przy wykonaniu
        if let why = p.globalRefusal { return ToolResult(summary: String(localized: "Nic nie przeniesiono: \(why)."), data: .object(["refused": .string(why)]), success: false) }
        var moved: [JSONValue] = [], failed: [JSONValue] = p.refused.map { .object(["reason": .string($0)]) }
        var bytes: UInt64 = 0
        for it in p.items {
            guard ExecutionGuard.allows(.leftoversToTrash) else { failed.append(.object(["path": .string(it.path), "reason": .string(String(localized: "tryb Edycja wygasł – nic nie ruszono"))])); continue }
            // tuż przed przeniesieniem: ten sam element (odcisk), nie dowiązanie
            guard let st = FileStat.of(it.path), !st.isSymlink, FileFingerprint(st).encoded == it.fingerprint else {
                failed.append(.object(["path": .string(it.path), "reason": .string(String(localized: "zmieniony tuż przed przeniesieniem – nic nie ruszono"))])); continue
            }
            do {
                let dest = try trash.moveToTrash(it.path)
                moved.append(.object(["path": .string(it.path), "trash_path": .string(dest ?? ""), "bytes": .number(Double(it.size))]))
                bytes += it.size
            } catch { failed.append(.object(["path": .string(it.path), "reason": .string(error.localizedDescription)])) }
        }
        let summary = failed.isEmpty
            ? String(localized: "Przeniesiono do Kosza \(PolishPlural.elements(moved.count)) (\(ByteFormat.string(bytes))). Przywrócisz je w Finderze.")
            : String(localized: "Przeniesiono częściowo: \(moved.count) do Kosza, \(failed.count) zostało na miejscu.")
        return ToolResult(summary: summary, data: .object(["moved": .array(moved), "failed": .array(failed), "partial": .bool(!failed.isEmpty)]),
                          success: failed.isEmpty && !moved.isEmpty)
    }
}
