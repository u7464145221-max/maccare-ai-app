import Foundation

/// Pojedynczy, rzeczywisty pomiar. Każdy wniosek (reguły lub AI) musi wskazywać identyfikatory dowodów.
public struct Evidence: Codable, Hashable, Sendable, Identifiable {
    public var id: String          // stabilny, np. "mem.pressure", "proc.cpu.1234"
    public var source: String      // skąd pochodzi pomiar, np. "host_statistics64", "sysctl vm.swapusage"
    public var label: String       // opis po polsku
    public var value: String       // wartość czytelna
    public var numeric: Double?
    public var unit: String?
    public var measuredAt: Date
    /// true = dane testowe/syntetyczne – zawsze oznaczane w UI i raportach.
    public var synthetic: Bool

    public init(id: String, source: String, label: String, value: String, numeric: Double? = nil,
                unit: String? = nil, measuredAt: Date, synthetic: Bool = false) {
        self.id = id; self.source = source; self.label = label; self.value = value
        self.numeric = numeric; self.unit = unit; self.measuredAt = measuredAt; self.synthetic = synthetic
    }
}

public enum MemoryPressureLevel: String, Codable, Sendable { case normal, warning, critical
    public var label: String { switch self { case .normal: return String(localized: "normalne"); case .warning: return String(localized: "podwyższone"); case .critical: return String(localized: "krytyczne") } }
}

public enum ThermalLevel: Int, Codable, Sendable { case nominal = 0, fair, serious, critical
    public var label: String { switch self { case .nominal: return String(localized: "nominalny"); case .fair: return String(localized: "podwyższony"); case .serious: return String(localized: "poważny (throttling)"); case .critical: return String(localized: "krytyczny") } }
}

public struct CPUStats: Codable, Sendable, Equatable {
    public var totalPercent: Double
    public var perCore: [Double]
    public var loadAverage: [Double]      // 1, 5, 15 min
    public var coreCount: Int
    public init(totalPercent: Double, perCore: [Double] = [], loadAverage: [Double] = [], coreCount: Int) {
        self.totalPercent = totalPercent; self.perCore = perCore; self.loadAverage = loadAverage; self.coreCount = coreCount
    }
}

public struct MemoryStats: Codable, Sendable, Equatable {
    public var total: UInt64
    public var used: UInt64             // app + wired + compressed
    public var wired: UInt64
    public var compressed: UInt64
    public var cachedFiles: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressureLevel
    public var pageoutsPerSec: Double?
    public init(total: UInt64, used: UInt64, wired: UInt64 = 0, compressed: UInt64 = 0, cachedFiles: UInt64 = 0,
                swapUsed: UInt64 = 0, swapTotal: UInt64 = 0, pressure: MemoryPressureLevel = .normal, pageoutsPerSec: Double? = nil) {
        self.total = total; self.used = used; self.wired = wired; self.compressed = compressed; self.cachedFiles = cachedFiles
        self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.pressure = pressure; self.pageoutsPerSec = pageoutsPerSec
    }
}

public struct VolumeStats: Codable, Sendable, Equatable {
    public var mountPoint: String
    public var name: String
    public var total: UInt64
    /// Miejsce dostępne dla „ważnych” zapisów (uwzględnia purgeable) – tak raportuje Finder.
    public var availableImportant: UInt64
    /// Miejsce faktycznie wolne (bez purgeable).
    public var availableStrict: UInt64
    public var fileSystem: String
    public var isInternal: Bool
    public init(mountPoint: String, name: String, total: UInt64, availableImportant: UInt64, availableStrict: UInt64,
                fileSystem: String = "apfs", isInternal: Bool = true) {
        self.mountPoint = mountPoint; self.name = name; self.total = total; self.availableImportant = availableImportant
        self.availableStrict = availableStrict; self.fileSystem = fileSystem; self.isInternal = isInternal
    }
    public var freeFraction: Double { total == 0 ? 1 : Double(availableImportant) / Double(total) }
    public var purgeable: UInt64 { availableImportant > availableStrict ? availableImportant - availableStrict : 0 }
}

public struct DiskIOStats: Codable, Sendable, Equatable {
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var readOpsPerSec: Double
    public var writeOpsPerSec: Double
    /// Średni czas operacji (ms) z liczników IOBlockStorageDriver, jeśli dostępne.
    public var avgLatencyMs: Double?
    public init(readBytesPerSec: Double, writeBytesPerSec: Double, readOpsPerSec: Double, writeOpsPerSec: Double, avgLatencyMs: Double? = nil) {
        self.readBytesPerSec = readBytesPerSec; self.writeBytesPerSec = writeBytesPerSec
        self.readOpsPerSec = readOpsPerSec; self.writeOpsPerSec = writeOpsPerSec; self.avgLatencyMs = avgLatencyMs
    }
}

public struct BatteryStats: Codable, Sendable, Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var onAC: Bool
    public var cycleCount: Int?
    public var designCapacity: Int?          // mAh
    public var maxCapacity: Int?             // mAh (AppleRawMaxCapacity)
    public var temperatureC: Double?
    public var condition: String?            // "Normal"/"Good", "Service Recommended"…
    /// Skąd pochodzi `condition` (np. "system_profiler SPPowerDataType" albo "IOPowerSources BatteryHealth") – trafia do dowodu.
    public var conditionSource: String?
    /// Maksymalna pojemność w %, tak jak raportuje ją sam system (system_profiler). Ma pierwszeństwo przed własnym przeliczeniem mAh.
    public var reportedMaxCapacityPercent: Double?
    public init(percent: Int, isCharging: Bool, onAC: Bool, cycleCount: Int? = nil, designCapacity: Int? = nil,
                maxCapacity: Int? = nil, temperatureC: Double? = nil, condition: String? = nil,
                conditionSource: String? = nil, reportedMaxCapacityPercent: Double? = nil) {
        self.percent = percent; self.isCharging = isCharging; self.onAC = onAC; self.cycleCount = cycleCount
        self.designCapacity = designCapacity; self.maxCapacity = maxCapacity; self.temperatureC = temperatureC; self.condition = condition
        self.conditionSource = conditionSource; self.reportedMaxCapacityPercent = reportedMaxCapacityPercent
    }
    /// Kondycja = wartość raportowana przez system albo (zapas) pojemność maksymalna / projektowa. nil, gdy system nie udostępnia danych.
    public var healthPercent: Double? {
        if let r = reportedMaxCapacityPercent { return min(100, r) }
        guard let d = designCapacity, d > 0, let m = maxCapacity, m > 0 else { return nil }
        return min(100, Double(m) / Double(d) * 100)
    }
    public var healthSource: String { reportedMaxCapacityPercent != nil ? "system_profiler SPPowerDataType" : "AppleSmartBattery Raw/DesignCapacity" }
}

public struct ProcessSample: Codable, Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var executablePath: String
    public var bundlePath: String?       // ścieżka .app, jeśli proces należy do aplikacji
    public var isCurrentUser: Bool
    public var cpuPercent: Double        // 100% = jeden rdzeń
    public var memoryFootprint: UInt64
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
    public var energyImpactHint: Double? // przybliżenie z wakeups/CPU, jeśli dostępne
    public var isZombie: Bool
    public var startedAt: Date?
    public var id: Int32 { pid }
    public init(pid: Int32, parentPID: Int32 = 1, name: String, executablePath: String = "", bundlePath: String? = nil,
                isCurrentUser: Bool = true, cpuPercent: Double = 0, memoryFootprint: UInt64 = 0, diskReadBytes: UInt64? = nil,
                diskWriteBytes: UInt64? = nil, energyImpactHint: Double? = nil, isZombie: Bool = false, startedAt: Date? = nil) {
        self.pid = pid; self.parentPID = parentPID; self.name = name; self.executablePath = executablePath; self.bundlePath = bundlePath
        self.isCurrentUser = isCurrentUser; self.cpuPercent = cpuPercent; self.memoryFootprint = memoryFootprint
        self.diskReadBytes = diskReadBytes; self.diskWriteBytes = diskWriteBytes; self.energyImpactHint = energyImpactHint
        self.isZombie = isZombie; self.startedAt = startedAt
    }
    public var displayName: String {
        if let b = bundlePath { return URL(fileURLWithPath: b).deletingPathExtension().lastPathComponent }
        return name
    }
}

public enum StartupScope: String, Codable, Sendable { case userAgent, globalAgent, globalDaemon, loginItem, backgroundTaskManagement
    public var label: String {
        switch self {
        case .userAgent: return String(localized: "Agent użytkownika"); case .globalAgent: return String(localized: "Agent globalny"); case .globalDaemon: return String(localized: "Demon systemowy")
        case .loginItem: return String(localized: "Element logowania"); case .backgroundTaskManagement: return String(localized: "Element w tle (BTM)")
        }
    }
}

public enum SignatureStatus: String, Codable, Sendable {
    case appleSigned, developerID, appStore, adHoc, unsigned, invalid, notChecked, missingBinary
    /// Podpis Developer ID, ale bez notaryzacji (starsze, legalne narzędzia). Nie jest „zaufany”, lecz też nie budzi osobnego ustalenia.
    case developerIDNotNotarized
    /// Poprawny podpis, ale certyfikat spoza łańcucha Apple (self-signed, certyfikat deweloperski).
    case untrustedCertificate
    public var label: String {
        switch self {
        case .appleSigned: return String(localized: "Apple"); case .developerID: return String(localized: "Developer ID (notaryzowany)"); case .appStore: return String(localized: "App Store")
        case .adHoc: return String(localized: "Podpis ad-hoc"); case .unsigned: return String(localized: "Brak podpisu"); case .invalid: return String(localized: "Nieprawidłowy podpis")
        case .notChecked: return String(localized: "Nie sprawdzono"); case .missingBinary: return String(localized: "Brak pliku programu")
        case .developerIDNotNotarized: return String(localized: "Developer ID (bez notaryzacji)"); case .untrustedCertificate: return String(localized: "Certyfikat spoza łańcucha Apple")
        }
    }
    public var isTrusted: Bool { [.appleSigned, .developerID, .appStore].contains(self) }
}

public struct StartupItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { plistPath ?? label }
    public var label: String
    public var program: String?
    public var plistPath: String?
    public var scope: StartupScope
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var isLoaded: Bool?
    public var signature: SignatureStatus
    public var teamID: String?
    public var signerName: String?
    public init(label: String, program: String?, plistPath: String?, scope: StartupScope, runAtLoad: Bool = false,
                keepAlive: Bool = false, isLoaded: Bool? = nil, signature: SignatureStatus = .notChecked, teamID: String? = nil, signerName: String? = nil) {
        self.label = label; self.program = program; self.plistPath = plistPath; self.scope = scope; self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive; self.isLoaded = isLoaded; self.signature = signature; self.teamID = teamID; self.signerName = signerName
    }
    public var isApple: Bool { label.hasPrefix("com.apple.") }
    public var programMissing: Bool { signature == .missingBinary }
}

extension StartupItem {
    /// Program z lokalnego środowiska użytkownika (np. `.venv`, `~/.local`) albo z Homebrew – takie elementy są agregowane w jedno ustalenie.
    public func isFromLocalTools(home: String) -> Bool {
        guard let p = program else { return false }
        return p.hasPrefix(home + "/") || p.hasPrefix("/opt/homebrew/") || p.hasPrefix("/usr/local/")
    }
    /// Status podpisu, który zasługuje na ustalenie. `.developerIDNotNotarized` celowo NIE (starsze, legalne narzędzia).
    public var hasUntrustedSignature: Bool { [.unsigned, .invalid, .adHoc, .untrustedCertificate].contains(signature) }
}

public enum ToggleState: String, Codable, Sendable { case enabled, disabled, unknown }

public struct SecurityPosture: Codable, Sendable, Equatable {
    public var sip: ToggleState = .unknown
    public var gatekeeper: ToggleState = .unknown
    public var fileVault: ToggleState = .unknown
    public var firewall: ToggleState = .unknown
    public var firewallStealth: ToggleState = .unknown
    public var autoUpdateCheck: ToggleState = .unknown
    public var xprotectVersion: String?
    public var xprotectRemediatorVersion: String?
    public var fullDiskAccessGranted: Bool?
    public var listeningExternalPorts: [String] = []
    public init() {}
}

public struct CrashReportSummary: Codable, Sendable, Hashable {
    public var process: String
    public var count: Int
    public var lastDate: Date
    public var kinds: [String]         // "crash", "hang", "jetsam", "cpu_resource", "wakeups"
    public init(process: String, count: Int, lastDate: Date, kinds: [String]) {
        self.process = process; self.count = count; self.lastDate = lastDate; self.kinds = kinds
    }
}

/// Kompletny, deterministyczny obraz stanu Maca. Pola opcjonalne = system nie udostępnił danych
/// (NIE są interpretowane jako „OK” ani karane w ocenie).
public struct SystemSnapshot: Codable, Sendable {
    public var takenAt: Date
    public var osVersion: String
    public var modelIdentifier: String?
    public var isAppleSilicon: Bool?
    public var uptimeSeconds: Double?
    public var cpu: CPUStats?
    public var memory: MemoryStats?
    public var volumes: [VolumeStats]
    public var diskIO: DiskIOStats?
    public var battery: BatteryStats?
    public var thermal: ThermalLevel?
    public var processes: [ProcessSample]
    public var startupItems: [StartupItem]?
    public var security: SecurityPosture?
    public var crashes: [CrashReportSummary]?
    /// Procesy widoczne dla jądra, ale niemierzalne bez uprawnień (głównie procesy roota). nil = nieznane.
    public var unmeasuredProcessCount: Int?
    /// Daty lokalnych migawek Time Machine (blokują zwrot miejsca po usunięciu plików). nil = nieznane.
    public var localSnapshots: [Date]?
    /// Aktualizacje systemu i aplikacji Apple oczekujące według OSTATNIEGO sprawdzenia przez macOS (P2-10, etap 1). nil = nieznane.
    public var updates: SoftwareUpdateStatus? = nil
    public var synthetic: Bool

    public init(takenAt: Date, osVersion: String, modelIdentifier: String? = nil, isAppleSilicon: Bool? = nil,
                uptimeSeconds: Double? = nil, cpu: CPUStats? = nil, memory: MemoryStats? = nil, volumes: [VolumeStats] = [],
                diskIO: DiskIOStats? = nil, battery: BatteryStats? = nil, thermal: ThermalLevel? = nil,
                processes: [ProcessSample] = [], startupItems: [StartupItem]? = nil, security: SecurityPosture? = nil,
                crashes: [CrashReportSummary]? = nil, unmeasuredProcessCount: Int? = nil, localSnapshots: [Date]? = nil, synthetic: Bool = false) {
        self.takenAt = takenAt; self.osVersion = osVersion; self.modelIdentifier = modelIdentifier; self.isAppleSilicon = isAppleSilicon
        self.uptimeSeconds = uptimeSeconds; self.cpu = cpu; self.memory = memory; self.volumes = volumes; self.diskIO = diskIO
        self.battery = battery; self.thermal = thermal; self.processes = processes; self.startupItems = startupItems
        self.security = security; self.crashes = crashes; self.unmeasuredProcessCount = unmeasuredProcessCount; self.localSnapshots = localSnapshots; self.synthetic = synthetic
    }

    public var bootVolume: VolumeStats? { volumes.first { $0.mountPoint == "/" } ?? volumes.first }

    /// Procesy pogrupowane per aplikacja (sumy CPU i pamięci).
    public func appGroups() -> [ProcessGroup] {
        var map: [String: ProcessGroup] = [:]
        for p in processes {
            let key = p.bundlePath ?? p.name
            if var g = map[key] {
                g.pids.append(p.pid); g.cpuPercent += p.cpuPercent; g.memory += p.memoryFootprint
                g.allCurrentUser = g.allCurrentUser && p.isCurrentUser
                map[key] = g
            } else {
                map[key] = ProcessGroup(key: key, name: p.displayName, bundlePath: p.bundlePath, pids: [p.pid],
                                        cpuPercent: p.cpuPercent, memory: p.memoryFootprint, allCurrentUser: p.isCurrentUser,
                                        executablePath: p.executablePath.isEmpty ? nil : p.executablePath)
            }
        }
        return Array(map.values)
    }

    /// Zbiór dowodów wyprowadzonych z migawki – wspólne słownictwo reguł, panelu i asystenta.
    /// - Parameter context: progi i ochrona procesów – dowody powstają też dla każdej grupy, którą może zacytować reguła
    ///   (pamięć ≥ próg bezczynnej aplikacji, CPU ≥ próg procesu, największa grupa możliwa do zamknięcia), a nie tylko dla top-5.
    public func evidence(context: RuleContext = RuleContext()) -> [Evidence] {
        var e: [Evidence] = []
        let t = takenAt
        func add(_ id: String, _ src: String, _ label: String, _ value: String, _ n: Double? = nil, _ unit: String? = nil) {
            e.append(Evidence(id: id, source: src, label: label, value: value, numeric: n, unit: unit, measuredAt: t, synthetic: synthetic))
        }
        if let c = cpu {
            add("cpu.total", "host_processor_info", String(localized: "Obciążenie CPU (wszystkie rdzenie)"), String(format: "%.0f%%", c.totalPercent), c.totalPercent, "%")
            if c.loadAverage.count == 3 {
                add("cpu.load", "getloadavg", String(localized: "Średnie obciążenie 1/5/15 min"), c.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / "), c.loadAverage[0])
            }
        }
        if let m = memory {
            add("mem.pressure", "kern.memorystatus_vm_pressure_level", String(localized: "Ciśnienie pamięci"), m.pressure.label)
            add("mem.used", "host_statistics64", String(localized: "Pamięć w użyciu"), "\(ByteFormat.string(m.used)) z \(ByteFormat.string(m.total))", Double(m.used), "B")
            add("mem.compressed", "host_statistics64", String(localized: "Pamięć skompresowana"), ByteFormat.string(m.compressed), Double(m.compressed), "B")
            add("mem.swap", "sysctl vm.swapusage", String(localized: "Użycie swap"), ByteFormat.string(m.swapUsed), Double(m.swapUsed), "B")
            if let po = m.pageoutsPerSec { add("mem.pageouts", "host_statistics64", "Zrzuty stron na dysk", String(format: "%.0f/s", po), po, "1/s") }
        }
        if let v = bootVolume {
            add("disk.free", "URLResourceKey.volumeAvailableCapacityForImportantUsage", "Wolne miejsce (dysk startowy)",
                "\(ByteFormat.string(v.availableImportant)) z \(ByteFormat.string(v.total)) (\(Int(v.freeFraction * 100))%)", Double(v.availableImportant), "B")
            if v.purgeable > 0 { add("disk.purgeable", "volumeAvailableCapacity vs ForImportantUsage", "Miejsce do odzyskania przez system (purgeable)", ByteFormat.string(v.purgeable), Double(v.purgeable), "B") }
        }
        if let snaps = localSnapshots {
            let newest = snaps.max().map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
            add("tm.snapshots", "tmutil listlocalsnapshotdates", "Lokalne migawki Time Machine", snaps.isEmpty ? "brak" : "\(snaps.count) (najnowsza: \(newest))", Double(snaps.count))
        }
        if let io = diskIO {
            add("disk.io", "IOBlockStorageDriver Statistics", "Transfer dysku (odczyt/zapis)",
                "\(ByteFormat.string(UInt64(io.readBytesPerSec)))/s / \(ByteFormat.string(UInt64(io.writeBytesPerSec)))/s", io.readBytesPerSec + io.writeBytesPerSec, "B/s")
            if let l = io.avgLatencyMs { add("disk.latency", "IOBlockStorageDriver Statistics", String(localized: "Średni czas operacji dysku"), String(format: "%.1f ms", l), l, "ms") }
        }
        if let b = battery {
            add("bat.percent", "IOPowerSources", String(localized: "Poziom naładowania"), "\(b.percent)%\(b.isCharging ? " (ładowanie)" : "")", Double(b.percent), "%")
            if let c = b.cycleCount { add("bat.cycles", "AppleSmartBattery CycleCount", String(localized: "Cykle ładowania"), "\(c)", Double(c)) }
            if let h = b.healthPercent { add("bat.health", b.healthSource, "Kondycja baterii", String(format: "%.0f%%", h), h, "%") }
            if let cond = b.condition { add("bat.condition", b.conditionSource ?? "IOPowerSources BatteryHealth", "Stan baterii wg systemu", cond) }
            if let temp = b.temperatureC { add("bat.temp", "AppleSmartBattery Temperature", "Temperatura baterii", String(format: "%.1f °C", temp), temp, "°C") }
        }
        if let th = thermal { add("thermal.state", "ProcessInfo.thermalState", "Stan termiczny", th.label, Double(th.rawValue)) }
        let groups = appGroups()
        var cpuGroups = Array(groups.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(5)).filter { $0.cpuPercent >= 1 }
        var memGroups = Array(groups.sorted(by: { $0.memory > $1.memory }).prefix(5))
        let th = context.thresholds
        for g in groups where g.cpuPercent >= th.processCPUPercent && !cpuGroups.contains(where: { $0.key == g.key }) { cpuGroups.append(g) }
        for g in groups where g.memory >= th.idleAppMemoryBytes && !memGroups.contains(where: { $0.key == g.key }) { memGroups.append(g) }
        if let top = groups.filter({ ProcessGuard.canPropose($0, ctx: context) }).max(by: { $0.memory < $1.memory }), !memGroups.contains(where: { $0.key == top.key }) { memGroups.append(top) }
        for g in cpuGroups.sorted(by: { $0.cpuPercent > $1.cpuPercent }) {
            add("proc.cpu.\(g.name)", "proc_pidinfo", "CPU: \(g.name)", String(format: "%.0f%% (%d proc.)", g.cpuPercent, g.pids.count), g.cpuPercent, "%")
        }
        for g in memGroups.sorted(by: { $0.memory > $1.memory }) {
            add("proc.mem.\(g.name)", "proc_pid_rusage phys_footprint", String(localized: "Pamięć: \(g.name)"), ByteFormat.string(g.memory), Double(g.memory), "B")
        }
        if let n = unmeasuredProcessCount, n > 0 {
            add("proc.unmeasured", "sysctl KERN_PROC_ALL vs libproc", String(localized: "Procesy systemowe niemierzalne bez uprawnień"), "\(n)", Double(n))
        }
        if let items = startupItems {
            let third = items.filter { !$0.isApple }
            add("startup.count", "launchd plist", "Elementy autostartu spoza Apple", "\(third.count)", Double(third.count))
            // Lokalne narzędzia bez zaufanego podpisu (.venv, Homebrew…) – jeden zbiorczy dowód zamiast jednego na element.
            let local = third.filter { $0.hasUntrustedSignature && !$0.programMissing && $0.isFromLocalTools(home: context.homePath) }
            if !local.isEmpty {
                let labels = local.map { $0.label }.sorted()
                add("startup.local_unsigned", "launchd plist + SecStaticCode", String(localized: "Autostart z lokalnych narzędzi bez zaufanego podpisu"),
                    "\(local.count): " + labels.prefix(10).joined(separator: ", ") + (labels.count > 10 ? " …" : ""), Double(local.count))
            }
            for i in third where i.programMissing || (i.hasUntrustedSignature && !local.contains(where: { $0.id == i.id })) {
                add("startup.item.\(i.label)", "launchd plist + SecStaticCode", "Autostart: \(i.label)", i.signature.label)
            }
        }
        if let s = security {
            add("sec.sip", "csrutil status", "SIP", s.sip.rawValue)
            add("sec.gatekeeper", "spctl --status", "Gatekeeper", s.gatekeeper.rawValue)
            add("sec.filevault", "fdesetup status", "FileVault", s.fileVault.rawValue)
            add("sec.firewall", "socketfilterfw", "Zapora aplikacji", s.firewall.rawValue)
            if let fda = s.fullDiskAccessGranted { add("sec.fda", "test odczytu chronionego katalogu", String(localized: "Pełny dostęp do dysku dla MacCare"), fda ? "przyznany" : "brak") }
        }
        for c in crashes ?? [] {
            add("crash.\(c.process)", "DiagnosticReports", "Raporty awarii: \(c.process)", "\(c.count)× (\(c.kinds.joined(separator: ", ")))", Double(c.count))
        }
        if let u = uptimeSeconds { add("sys.uptime", "kern.boottime", "Czas od uruchomienia", String(format: "%.1f h", u / 3600), u / 3600, "h") }
        if let up = updates {
            add("updates.pending", "com.apple.SoftwareUpdate.plist (RecommendedUpdates)", String(localized: "Oczekujące aktualizacje Apple"),
                up.pending.isEmpty ? "brak" : up.pending.map(\.title).joined(separator: ", "), Double(up.pending.count))
            if let d = up.lastCheck { add("updates.lastCheck", "com.apple.SoftwareUpdate.plist (LastSuccessfulDate)", "Ostatnie sprawdzenie aktualizacji", d.formatted(date: .abbreviated, time: .shortened)) }
        }
        return e
    }
}

public struct ProcessGroup: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var bundlePath: String?
    public var pids: [Int32]
    public var cpuPercent: Double
    public var memory: UInt64
    public var allCurrentUser: Bool
    /// Ścieżka pliku wykonywalnego pierwszego procesu grupy (do ochrony procesów systemowych).
    public var executablePath: String? = nil
    public var id: String { key }
}

/// Stan aktualizacji z pliku preferencji Software Update (tylko odczyt, bez sieci i bez uruchamiania `softwareupdate`).
/// To wynik OSTATNIEGO sprawdzenia wykonanego przez macOS – data sprawdzenia jest częścią dowodu.
public struct SoftwareUpdateStatus: Codable, Sendable, Equatable {
    public struct Pending: Codable, Sendable, Equatable {
        public var name: String
        public var version: String?
        public var identifier: String?
        public var title: String { version.map { name.contains($0) ? name : "\(name) \($0)" } ?? name }
        /// Aktualizacja samego systemu (nie aplikacji Apple, np. Safari).
        public var isMacOS: Bool { name.lowercased().hasPrefix("macos") }
        public init(name: String, version: String? = nil, identifier: String? = nil) { self.name = name; self.version = version; self.identifier = identifier }
    }
    public var pending: [Pending]
    public var lastCheck: Date?
    public init(pending: [Pending], lastCheck: Date?) { self.pending = pending; self.lastCheck = lastCheck }

    public static let defaultPath = "/Library/Preferences/com.apple.SoftwareUpdate.plist"

    public static func parse(plist p: [String: Any]) -> SoftwareUpdateStatus {
        let pending = (p["RecommendedUpdates"] as? [[String: Any]] ?? []).compactMap { u -> Pending? in
            guard let name = (u["Display Name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return Pending(name: name, version: u["Display Version"] as? String, identifier: u["Identifier"] as? String)
        }
        return SoftwareUpdateStatus(pending: pending, lastCheck: (p["LastSuccessfulDate"] as? Date) ?? (p["LastFullSuccessfulDate"] as? Date))
    }

    public static func read(path: String = defaultPath) -> SoftwareUpdateStatus? {
        guard let d = FileManager.default.contents(atPath: path),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return parse(plist: p)
    }
}
