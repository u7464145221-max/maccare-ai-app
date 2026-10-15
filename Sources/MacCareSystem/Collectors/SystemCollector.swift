#if os(macOS)
import Foundation
import MacCareCore

/// Zbiera `SystemSnapshot` z prawdziwego systemu. Stan (poprzednie liczniki) trzyma wewnątrz,
/// więc wielkości „na sekundę” są liczone z delt. Wartości niedostępne ⇒ nil (nie „OK”).
///
/// Autostart, podpisy, zabezpieczenia i raporty awarii dodaje osobny kolektor (T3).
public actor SystemCollector {
    private var cpu = CPUCollector()
    private var memory = MemoryCollector()
    private var diskIO = DiskIOCollector()
    private var processes = ProcessCollector()
    private let clock: Clock

    private var cachedVolumes: [VolumeStats] = []
    private var cachedBattery: BatteryStats?
    private var slowLoaded = false
    private let batteryProfile = BatteryProfileCache()

    /// Liczba procesów widocznych dla jądra, ale niemierzalnych bez uprawnień (głównie procesy roota).
    /// Ostatnia próbka; do wykorzystania przy interpretacji „CPU systemu vs suma procesów”.
    public private(set) var unmeasuredProcessCount = 0

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
        // Baza dla delt – pierwsza właściwa próbka ma już z czym porównywać.
        let now = clock.now
        _ = cpu.sample(now: now); _ = memory.sample(now: now); _ = diskIO.sample(now: now); _ = processes.sample()
    }

    /// - Parameter refreshSlow: odświeża wolumeny i baterię (zmieniają się wolno). Pierwsze wywołanie zawsze je czyta.
    public func snapshot(refreshSlow: Bool = true) async -> SystemSnapshot {
        let now = clock.now
        if refreshSlow || !slowLoaded {
            cachedVolumes = VolumeCollector.read()
            cachedBattery = BatteryCollector.read()
            // Stan i pojemność wg samego systemu (system_profiler, cache 1 h) mają pierwszeństwo; IOPS zostaje zapasem.
            if var b = cachedBattery, let prof = await batteryProfile.current(now: now, hasBattery: true) {
                if let c = prof.condition { b.condition = c; b.conditionSource = BatteryProfile.source }
                if let m = prof.maxCapacityPercent { b.reportedMaxCapacityPercent = m }
                cachedBattery = b
            }
            slowLoaded = true
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var uptime: Double?
        if let bt = Sysctl.value("kern.boottime", timeval()), bt.tv_sec > 0 { uptime = now.timeIntervalSince1970 - Double(bt.tv_sec) }

        let procs = processes.sample()
        unmeasuredProcessCount = processes.unmeasuredCount
        return SystemSnapshot(
            takenAt: now,
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            modelIdentifier: Sysctl.string("hw.model"),
            isAppleSilicon: Sysctl.int32("hw.optional.arm64") == 1,
            uptimeSeconds: uptime,
            cpu: cpu.sample(now: now),
            memory: memory.sample(now: now),
            volumes: cachedVolumes,
            diskIO: diskIO.sample(now: now),
            battery: cachedBattery,
            thermal: ThermalLevel(rawValue: ProcessInfo.processInfo.thermalState.rawValue),
            processes: procs,
            unmeasuredProcessCount: processes.unmeasuredCount,
            synthetic: false)
    }
}
#endif
