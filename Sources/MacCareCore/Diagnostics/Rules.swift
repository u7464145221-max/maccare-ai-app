import Foundation

public enum FindingCategory: String, Codable, Sendable, CaseIterable {
    case storage, memory, cpu, thermal, battery, security, startup, stability, apps, cleanup
    public var label: String {
        switch self {
        case .storage: return String(localized: "Dysk"); case .memory: return String(localized: "Pamięć"); case .cpu: return String(localized: "Procesor"); case .thermal: return String(localized: "Temperatura")
        case .battery: return String(localized: "Bateria"); case .security: return String(localized: "Bezpieczeństwo"); case .startup: return String(localized: "Autostart")
        case .stability: return String(localized: "Stabilność"); case .apps: return String(localized: "Aplikacje"); case .cleanup: return String(localized: "Porządki")
        }
    }
}

/// Akcja zaproponowana przez regułę – wskazuje narzędzie z rejestru i jego argumenty.
public struct SuggestedAction: Codable, Sendable, Hashable {
    public var tool: String
    public var arguments: [String: JSONValue]
    public var label: String
    public init(tool: String, arguments: [String: JSONValue] = [:], label: String) {
        self.tool = tool; self.arguments = arguments; self.label = label
    }
    public static func == (a: SuggestedAction, b: SuggestedAction) -> Bool { a.tool == b.tool && a.label == b.label && a.arguments == b.arguments }
    public func hash(into h: inout Hasher) { h.combine(tool); h.combine(label) }
}

/// Wykryty problem lub obserwacja. `certainty` jawnie mówi, czy to fakt, czy przypuszczenie.
public struct Finding: Codable, Sendable, Identifiable, Hashable {
    public var id: String              // ruleID + podmiot, stabilny między skanami
    public var ruleID: String
    public var category: FindingCategory
    public var title: String
    public var detail: String
    public var severity: Severity
    public var certainty: Certainty
    public var evidenceIDs: [String]
    public var actions: [SuggestedAction]
    public init(id: String, ruleID: String, category: FindingCategory, title: String, detail: String, severity: Severity,
                certainty: Certainty, evidenceIDs: [String], actions: [SuggestedAction] = []) {
        self.id = id; self.ruleID = ruleID; self.category = category; self.title = title; self.detail = detail
        self.severity = severity; self.certainty = certainty; self.evidenceIDs = evidenceIDs; self.actions = actions
    }
    public static func == (a: Finding, b: Finding) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Konfigurowalne progi. Wartości domyślne opisane w docs/METODOLOGIA.md.
public struct RuleThresholds: Codable, Sendable {
    public var diskFreeWarningFraction = 0.15
    public var diskFreeCriticalFraction = 0.05
    public var diskFreeCriticalBytes: UInt64 = 10_000_000_000
    public var swapWarningBytes: UInt64 = 4_000_000_000
    public var processCPUPercent = 80.0
    public var processCPUSustainSeconds = 120.0
    public var systemCPUPercent = 90.0
    public var idleAppMemoryBytes: UInt64 = 1_500_000_000
    public var batteryHealthWarning = 80.0
    public var batteryCyclesWarning = 1000
    public var crashRepeatCount = 3
    public var uptimeDaysInfo = 21.0
    public init() {}
}

/// Historia krótkoterminowa – potrzebna, by odróżnić chwilowy skok od trwałego obciążenia.
public struct MetricWindow: Sendable {
    public struct Point: Sendable { public var t: Date; public var value: Double }
    public private(set) var series: [String: [Point]] = [:]
    public var maxAge: TimeInterval
    public init(maxAge: TimeInterval = 900) { self.maxAge = maxAge }

    public mutating func record(_ key: String, _ value: Double, at t: Date) {
        var s = series[key, default: []]
        s.append(Point(t: t, value: value))
        s.removeAll { t.timeIntervalSince($0.t) > maxAge }
        series[key] = s
    }
    /// Jak długo (s) wartość nieprzerwanie była ≥ progu, licząc wstecz od ostatniej próbki.
    public func sustainedDuration(_ key: String, atLeast threshold: Double) -> TimeInterval {
        guard let s = series[key], let last = s.last, last.value >= threshold else { return 0 }
        var start = last.t
        for p in s.reversed() { if p.value >= threshold { start = p.t } else { break } }
        return last.t.timeIntervalSince(start)
    }
    public func values(_ key: String) -> [Double] { series[key]?.map { $0.value } ?? [] }
    public mutating func prune(keeping keys: Set<String>) { series = series.filter { keys.contains($0.key) || !$0.key.hasPrefix("app.cpu.") } }
}

public struct RuleContext: Sendable {
    public var thresholds: RuleThresholds
    public var window: MetricWindow
    public var ignoredApps: Set<String>
    public var protectedProcessNames: Set<String>
    /// Katalog domowy użytkownika (do rozpoznawania lokalnych narzędzi w autostarcie).
    public var homePath: String
    public init(thresholds: RuleThresholds = .init(), window: MetricWindow = .init(), ignoredApps: Set<String> = [],
                protectedProcessNames: Set<String> = ProcessGuard.protectedNames, homePath: String = NSHomeDirectory()) {
        self.thresholds = thresholds; self.window = window; self.ignoredApps = Set(ignoredApps.map { $0.lowercased() })
        self.protectedProcessNames = protectedProcessNames; self.homePath = homePath
    }
}

public enum ProcessGuard {
    /// Procesy, których MacCare nigdy nie proponuje zamykać.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer", "coreaudiod",
        "mds", "mds_stores", "mdworker", "mdworker_shared", "backupd", "softwareupdated", "MacCare AI", "MacCareApp", "maccare",
        "ControlCenter", "NotificationCenter", "cfprefsd", "trustd", "securityd", "opendirectoryd", "powerd", "syspolicyd"
    ]
    public static func canPropose(_ g: ProcessGroup, ctx: RuleContext) -> Bool {
        g.allCurrentUser && !ctx.protectedProcessNames.contains(g.name) && !ctx.ignoredApps.contains(g.name.lowercased())
            && !(g.bundlePath?.hasPrefix("/System/") ?? false)
            // Procesy systemowe Apple (także o nazwie ściętej do MAXCOMLEN, np. „com.apple.Virtualization.Virtua”) i pliki pod /System/.
            && !g.name.hasPrefix("com.apple.") && !(g.executablePath?.hasPrefix("/System/") ?? false)
    }
}

public protocol DiagnosticRule: Sendable {
    var id: String { get }
    func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding]
}

/// Silnik reguł: deterministyczny, bez AI. Każda reguła podaje dowody.
public struct RulesEngine: Sendable {
    public var rules: [any DiagnosticRule]
    public init(rules: [any DiagnosticRule] = RulesEngine.standardRules) { self.rules = rules }

    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        rules.flatMap { $0.evaluate(s, ctx) }
            .sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
    }

    public static let standardRules: [any DiagnosticRule] = [
        LowDiskRule(), LocalSnapshotsRule(), MemoryPressureRule(), SwapRule(), SustainedProcessCPURule(), SystemCPURule(), IdleMemoryHogRule(),
        ThermalRule(), BatteryHealthRule(), SSDHealthRule(), SecurityPostureRule(), ScanAccessRule(), SoftwareUpdatesRule(), StartupItemsRule(), CrashLoopRule(), ZombieRule(), UptimeRule()
    ]
}

// MARK: - Reguły

public struct LowDiskRule: DiagnosticRule {
    public let id = "disk.low"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let v = s.bootVolume, v.total > 0 else { return [] }
        let t = ctx.thresholds
        let critical = v.freeFraction < t.diskFreeCriticalFraction || v.availableImportant < t.diskFreeCriticalBytes
        guard critical || v.freeFraction < t.diskFreeWarningFraction else { return [] }
        var detail = String(localized: "Na dysku startowym zostało \(ByteFormat.string(v.availableImportant)) (\(Int(v.freeFraction * 100))%). ")
        detail += String(localized: "Przy małej ilości miejsca macOS ogranicza pamięć wirtualną i kopie lokalne, co może spowalniać system.")
        if v.purgeable > 1_000_000_000 { detail += String(localized: " Z tego \(ByteFormat.string(v.purgeable)) system może zwolnić sam (purgeable).") }
        return [Finding(id: id, ruleID: id, category: .storage, title: String(localized: "Mało wolnego miejsca na dysku"), detail: detail,
                        severity: critical ? .critical : .warning, certainty: .confirmed, evidenceIDs: ["disk.free"] + (v.purgeable > 0 ? ["disk.purgeable"] : []),
                        actions: [SuggestedAction(tool: "scan_cleanup", label: String(localized: "Znajdź dane do bezpiecznego usunięcia")),
                                  SuggestedAction(tool: "find_large_files", label: String(localized: "Pokaż największe pliki"))])]
    }
}

public struct LocalSnapshotsRule: DiagnosticRule {
    public let id = "disk.snapshots"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let snaps = s.localSnapshots, !snaps.isEmpty, let v = s.bootVolume, v.purgeable >= 5_000_000_000 else { return [] }
        return [Finding(id: id, ruleID: id, category: .storage, title: String(localized: "Migawki Time Machine trzymają miejsce, które system zwolni sam"),
                        detail: String(localized: "Na dysku jest \(snaps.count) lokalnych migawek, a \(ByteFormat.string(v.purgeable)) liczy się jako „do odzyskania przez system”. Usunięcie plików objętych migawką nie zwiększy wolnego miejsca, dopóki migawki nie wygasną (zwykle do 24 godz.) – dlatego sprzątanie pamięci podręcznej bywa tu mało skuteczne. macOS zwalnia je sam, gdy brakuje miejsca."),
                        severity: .info, certainty: .probable, evidenceIDs: ["tm.snapshots", "disk.purgeable"])]
    }
}

public struct MemoryPressureRule: DiagnosticRule {
    public let id = "mem.pressure"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let m = s.memory, m.pressure != .normal else { return [] }
        let top = s.appGroups().filter { ProcessGuard.canPropose($0, ctx: ctx) }.max { $0.memory < $1.memory }
        var detail = String(localized: "macOS zgłasza \(m.pressure.label) ciśnienie pamięci – system kompresuje pamięć i zrzuca ją na dysk.")
        var ev = ["mem.pressure", "mem.used", "mem.compressed", "mem.swap"]
        var actions: [SuggestedAction] = []
        if let top {
            detail += String(localized: " Najwięcej pamięci zajmuje \(top.name) (\(ByteFormat.string(top.memory))).")
            ev.append("proc.mem.\(top.name)")
            actions.append(SuggestedAction(tool: "quit_app", arguments: ["name": .string(top.name)], label: String(localized: "Zamknij \(top.name)")))
        }
        return [Finding(id: id, ruleID: id, category: .memory, title: String(localized: "Brakuje pamięci RAM"), detail: detail,
                        severity: m.pressure == .critical ? .critical : .warning, certainty: .confirmed, evidenceIDs: ev, actions: actions)]
    }
}

public struct SwapRule: DiagnosticRule {
    public let id = "mem.swap"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let m = s.memory, m.swapUsed >= ctx.thresholds.swapWarningBytes, m.pressure == .normal else { return [] }
        return [Finding(id: id, ruleID: id, category: .memory, title: String(localized: "Duże użycie pliku wymiany (swap)"),
                        detail: String(localized: "Swap zajmuje \(ByteFormat.string(m.swapUsed)). Obecnie ciśnienie pamięci jest normalne, więc to ślad wcześniejszego niedoboru RAM, a nie bieżący problem. Swap zwolni się po zamknięciu dużych aplikacji lub restarcie."),
                        severity: .info, certainty: .confirmed, evidenceIDs: ["mem.swap", "mem.pressure"])]
    }
}

public struct SustainedProcessCPURule: DiagnosticRule {
    public let id = "cpu.process"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        let t = ctx.thresholds
        return s.appGroups().filter { $0.cpuPercent >= t.processCPUPercent && ProcessGuard.canPropose($0, ctx: ctx) }.compactMap { g in
            let dur = ctx.window.sustainedDuration("app.cpu.\(g.key)", atLeast: t.processCPUPercent)
            let sustained = dur >= t.processCPUSustainSeconds
            return Finding(id: "\(id).\(g.name)", ruleID: id, category: .cpu,
                           title: String(localized: "\(g.name) obciąża procesor (\(Int(g.cpuPercent))%)"),
                           detail: sustained ? String(localized: "Obciążenie utrzymuje się od \(Int(dur)) s – to nie jest chwilowy skok.") : String(localized: "Pojedynczy pomiar – może to być chwilowa praca (np. indeksowanie, eksport). Obserwuję dalej."),
                           severity: sustained ? .warning : .info, certainty: sustained ? .confirmed : .probable,
                           evidenceIDs: ["proc.cpu.\(g.name)", "cpu.total"],
                           actions: sustained ? [SuggestedAction(tool: "quit_app", arguments: ["name": .string(g.name)], label: String(localized: "Zamknij \(g.name)"))] : [])
        }
    }
}

public struct SystemCPURule: DiagnosticRule {
    public let id = "cpu.system"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let c = s.cpu, c.totalPercent >= ctx.thresholds.systemCPUPercent else { return [] }
        let dur = ctx.window.sustainedDuration("cpu.total", atLeast: ctx.thresholds.systemCPUPercent)
        guard dur >= 60 else { return [] }
        var out = [Finding(id: id, ruleID: id, category: .cpu, title: String(localized: "Procesor przeciążony od \(Int(dur)) s"),
                           detail: String(localized: "Łączne obciążenie wynosi \(Int(c.totalPercent))%. Sprawdź listę procesów – reguła nie wskazuje jednej przyczyny, jeśli żaden proces nie przekracza progu."),
                           severity: .warning, certainty: .confirmed, evidenceIDs: ["cpu.total", "cpu.load"])]
        // Gdy procesy użytkownika tłumaczą mniej niż połowę obciążenia, reszta pochodzi z procesów, których bez uprawnień nie widać.
        // Nie zgadujemy nazwy – to wniosek tylko „prawdopodobny”.
        let userCores = s.processes.filter { $0.isCurrentUser && !$0.isZombie }.reduce(0.0) { $0 + $1.cpuPercent } / 100
        let totalCores = c.totalPercent / 100 * Double(max(c.coreCount, 1))
        if let n = s.unmeasuredProcessCount, n > 0, totalCores > 0, userCores < totalCores * 0.5 {
            out.append(Finding(id: "\(id).hidden", ruleID: id, category: .cpu, title: String(localized: "Główne obciążenie pochodzi z procesów systemowych"),
                               detail: String(localized: "Procesy użytkownika wykorzystują ok. \(String(format: "%.1f", userCores)) z \(String(format: "%.1f", totalCores)) zajętych rdzeni. Reszta to najpewniej procesy systemowe (\(n) niemierzalnych bez uprawnień) – ich nazw nie da się ustalić bez podwyższonych uprawnień, więc ich nie zgaduję."),
                               severity: .info, certainty: .probable, evidenceIDs: ["cpu.total", "proc.unmeasured"]))
        }
        return out
    }
}

public struct IdleMemoryHogRule: DiagnosticRule {
    public let id = "mem.idle_app"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let m = s.memory, m.pressure != .normal else { return [] }   // tylko gdy RAM faktycznie jest potrzebny
        return s.appGroups().filter { $0.bundlePath != nil && $0.cpuPercent < 0.5 && $0.memory >= ctx.thresholds.idleAppMemoryBytes && ProcessGuard.canPropose($0, ctx: ctx) }
            .prefix(2).map { g in
                Finding(id: "\(id).\(g.name)", ruleID: id, category: .memory, title: String(localized: "\(g.name) bezczynnie zajmuje \(ByteFormat.string(g.memory))"),
                        detail: String(localized: "Aplikacja nie używa procesora, a przy podwyższonym ciśnieniu pamięci jej zamknięcie realnie odciąży system."),
                        severity: .info, certainty: .confirmed, evidenceIDs: ["proc.mem.\(g.name)", "mem.pressure"],
                        actions: [SuggestedAction(tool: "quit_app", arguments: ["name": .string(g.name)], label: String(localized: "Zamknij \(g.name)"))])
            }
    }
}

public struct ThermalRule: DiagnosticRule {
    public let id = "thermal"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let th = s.thermal, th.rawValue >= ThermalLevel.serious.rawValue else { return [] }
        return [Finding(id: id, ruleID: id, category: .thermal, title: String(localized: "System ogranicza wydajność z powodu temperatury"),
                        detail: String(localized: "Stan termiczny: \(th.label). macOS obniża taktowanie, żeby się schłodzić – to wyjaśnia spadek wydajności w tym momencie."),
                        severity: th == .critical ? .critical : .warning, certainty: .confirmed, evidenceIDs: ["thermal.state", "cpu.total"])]
    }
}

public struct BatteryHealthRule: DiagnosticRule {
    public let id = "battery.health"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let b = s.battery else { return [] }
        var out: [Finding] = []
        if let cond = b.condition, cond.lowercased().contains("service") || cond.lowercased().contains("poor") {
            out.append(Finding(id: "\(id).condition", ruleID: id, category: .battery, title: String(localized: "System zaleca serwis baterii"),
                               detail: String(localized: "macOS raportuje stan: \(cond)."), severity: .warning, certainty: .confirmed, evidenceIDs: ["bat.condition"]))
        }
        if let h = b.healthPercent, h < ctx.thresholds.batteryHealthWarning {
            out.append(Finding(id: "\(id).capacity", ruleID: id, category: .battery, title: String(localized: "Pojemność baterii spadła do \(Int(h))%"),
                               detail: String(localized: "Maksymalna pojemność względem projektowej. Krótszy czas pracy na baterii jest tu oczekiwany."),
                               severity: .info, certainty: .confirmed, evidenceIDs: ["bat.health"] + (b.cycleCount != nil ? ["bat.cycles"] : [])))
        }
        return out
    }
}

/// 18.10 (decyzja właściciela): kondycja dysku SSD z dziennika SMART – ostrzeżenie sprzętowe, zapas poniżej progu, błędy nośnika, wysokie zużycie.
public struct SSDHealthRule: DiagnosticRule {
    public let id = "storage.ssd"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let d = s.ssd else { return [] }
        var out: [Finding] = []
        if d.criticalWarning != 0 || d.availableSpare < d.availableSpareThreshold {
            out.append(Finding(id: "\(id).critical", ruleID: id, category: .storage, title: String(localized: "Dysk SSD zgłasza ostrzeżenie sprzętowe"),
                               detail: String(localized: "Zrób kopię zapasową (Time Machine) i skontaktuj się z serwisem Apple. Zapas komórek: \(d.availableSpare)% (próg \(d.availableSpareThreshold)%)."),
                               severity: .critical, certainty: .confirmed, evidenceIDs: ["ssd.warning", "ssd.spare"]))
        }
        if d.mediaErrors > 0 {
            out.append(Finding(id: "\(id).errors", ruleID: id, category: .storage, title: String(localized: "Dysk SSD zarejestrował błędy nośnika (\(d.mediaErrors))"),
                               detail: String(localized: "Pojedyncze błędy nie muszą oznaczać awarii, ale warto mieć aktualną kopię zapasową i obserwować, czy liczba rośnie."),
                               severity: .warning, certainty: .confirmed, evidenceIDs: ["ssd.errors"]))
        }
        if d.percentUsed >= 80 {
            out.append(Finding(id: "\(id).wear", ruleID: id, category: .storage, title: String(localized: "Dysk SSD zużyty w \(d.percentUsed)%"),
                               detail: String(localized: "To szacunek producenta dotyczący liczby zapisów. Dysk może działać dłużej, ale kopia zapasowa jest tu szczególnie ważna."),
                               severity: d.percentUsed >= 100 ? .warning : .info, certainty: .confirmed, evidenceIDs: ["ssd.used", "ssd.written"]))
        }
        return out
    }
}

public struct SecurityPostureRule: DiagnosticRule {
    public let id = "security.posture"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let p = s.security else { return [] }
        var out: [Finding] = []
        func f(_ key: String, _ title: String, _ detail: String, _ sev: Severity, _ ev: String) {
            out.append(Finding(id: "\(id).\(key)", ruleID: id, category: .security, title: title, detail: detail, severity: sev,
                               certainty: .confirmed, evidenceIDs: [ev], actions: [SuggestedAction(tool: "open_security_settings", arguments: ["pane": .string(key)], label: String(localized: "Otwórz ustawienia"))]))
        }
        if p.sip == .disabled { f("sip", String(localized: "Ochrona integralności systemu (SIP) jest wyłączona"), String(localized: "SIP chroni pliki systemowe przed modyfikacją. Włączenie wymaga trybu Recovery (csrutil enable) – MacCare nie robi tego automatycznie."), .critical, "sec.sip") }
        if p.gatekeeper == .disabled { f("gatekeeper", String(localized: "Gatekeeper jest wyłączony"), String(localized: "Uruchamiane mogą być aplikacje bez weryfikacji pochodzenia."), .critical, "sec.gatekeeper") }
        if p.fileVault == .disabled { f("filevault", String(localized: "FileVault jest wyłączony"), String(localized: "Dane na dysku nie są szyfrowane – po kradzieży Maca można je odczytać."), .warning, "sec.filevault") }
        if p.firewall == .disabled { f("firewall", String(localized: "Zapora aplikacji jest wyłączona"), String(localized: "Usługi uruchomione na Macu mogą przyjmować połączenia z sieci."), .info, "sec.firewall") }
        return out
    }
}

/// P2-10 / AUD-SCEN-2: aktualizacje Apple oczekujące według ostatniego sprawdzenia przez macOS oraz zbyt dawne sprawdzenie.
public struct SoftwareUpdatesRule: DiagnosticRule {
    public let id = "updates.available"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let u = s.updates else { return [] }
        var out: [Finding] = []
        let action = [SuggestedAction(tool: "open_security_settings", arguments: ["pane": .string("updates")], label: String(localized: "Otwórz Uaktualnienia"))]
        if !u.pending.isEmpty {
            let system = u.pending.contains { $0.isMacOS }
            let checked = u.lastCheck.map { String(localized: " (stan z \($0.formatted(date: .abbreviated, time: .omitted)))") } ?? ""
            let systemNote = system ? String(localized: " – aktualizacja systemu jest szczególnie ważna") : ""
            out.append(Finding(id: id, ruleID: id, category: .security,
                               title: String(localized: "Dostępne aktualizacje: \(u.pending.map(\.title).joined(separator: ", "))"),
                               detail: String(localized: "macOS zgłosił oczekujące aktualizacje\(checked). Aktualizacje usuwają luki bezpieczeństwa\(systemNote). MacCare ich nie instaluje: zrób to w Ustawieniach systemowych → Ogólne → Uaktualnienia."),
                               severity: system ? .warning : .info, certainty: .confirmed, evidenceIDs: ["updates.pending"] + (u.lastCheck != nil ? ["updates.lastCheck"] : []), actions: action))
        }
        if let d = u.lastCheck, s.takenAt.timeIntervalSince(d) > 30 * 86400 {
            out.append(Finding(id: "updates.stale", ruleID: id, category: .security, title: String(localized: "Aktualizacji nie sprawdzano od ponad 30 dni"),
                               detail: String(localized: "Ostatnie udane sprawdzenie: \(d.formatted(date: .abbreviated, time: .omitted)). Lista oczekujących aktualizacji może być nieaktualna."),
                               severity: .info, certainty: .confirmed, evidenceIDs: ["updates.lastCheck"], actions: action))
        }
        return out
    }
}

/// P1-4 (AUD-SCEN-1): brak Pełnego dostępu do dysku to nie wada zabezpieczeń (nie obniża oceny), ale OGRANICZA wyniki skanów – mówimy o tym wprost.
public struct ScanAccessRule: DiagnosticRule {
    public let id = "scan.fda.missing"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard s.security?.fullDiskAccessGranted == false else { return [] }
        return [Finding(id: id, ruleID: id, category: .storage, title: String(localized: "Skany mogą być niepełne: brak Pełnego dostępu do dysku"),
                        detail: String(localized: "Bez tego uprawnienia macOS nie pozwala zajrzeć do części folderów (np. Poczta, Safari, kontenery innych aplikacji). Ich rozmiary nie są liczone na mapie dysku ani w porządkach – foldery bez dostępu są oznaczane jako „skan niepełny”. Uprawnienie jest opcjonalne i nie wpływa na ocenę zdrowia."),
                        severity: .info, certainty: .confirmed, evidenceIDs: ["sec.fda"],
                        actions: [SuggestedAction(tool: "open_security_settings", arguments: ["pane": .string("fda")], label: String(localized: "Otwórz ustawienia"))])]
    }
}

public struct StartupItemsRule: DiagnosticRule {
    public let id = "startup.items"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let items = s.startupItems else { return [] }
        var out: [Finding] = []
        var local: [StartupItem] = []
        for i in items where !i.isApple {
            if i.programMissing {
                out.append(Finding(id: "\(id).orphan.\(i.label)", ruleID: id, category: .startup, title: String(localized: "Osierocony element autostartu: \(i.label)"),
                                   detail: String(localized: "Plik konfiguracyjny wskazuje na nieistniejący program (\(i.program ?? "?")). Najczęściej to pozostałość po odinstalowanej aplikacji."),
                                   severity: .info, certainty: .confirmed, evidenceIDs: ["startup.item.\(i.label)"],
                                   actions: i.scope == .userAgent ? [SuggestedAction(tool: "disable_launch_agent", arguments: ["label": .string(i.label)], label: String(localized: "Wyłącz i przenieś do kwarantanny"))] : []))
            } else if i.hasUntrustedSignature {
                // `.developerIDNotNotarized` nie wchodzi tu celowo (starsze, legalne narzędzia – bez osobnego ustalenia).
                if i.isFromLocalTools(home: ctx.homePath) { local.append(i); continue }
                out.append(Finding(id: "\(id).unsigned.\(i.label)", ruleID: id, category: .security, title: String(localized: "Autostart bez zaufanego podpisu: \(i.label)"),
                                   detail: String(localized: "Program \(i.program ?? "?") uruchamiany automatycznie ma status: \(i.signature.label). To nie oznacza złośliwości, ale warto sprawdzić pochodzenie."),
                                   severity: i.keepAlive ? .warning : .info, certainty: .confirmed, evidenceIDs: ["startup.item.\(i.label)"]))
            }
        }
        if !local.isEmpty {
            let labels = local.map { $0.label }.sorted()
            out.append(Finding(id: "\(id).local_unsigned", ruleID: id, category: .startup,
                               title: String(localized: "\(PolishPlural.counted(local.count, one: "element", few: "elementy", many: "elementów")) autostartu z lokalnych narzędzi (np. środowiska Python, Homebrew)"),
                               detail: String(localized: "Uruchamiane automatycznie programy z katalogu domowego lub Homebrew nie mają zaufanego podpisu – to typowe dla własnych skryptów i środowisk deweloperskich, a nie dla złośliwego oprogramowania. Pierwsze: \(labels.prefix(10).joined(separator: ", "))\(labels.count > 10 ? " …" : "")."),
                               severity: .info, certainty: .confirmed, evidenceIDs: ["startup.local_unsigned"]))
        }
        return out
    }
}

public struct CrashLoopRule: DiagnosticRule {
    public let id = "stability.crashes"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        (s.crashes ?? []).filter { $0.count >= ctx.thresholds.crashRepeatCount }.map { c in
            Finding(id: "\(id).\(c.process)", ruleID: id, category: .stability, title: String(localized: "\(c.process) zgłasza powtarzające się problemy (\(c.count)×)"),
                    detail: String(localized: "Typy zdarzeń: \(c.kinds.joined(separator: ", ")). Ostatnie: \(c.lastDate.formatted(date: .abbreviated, time: .shortened)). Przyczynę może wyjaśnić analiza raportu – poproś asystenta."),
                    severity: .warning, certainty: .confirmed, evidenceIDs: ["crash.\(c.process)"],
                    actions: [SuggestedAction(tool: "read_crash_summary", arguments: ["process": .string(c.process)], label: String(localized: "Przeanalizuj raporty"))])
        }
    }
}

public struct ZombieRule: DiagnosticRule {
    public let id = "proc.zombies"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        let z = s.processes.filter { $0.isZombie }
        guard z.count >= 5 else { return [] }
        return [Finding(id: id, ruleID: id, category: .stability, title: String(localized: "\(z.count) procesów zombie"),
                        detail: String(localized: "Procesy zakończone, ale nieodebrane przez proces nadrzędny. Nie zużywają CPU ani RAM; znikną po zamknięciu procesu nadrzędnego lub restarcie."),
                        severity: .info, certainty: .confirmed, evidenceIDs: [])]
    }
}

public struct UptimeRule: DiagnosticRule {
    public let id = "sys.uptime"
    public init() {}
    public func evaluate(_ s: SystemSnapshot, _ ctx: RuleContext) -> [Finding] {
        guard let u = s.uptimeSeconds, u / 86400 >= ctx.thresholds.uptimeDaysInfo else { return [] }
        return [Finding(id: id, ruleID: id, category: .stability, title: String(localized: "Mac działa bez restartu od \(Int(u / 86400)) dni"),
                        detail: String(localized: "To samo w sobie nie jest błędem. Restart instaluje oczekujące poprawki i zwalnia swap – rozważ go, jeśli masz inne objawy."),
                        severity: .info, certainty: .confirmed, evidenceIDs: ["sys.uptime"])]
    }
}
