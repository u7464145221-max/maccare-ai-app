#if os(macOS)
import AppKit
import MacCareCore

/// Implementacja `DiagnosticsProvider` na macOS: pętla próbkowania (szybka co 2 s, wolna co 30 s, bogata – autostart/zabezpieczenia/
/// awarie – co 5 min), okno metryk dla reguł, zapis próbek do `HistoryStore` co 60 s.
public actor MacDiagnosticsProvider: DiagnosticsProvider {
    public struct Settings: Sendable {
        public var home: String
        public var tempDir: String
        public var ignoredApps: Set<String>
        public var thresholds: RuleThresholds
        public var fastInterval: TimeInterval
        /// Okres próbkowania, gdy okno aplikacji nie jest widoczne (AUD-PERF-1): nic nie jest wtedy oglądane, więc nie ma po co liczyć co 2 s.
        public var backgroundInterval: TimeInterval = 30
        public var slowInterval: TimeInterval
        public var enrichInterval: TimeInterval
        public var historyInterval: TimeInterval
        public var largeFilesTimeout: TimeInterval
        public init(home: String = NSHomeDirectory(), tempDir: String = NSTemporaryDirectory(), ignoredApps: Set<String> = [],
                    thresholds: RuleThresholds = .init(), fastInterval: TimeInterval = 2, slowInterval: TimeInterval = 30,
                    enrichInterval: TimeInterval = 300, historyInterval: TimeInterval = 60, largeFilesTimeout: TimeInterval = 90) {
            self.home = home; self.tempDir = tempDir; self.ignoredApps = ignoredApps; self.thresholds = thresholds
            self.fastInterval = fastInterval; self.slowInterval = slowInterval; self.enrichInterval = enrichInterval
            self.historyInterval = historyInterval; self.largeFilesTimeout = largeFilesTimeout
        }
    }

    private let collector: SystemCollector
    private let history: HistoryStore?
    private let clones: CloneInfoProvider
    private var settings: Settings
    private var window = MetricWindow()
    private var latest: SystemSnapshot?
    private var startup: [StartupItem]?
    private var security: SecurityPosture?
    private var crashes: [CrashReportSummary]?
    private var ssd: SSDHealth?
    private var localSnapshots: [Date]?
    private var updates: SoftwareUpdateStatus?
    private var loop: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?
    private var lastSlow = Date.distantPast
    private var lastEnrich = Date.distantPast
    private var lastHistory = Date.distantPast
    private var lastCompaction = Date.distantPast

    public init(history: HistoryStore? = nil, settings: Settings = .init(), collector: SystemCollector = SystemCollector(),
                clones: CloneInfoProvider = APFSCloneInfo()) {
        self.history = history; self.settings = settings; self.collector = collector; self.clones = clones
    }

    // MARK: Pętla próbkowania
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = await self.sampleInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
            }
        }
    }

    private var background = false
    /// Okres następnego próbkowania: szybki, gdy okno widać; `backgroundInterval` (nie krótszy niż szybki), gdy jest ukryte.
    public var sampleInterval: TimeInterval { background ? max(settings.fastInterval, settings.backgroundInterval) : settings.fastInterval }
    public var isInBackground: Bool { background }

    /// Wywoływane przy zmianie widoczności okna. Powrót na pierwszy plan budzi pętlę od razu (nowy pomiar zamiast czekania do 30 s).
    /// Czy pora na wzbogacenie: co `interval` przy widocznym oknie, co najmniej 30 min w tle.
    static func enrichmentDue(lastEnrich: Date, now: Date, background: Bool, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastEnrich) >= (background ? max(interval, 1800) : interval)
    }

    public func setBackground(_ on: Bool) {
        guard on != background else { return }
        background = on
        if !on, loop != nil { stop(); start() }
    }

    public func stop() { loop?.cancel(); loop = nil }
    public var isRunning: Bool { loop != nil }

    public func updateSettings(_ s: Settings) { settings = s }
    public func setIgnoredApps(_ apps: Set<String>) { settings.ignoredApps = apps }

    func tick(now: Date = Date()) async {
        let slow = latest == nil || now.timeIntervalSince(lastSlow) >= settings.slowInterval
        var snap = await collector.snapshot(refreshSlow: slow)
        if slow { lastSlow = now }
        // Wzbogacenie (autostart + podpisy, zabezpieczenia, awarie) trwa sekundy – działa w tle i NIE blokuje szybkiej pętli.
        // Audyt 2 (4.7): przy ukrytym oknie wzbogacenie (ok. 60 procesów launchctl, polecenia zabezpieczeń, tmutil) co 30 min zamiast co 5 –
        // powiadomienia i pasek menu nie potrzebują świeższych danych o autostarcie; po pokazaniu okna dane odświeżają się jak dotąd.
        if enrichTask == nil, latest == nil || Self.enrichmentDue(lastEnrich: lastEnrich, now: now, background: background, interval: settings.enrichInterval) {
            lastEnrich = now
            // Audyt 3: pełne wzbogacenie (stan załadowania każdego elementu autostartu – osobny `launchctl` na element, `lsof`, `tmutil`)
            // najwyżej co 30 min; między nimi lekkie co 5 min (zabezpieczenia, podpisy z pamięci, awarie, SMART) z poprzednimi wartościami ciężkich części.
            let full = latest == nil || now.timeIntervalSince(lastFullEnrich) >= Self.fullEnrichInterval
            if full { lastFullEnrich = now }
            enrichTask = Task { [weak self] in await self?.runEnrichment(full: full) }
        }
        snap.startupItems = startup; snap.security = security; snap.crashes = crashes; snap.localSnapshots = localSnapshots; snap.updates = updates; snap.ssd = ssd
        latest = snap
        updateWindow(snap, at: now)
        if history != nil, now.timeIntervalSince(lastHistory) >= settings.historyInterval {
            recordHistory(snap, at: now)
            lastHistory = now
        }
    }

    static let fullEnrichInterval: TimeInterval = 1800
    /// Testy: czekanie na trwające wzbogacenie.
    func awaitEnrichment() async { await enrichTask?.value }
    private var lastFullEnrich = Date.distantPast
    /// Liczba pełnych i lekkich wzbogaceń (testy).
    private(set) var enrichmentRuns: (full: Int, light: Int) = (0, 0)

    private func runEnrichment(full: Bool = true) async {
        let home = settings.home
        if full { enrichmentRuns.full += 1 } else { enrichmentRuns.light += 1 }
        let previousStartup = startup, previousSecurity = security, previousSnaps = localSnapshots
        // Audyt 2 (4.3): kolektory są niezależne – razem, nie po kolei (autostart ok. 3,1 s, tmutil ok. 2,7 s, zabezpieczenia 0,5 s ⇒ czeka się na najdłuższy).
        async let s = StartupCollector(home: home).collect(checkSignatures: true, checkLoaded: full)
        async let sec = SecurityCollector().collect(ports: full)
        async let cr = Task.detached(priority: .utility) { () -> [CrashReportSummary]? in
            let c = CrashReportCollector(directory: home + "/Library/Logs/DiagnosticReports", home: home)
            return c.directoryUnreadable() ? nil : c.summaries()                           // nieczytelny katalog = nieznane, nie „0 awarii”
        }.value
        async let snaps: [Date]? = full ? LocalSnapshotCollector.collect() : previousSnaps
        async let upd = Task.detached(priority: .utility) { SoftwareUpdateStatus.read() }.value       // P2-10: tylko odczyt plistu, bez sieci
        async let disk = Task.detached(priority: .utility) { SSDHealthCollector.read() }.value        // 18.10: SMART NVMe, tylko odczyt
        var (rs, rsec, rcr, rsnaps, rupd, rssd) = await (s, sec, cr, snaps, upd, disk)
        if !full {                                                                        // lekkie: stan załadowania i porty z ostatniego pełnego odczytu
            let loaded = Dictionary((previousStartup ?? []).map { ($0.label, $0.isLoaded) }, uniquingKeysWith: { a, _ in a })
            rs = rs.map { var i = $0; i.isLoaded = loaded[i.label] ?? nil; return i }
            if let p = previousSecurity { rsec.listeningExternalPorts = p.listeningExternalPorts; rsec.portsRead = p.portsRead }
        }
        startup = rs; security = rsec; crashes = rcr; localSnapshots = rsnaps; updates = rupd; ssd = rssd
        enrichTask = nil
    }

    private func updateWindow(_ s: SystemSnapshot, at t: Date) {
        if let c = s.cpu { window.record("cpu.total", c.totalPercent, at: t) }
        let groups = s.appGroups()
        for g in groups { window.record("app.cpu.\(g.key)", g.cpuPercent, at: t) }
        window.prune(keeping: Set(groups.map { "app.cpu.\($0.key)" }))
    }

    /// Nazwy szeregów zapisywanych do `HistoryStore` (używa ich wykres historii w aplikacji).
    static func historySamples(_ s: SystemSnapshot) -> [String: Double] {
        var v: [String: Double] = [:]
        if let c = s.cpu { v["cpu.total"] = c.totalPercent }
        if let m = s.memory {
            v["mem.used"] = Double(m.used); v["mem.swap"] = Double(m.swapUsed); v["mem.compressed"] = Double(m.compressed)
            v["mem.pressure"] = m.pressure == .normal ? 0 : (m.pressure == .warning ? 1 : 2)
        }
        if let d = s.bootVolume { v["disk.free"] = Double(d.availableImportant) }
        if let io = s.diskIO {
            v["disk.io"] = io.readBytesPerSec + io.writeBytesPerSec
            if let l = io.avgLatencyMs { v["disk.latency"] = l }
        }
        if let b = s.battery { v["bat.percent"] = Double(b.percent) }
        if let t = s.thermal { v["thermal.state"] = Double(t.rawValue) }
        return v
    }

    private func recordHistory(_ s: SystemSnapshot, at t: Date) {
        history?.recordSamples(Self.historySamples(s), at: t)
        if t.timeIntervalSince(lastCompaction) >= 6 * 3600 { history?.compactSamples(now: t); history?.pruneOld(now: t); lastCompaction = t }   // audyt 2 (4.14): retencja
    }

    /// Dla testów: bieżące okno metryk.
    func currentWindow() -> MetricWindow { window }

    // MARK: DiagnosticsProvider
    public func snapshot() async -> SystemSnapshot {
        if latest == nil || loop == nil {
            await tick()
            // Świeży kolektor nie ma jeszcze interwału do liczenia delt (CPU = nil) – krótko czekamy i próbkujemy ponownie,
            // żeby reguły i dowody (np. cpu.total) nie odwoływały się do nieistniejącego pomiaru.
            if latest?.cpu == nil {
                try? await Task.sleep(nanoseconds: 350_000_000)   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
                await tick()
            }
        }
        // Pierwsze wywołanie czeka na pierwsze wzbogacenie; kolejne zwracają to, co jest w pamięci podręcznej.
        if security == nil, let t = enrichTask { await t.value }
        var s = latest!
        s.startupItems = startup; s.security = security; s.crashes = crashes; s.localSnapshots = localSnapshots
        return s
    }

    private func ruleContext() -> RuleContext {
        RuleContext(thresholds: settings.thresholds, window: window, ignoredApps: settings.ignoredApps, homePath: settings.home)
    }

    /// Wymusza odświeżenie danych „bogatych” (autostart + podpisy, zabezpieczenia, awarie, migawki) i czeka na wynik – dla ręcznego skanu Ochrony.
    public func refreshEnrichmentNow() async {
        if let t = enrichTask { await t.value }
        lastFullEnrich = Date()
        enrichTask = Task { [weak self] in await self?.runEnrichment(full: true) }; await enrichTask?.value   // ręczny skan – zawsze pełny odczyt
        if var l = latest { l.startupItems = startup; l.security = security; l.crashes = crashes; l.localSnapshots = localSnapshots; l.updates = updates; l.ssd = ssd; latest = l }
        lastEnrich = Date()
    }

    /// Dowody zgodne z kontekstem reguł (progi, ignorowane aplikacje, katalog domowy) – dla panelu i asystenta.
    public func evidence() async -> [Evidence] {
        let s = await snapshot()
        return s.evidence(context: ruleContext())
    }

    public func findings() async -> [Finding] {
        let s = await snapshot()
        return RulesEngine().evaluate(s, ruleContext())
    }

    public func cleanupScan(categories: Set<CleanupCategory>?) async -> CleanupScanResult {
        await cleanupScan(categories: categories, recordInHistory: true)
    }

    public func verificationScan() async -> CleanupScanResult { await cleanupScan(categories: nil, recordInHistory: false) }

    /// `recordInHistory: false` – wywołujący (np. Smart Scan) zapisuje własny wiersz skanu, z oceną zdrowia.
    /// `cancel`: przerwanie z interfejsu (P2-4) – wynik ma wtedy `cancelled == true` i nie jest zapisywany w historii jako pełny skan.
    public func cleanupScan(categories: Set<CleanupCategory>?, recordInHistory: Bool, cancel: CancelFlag? = nil) async -> CleanupScanResult {
        let running = await RunningApps.all()                                             // aplikacje z oknem + właściciele procesów pomocniczych i w tle
        let tools = await Task.detached(priority: .utility) { RunningApps.runningToolTokens() }.value   // P2-3: pracujące narzędzia (npm, cargo, xcodebuild…)
        let scanner = CleanupScanner(home: settings.home, clones: clones, tempDir: settings.tempDir)
        let result = await Task.detached(priority: .utility) { scanner.scan(runningBundleIDs: running, runningTools: tools, only: categories, isCancelled: { cancel?.isSet ?? false }) }.value
        if recordInHistory, !result.cancelled {
            history?.recordScan(kind: categories == nil ? "cleanup" : "cleanup.partial", at: result.finishedAt, findings: await findings(),
                                reclaimable: result.safeReclaimable, health: nil)
        }
        return result
    }

    public func largeFiles(minBytes: UInt64, olderThanDays: Int?, limit: Int) async -> [FileEntry] {
        await largeFilesScan(minBytes: minBytes, olderThanDays: olderThanDays, limit: limit).files
    }

    public func largeFilesScan(minBytes: UInt64, olderThanDays: Int?, limit: Int) async -> LargeFilesResult {
        let home = settings.home
        let deadline = Date().addingTimeInterval(settings.largeFilesTimeout)
        let filter = FileFilter(minSize: minBytes, olderThanDays: olderThanDays)
        return await Task.detached(priority: .utility) {
            DiskAnalyzer.largeFilesScan(root: home, filter: filter, limit: limit, skip: [home + "/Library"], deadline: deadline)
        }.value
    }

    public func crashSummary(process: String) async -> String? {
        let home = settings.home
        return await Task.detached(priority: .utility) {
            CrashReportCollector(directory: home + "/Library/Logs/DiagnosticReports", home: home).crashSummary(process: process)
        }.value
    }

    public func benchmarkComparisons(limit: Int) async -> [BenchmarkComparison] {
        history?.benchmarks(limit: limit) ?? []
    }
}
#endif
