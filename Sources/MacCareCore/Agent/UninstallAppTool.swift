import Foundation

/// Odinstalowanie aplikacji przez Kosz (decyzja właściciela 15.10.2026, zakres Edycji `.trashOperations`). Tylko z interfejsu (`userOnly`).
/// Aplikacja: pakiet `.app` w /Applications lub ~/Applications (`PathPolicy.uninstall`), nie Apple i nie systemowa, NIE działa (stan z warstwy systemowej –
/// nieznany stan = odmowa), ten sam odcisk pakietu co przy wyborze. Dane: tylko wpisy pierwszego poziomu w znanych miejscach `~/Library`, NAZWANE identyfikatorem
/// tej aplikacji lub jej pomocnika (`AppData`) – sprawdzane ponownie przy wykonaniu. Najpierw aplikacja; gdy jej nie da się przenieść, danych nie ruszamy.
public struct UninstallAppTool: AgentTool {
    let trash: TrashService
    let home: String
    /// Identyfikatory działających aplikacji (małe litery); nil = stanu nie da się ustalić ⇒ odmowa.
    let runningBundleIDs: @Sendable () async -> Set<String>?
    public init(trash: TrashService, home: String = PathTools.home, runningBundleIDs: @escaping @Sendable () async -> Set<String>?) {
        self.trash = trash; self.home = home; self.runningBundleIDs = runningBundleIDs
    }

    public var userOnly: Bool { true }
    public var operation: MutatingOperation? { .uninstallToTrash }
    public var spec: ToolSpec {
        ToolSpec(name: "uninstall_app_to_trash",
                 description: String(localized: "Przenosi do systemowego Kosza aplikację wybraną przez użytkownika i zaznaczone dane tej aplikacji z ~/Library. Nigdy trwałe usuwanie; wszystko przywrócisz w Finderze."),
                 parameters: [ToolParameter("app_path", .string, String(localized: "Ścieżka pakietu aplikacji (.app)"), maxLength: 1024),
                              ToolParameter("app_fingerprint", .string, String(localized: "Odcisk pakietu z chwili wyboru"), maxLength: 256),
                              ToolParameter("items", .stringArray, String(localized: "Zaznaczone dane aplikacji w ~/Library"), required: false, maxLength: 1024, maxItems: 64)],
                 kind: .action, risk: .medium, permissions: [.none],
                 limits: String(localized: "Tylko aplikacje spoza Apple w /Applications i ~/Applications, które nie działają; tylko dane nazwane identyfikatorem tej aplikacji; zawsze do Kosza."),
                 reversible: true)
    }

    struct Plan { var app: String; var bundleID: String; var items: [AppDataItem]; var refused: [String]; var appRefusal: String? }

    func plan(_ a: ToolArguments) async -> Plan {
        let policy = PathPolicy(home: home)
        let raw = a.string("app_path") ?? ""
        let app = policy.resolvedTarget(raw)
        var plan = Plan(app: app, bundleID: "", items: [], refused: [], appRefusal: nil)
        func refuse(_ why: String) -> Plan { var p = plan; p.appRefusal = why; return p }
        guard app.lowercased().hasSuffix(".app"), policy.check(app, scope: .uninstall).isAllowed else { return refuse(String(localized: "To nie jest aplikacja w /Applications ani ~/Applications")) }
        guard let st = FileStat.of(app), !st.isSymlink, st.isDirectory else { return refuse(String(localized: "Aplikacja nie istnieje albo jest dowiązaniem")) }
        guard let fp = a.string("app_fingerprint"), FileFingerprint(st).encoded == fp else { return refuse(String(localized: "Aplikacja zmieniła się od wyboru – odśwież listę")) }
        guard let id = Bundle(path: app)?.bundleIdentifier, !id.isEmpty else { return refuse(String(localized: "Brak identyfikatora pakietu")) }
        plan.bundleID = id
        if id.lowercased().hasPrefix("com.apple.") { return refuse(String(localized: "Aplikacji Apple MacCare nie odinstalowuje")) }
        guard let running = await runningBundleIDs() else { return refuse(String(localized: "Nie udało się sprawdzić, czy aplikacja działa – nic nie ruszono")) }
        if running.contains(id.lowercased()) { return refuse(String(localized: "Aplikacja działa – zamknij ją i spróbuj ponownie")) }
        for rawItem in a.strings("items") {
            let p = policy.resolvedTarget(rawItem)
            let name = (p as NSString).lastPathComponent
            guard let loc = AppData.location(of: p, home: PathTools.canonical(home, home: home)) ?? AppData.location(of: p, home: home),
                  let assoc = AppData.association(entryName: name, appBundleID: id),
                  policy.check(p, scope: .uninstall).isAllowed, let ist = FileStat.of(p), !ist.isSymlink else {
                plan.refused.append(String(localized: "\(name): nie należy do tej aplikacji albo leży poza dozwolonymi miejscami")); continue
            }
            plan.items.append(AppDataItem(path: p, location: (loc.rel as NSString).lastPathComponent, association: assoc, risky: loc.risky, size: DiskUsage.measure(p).allocated))
        }
        return plan
    }

    public func preview(_ a: ToolArguments) async throws -> OperationPreview {
        let p = await plan(a)
        let name = ((p.app as NSString).lastPathComponent as NSString).deletingPathExtension
        if let why = p.appRefusal {
            return OperationPreview(title: String(localized: "Odinstalowanie \(name)"), purpose: String(localized: "Usunięcie aplikacji"), expectedEffect: String(localized: "Nic nie zostanie zmienione."),
                                    risk: .low, reversible: true, undoDescription: "—", affectedItems: [], estimatedBytes: 0, warnings: [why] + p.refused)
        }
        var appSize: UInt64 = 0
        if !p.app.isEmpty { appSize = DiskUsage.measure(p.app).allocated }
        let total = appSize + p.items.reduce(0) { $0 + $1.size }
        var warnings = p.refused
        if p.items.contains(where: { $0.risky }) { warnings.append(String(localized: "Wśród danych są Application Support lub kontener aplikacji – mogą zawierać Twoje dokumenty i ustawienia.")) }
        return OperationPreview(title: String(localized: "Odinstalowanie \(name)"), purpose: String(localized: "Usunięcie aplikacji i jej danych"),
                                expectedEffect: String(localized: "\(ByteFormat.string(total)) trafi do Kosza. Miejsce na dysku wróci dopiero po opróżnieniu Kosza w Finderze."),
                                risk: .medium, reversible: true,
                                undoDescription: String(localized: "W Finderze: Kosz → zaznacz element → Odłóż (Put Back). Nic nie jest usuwane na stałe."),
                                affectedItems: ([p.app] + p.items.map(\.path)).map { $0.replacingOccurrences(of: home, with: "~") }, estimatedBytes: total, warnings: warnings)
    }

    public func run(_ a: ToolArguments) async throws -> ToolResult {
        try ExecutionGuard.require(.uninstallToTrash)
        let p = await plan(a)                                                               // wszystkie warunki sprawdzane na nowo przy wykonaniu
        if let why = p.appRefusal { return ToolResult(summary: String(localized: "Nie odinstalowano: \(why)."), data: .object(["refused": .string(why)]), success: false) }
        var moved: [JSONValue] = [], failed: [JSONValue] = []
        let appBytes = DiskUsage.measure(p.app).allocated
        do {
            let dest = try trash.moveToTrash(p.app)
            moved.append(.object(["path": .string(p.app), "trash_path": .string(dest ?? ""), "bytes": .number(Double(appBytes))]))
        } catch {
            // Aplikacja zostaje ⇒ jej danych też nie ruszamy (np. aplikacja z App Store należy do systemu i wymaga uprawnień administratora).
            let why = String(localized: "Nie udało się przenieść aplikacji do Kosza (\(error.localizedDescription)). Jej danych nie ruszono – usuń aplikację w Finderze.")
            return ToolResult(summary: why, data: .object(["failed": .array([.object(["path": .string(p.app), "reason": .string(error.localizedDescription)])])]), success: false)
        }
        for it in p.items {
            guard ExecutionGuard.allows(.uninstallToTrash) else { failed.append(.object(["path": .string(it.path), "reason": .string(String(localized: "tryb Edycja wygasł – nic nie ruszono"))])); continue }
            guard let st = FileStat.of(it.path), !st.isSymlink else { failed.append(.object(["path": .string(it.path), "reason": .string(String(localized: "zmieniony tuż przed przeniesieniem – nic nie ruszono"))])); continue }
            do {
                let dest = try trash.moveToTrash(it.path)
                moved.append(.object(["path": .string(it.path), "trash_path": .string(dest ?? ""), "bytes": .number(Double(it.size))]))
            } catch { failed.append(.object(["path": .string(it.path), "reason": .string(error.localizedDescription)])) }
        }
        let bytes = appBytes + p.items.reduce(0) { $0 + $1.size }
        let name = ((p.app as NSString).lastPathComponent as NSString).deletingPathExtension
        let summary = failed.isEmpty
            ? String(localized: "Odinstalowano \(name) – aplikacja i \(PolishPlural.counted(p.items.count, one: "element", few: "elementy", many: "elementów")) danych w Koszu (\(ByteFormat.string(bytes))). Przywrócisz je w Finderze.")
            : String(localized: "Odinstalowano \(name) częściowo – \(failed.count) z \(p.items.count) elementów danych zostało na miejscu.")
        return ToolResult(summary: summary, data: .object(["moved": .array(moved), "failed": .array(failed), "partial": .bool(!failed.isEmpty)]), success: failed.isEmpty)
    }
}
