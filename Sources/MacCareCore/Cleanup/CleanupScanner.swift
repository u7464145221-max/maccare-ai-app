import Foundation

/// Element znaleziony przez skaner. Zawiera wszystko, co UI musi pokazać przed decyzją.
public struct CleanupCandidate: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var ruleID: String
    public var category: CleanupCategory
    public var description: String
    public var owner: String
    public var allocatedSize: UInt64
    /// Szacunek miejsca, które realnie wróci (bez twardych dowiązań i części współdzielonych klonów APFS).
    public var reclaimableSize: UInt64
    public var modified: Date?
    public var risk: RiskLevel
    public var recreatable: Bool
    public var removal: RemovalMode
    /// Aplikacja-właściciel działa – element nie jest zaznaczany i wymaga zamknięcia aplikacji.
    public var ownerRunning: Bool
    public var safeToRemove: Bool { recreatable && risk <= .low && !ownerRunning }
    public var safetyNote: String {
        if ownerRunning { return String(localized: "Aplikacja \(owner) jest uruchomiona – zamknij ją przed usunięciem.") }
        if removal == .permanent { return String(localized: "Usunięcie nieodwracalne.") }
        if safeToRemove { return String(localized: "Bezpieczne – dane odtworzą się automatycznie.") }
        return String(localized: "Do przejrzenia – sprawdź, czy nie są Ci potrzebne.")
    }
    public static func == (a: Self, b: Self) -> Bool { a.path == b.path }
    public func hash(into h: inout Hasher) { h.combine(path) }
}

public struct CleanupScanResult: Codable, Sendable {
    public var candidates: [CleanupCandidate]
    public var scannedRules: Int
    public var unreadableLocations: [String]     // np. brak uprawnień TCC – raportowane, nie ukrywane
    public var startedAt: Date
    public var finishedAt: Date
    /// P2-4 (AUD-SCAN-4): skan przerwany przez użytkownika – wynik NIEPEŁNY (część reguł nie została sprawdzona). UI musi to pokazać.
    public var cancelled: Bool = false
    public var isComplete: Bool { !cancelled }
    public var totalReclaimable: UInt64 { candidates.reduce(0) { $0 + $1.reclaimableSize } }
    public var safeReclaimable: UInt64 { candidates.filter { $0.safeToRemove }.reduce(0) { $0 + $1.reclaimableSize } }
    public func byCategory() -> [(CleanupCategory, [CleanupCandidate])] {
        let g = Dictionary(grouping: candidates, by: { $0.category })
        return CleanupCategory.allCases.compactMap { c in g[c].map { (c, $0.sorted { $0.allocatedSize > $1.allocatedSize }) } }
    }
}

/// Wyniki pomiarów zbierane z wątków puli (audyt 2, 4.2).
final class PathResults: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: DiskUsage] = [:]
    func set(_ p: String, _ u: DiskUsage) { lock.withLock { map[p] = u } }
    func all() -> [String: DiskUsage] { lock.withLock { map } }
}

public struct CleanupScanner: Sendable {
    public var rules: [CleanupRule]
    public var home: String
    public var clones: CloneInfoProvider
    public var clock: Clock
    public var minimumSize: UInt64
    public var tempDir: String

    public init(rules: [CleanupRule] = CleanupCatalog.rules, home: String = PathTools.home, clones: CloneInfoProvider = NoCloneInfo(),
                clock: Clock = SystemClock(), minimumSize: UInt64 = 1, tempDir: String = NSTemporaryDirectory()) {
        self.rules = rules; self.home = home; self.clones = clones; self.clock = clock; self.minimumSize = minimumSize; self.tempDir = tempDir
    }

    /// - Parameter runningBundleIDs: identyfikatory uruchomionych aplikacji (z NSWorkspace na macOS).
    /// - Parameter runningTools: znaczniki pracujących narzędzi wiersza poleceń (`ToolActivity`, P2-3) – ich pamięć podręczna jest „w użyciu”.
    public func scan(runningBundleIDs: Set<String> = [], runningTools: Set<String> = [], only categories: Set<CleanupCategory>? = nil,
                     isCancelled: @Sendable () -> Bool = { false }) -> CleanupScanResult {
        let start = clock.now
        let roots = CleanupCatalog.allowedRoots(rules, home: home, tempDir: tempDir)
        let policy = PathPolicy(home: home, ruleRoots: roots)
        let running = Set(runningBundleIDs.map { $0.lowercased() })
        var out: [CleanupCandidate] = []
        var unreadable: [String] = []
        var scanned = 0
        let fm = FileManager.default

        // Audyt 2 (4.2): faza 1 – lista celów (tanio, po kolei, ta sama kolejność co dawniej).
        struct Job { let rule: CleanupRule; let path: String; let st: FileStat }
        var jobs: [Job] = []
        for rule in rules {
            if isCancelled() { break }
            if let only = categories, !only.contains(rule.category) { continue }
            scanned += 1
            for raw in rule.paths {
                let root = CleanupCatalog.expand(raw, home: home, tempDir: tempDir)
                guard roots.contains(root), FileStat.of(root) != nil else { continue }
                var targets: [String] = []
                switch rule.match {
                case .whole:
                    targets = [root]
                case .children, .childrenWithExtensions, .childrenNamed:
                    guard let kids = try? fm.contentsOfDirectory(atPath: root) else { unreadable.append(root); continue }   // try? świadomie: nieczytelny katalog ⇒ brak wpisów (tylko odczyt)
                    for k in kids where k != ".DS_Store" && k != ".localized" {
                        if rule.excludeNames.contains(k) { continue }
                        if k.hasPrefix("com.apple.") && rule.owner != "macOS" { continue }
                        if case .childrenWithExtensions(let exts) = rule.match, !exts.contains((k as NSString).pathExtension.lowercased()) { continue }
                        if case .childrenNamed(let pattern) = rule.match, !Self.wildcard(k, pattern) { continue }
                        targets.append(root + "/" + k)
                    }
                }
                for t in targets {
                    guard policy.check(t, scope: .ruleCleanup).isAllowed, let st = FileStat.of(t) else { continue }
                    jobs.append(Job(rule: rule, path: t, st: st))
                }
            }
        }

        // Faza 2 – pomiar WSZYSTKICH celów równolegle (pula `ParallelTreeMeasure`, jak mapa: także wewnątrz jednego dużego folderu, z klonami APFS
        // i wspólnym rejestrem dowiązań twardych). Każda ścieżka mierzona raz, choćby wskazywało ją kilka reguł.
        let cutoffNow = clock.now
        func eligible(_ job: Job) -> Bool {
            guard let age = job.rule.minAgeDays else { return true }
            return Self.isUnusedSince(job.path, st: job.st, cutoff: cutoffNow.addingTimeInterval(-Double(age) * 86400))
        }
        let isEligible = jobs.map { isCancelled() ? false : eligible($0) }
        let registry = HardLinkRegistry(), clones = self.clones, limit = ScanConcurrency.limit()
        let results = PathResults()
        var groups: [String: Set<String>] = [:]
        var files: [String] = []
        for (i, job) in jobs.enumerated() where isEligible[i] {
            if job.st.isDirectory && !job.st.isSymlink { groups[(job.path as NSString).deletingLastPathComponent, default: []].insert((job.path as NSString).lastPathComponent) }
            else { files.append(job.path) }
        }
        for f in Set(files) {
            var local = Set<FileID>()
            results.set(f, DiskUsage.measureTree(f, clones: clones, sparseSeen: true, seen: &local, shared: registry).total)
        }
        for (parent, names) in groups.sorted(by: { $0.key < $1.key }) {
            if isCancelled() { break }
            withoutActuallyEscaping(isCancelled) { stop in                                   // pomiar blokuje do końca – domknięcie nie wychodzi poza wywołanie
                ParallelTreeMeasure.measureDirectories(in: parent, names: names.sorted(), limit: limit, registry: registry, trackKinds: false,
                                                       clones: clones, shouldStop: stop) { o in results.set(parent + "/" + o.name, o.tree.total) }
            }
        }
        let measured = results.all()

        // Faza 2b – rozliczenie nakładania W KOLEJNOŚCI reguł (jak dawny wspólny `seen`): cel w już policzonym (albo ta sama ścieżka) = 0;
        // od celu, w którym leżą wcześniej policzone cele, odejmujemy ich policzony rozmiar (np. ~/Library/Caches/Google po regule Chrome).
        var usages = [DiskUsage?](repeating: nil, count: jobs.count)
        var claimed: [(path: String, usage: DiskUsage)] = []
        for (i, job) in jobs.enumerated() where isEligible[i] {
            guard var u = measured[job.path] else { continue }
            if claimed.contains(where: { $0.path == job.path || PathTools.isWithin(job.path, $0.path) }) { continue }
            for c in claimed where PathTools.isWithin(c.path, job.path) {
                u.allocated = u.allocated >= c.usage.allocated ? u.allocated - c.usage.allocated : 0
                u.reclaimable = u.reclaimable >= c.usage.reclaimable ? u.reclaimable - c.usage.reclaimable : 0
                u.fileCount = max(0, u.fileCount - c.usage.fileCount)
            }
            usages[i] = u
            claimed.append((job.path, u))
        }

        // Faza 3 – kandydaci w kolejności celów (deterministycznie).
        for (i, job) in jobs.enumerated() {
            guard let u = usages[i] else { continue }
            let rule = job.rule, t = job.path, st = job.st
            // P1-4: nieczytelne podkatalogi wewnątrz kandydata – rozmiar jest wtedy zaniżony, więc mówimy o tym (zamiast przedstawiać wynik jako pełny)
            for p in u.unreadablePaths where unreadable.count < 200 && !unreadable.contains(p) { unreadable.append(p) }
            guard u.allocated >= minimumSize else { continue }
            let name = (t as NSString).lastPathComponent
            // aplikacja-właściciel działa (wskazana w regule albo – np. ~/Library/Caches/com.spotify.client – po nazwie elementu)
            let ownerRunning = RunningOwners.ownerRunning(ruleOwners: rule.ownerBundleIDs, itemName: name, running: running)
                || ToolActivity.toolRunning(ruleID: rule.id, runningTools: runningTools)
            out.append(CleanupCandidate(path: t, name: name, ruleID: rule.id, category: rule.category,
                                        description: rule.explanation, owner: rule.owner, allocatedSize: u.allocated,
                                        reclaimableSize: u.reclaimable, modified: st.modified, risk: rule.risk,
                                        recreatable: rule.recreatable, removal: rule.removal, ownerRunning: ownerRunning))
        }
        return CleanupScanResult(candidates: out.sorted { $0.allocatedSize > $1.allocatedSize }, scannedRules: scanned,
                                 unreadableLocations: unreadable, startedAt: start, finishedAt: clock.now, cancelled: isCancelled())
    }

    /// Dla katalogów: najnowsza modyfikacja wśród CAŁEJ zawartości (bez limitu wpisów – AUD-SCAN-3). Do diagnostyki i testów; skaner używa `isUnusedSince`.
    static func newestModification(_ path: String, st: FileStat) -> Date {
        guard st.isDirectory, let e = FileManager.default.enumerator(atPath: path) else { return st.modified }
        var newest = st.modified
        forEachEntry(of: e) { rel in
            if let s = FileStat.of(path + "/" + rel), s.modified > newest { newest = s.modified }
            return true
        }
        return newest
    }

    /// Czy element (i CAŁA jego zawartość) nie był modyfikowany po `cutoff` (P1-5 / AUD-SCAN-3).
    /// Kończy przy pierwszym świeższym wpisie (wystarcza jeden). Gdy wyniku nie da się ustalić – przekroczony limit wpisów lub czasu, podkatalog bez dostępu –
    /// odpowiada OSTROŻNIE „nie” (element nie kwalifikuje się do reguł „nieużywane od N dni”).
    static func isUnusedSince(_ path: String, st: FileStat, cutoff: Date, maxEntries: Int = 500_000, timeLimit: TimeInterval = 10) -> Bool {
        if st.modified > cutoff { return false }
        guard st.isDirectory else { return true }
        guard DiskUsage.canList(path), let e = FileManager.default.enumerator(atPath: path) else { return false }
        let deadline = Date().addingTimeInterval(timeLimit)
        var n = 0, unused = true
        forEachEntry(of: e) { rel in
            n += 1
            if n > maxEntries || (n % 1000 == 0 && Date() > deadline) { unused = false; return false }        // niepewne ⇒ nie kwalifikuj
            let p = path + "/" + rel
            guard let s = FileStat.of(p) else { return true }
            if s.modified > cutoff { unused = false; return false }
            if s.isDirectory, !s.isSymlink, !DiskUsage.canList(p) { unused = false; return false }              // nie widać zawartości ⇒ niepewne
            return true
        }
        return unused
    }

    static func wildcard(_ s: String, _ pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return s == pattern }
        guard s.hasPrefix(parts.first!), s.hasSuffix(parts.last!) else { return false }
        var rest = Substring(s.dropFirst(parts.first!.count))
        for mid in parts.dropFirst().dropLast() where !mid.isEmpty {
            guard let r = rest.range(of: mid) else { return false }
            rest = rest[r.upperBound...]
        }
        return rest.count >= parts.last!.count
    }
}
