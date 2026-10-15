#if os(macOS)
import Foundation
import MacCareCore

/// CPU z delt liczników `host_processor_info`. Pierwsza próbka (bez bazy) zwraca nil – nie zgadujemy.
struct CPUCollector {
    private var prevTicks: [[UInt32]] = []
    private var prevAt: Date?
    private let minInterval: TimeInterval = 0.25

    mutating func sample(now: Date) -> CPUStats? {
        guard let ticks = Self.readTicks() else { return nil }
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        var load = [Double](repeating: 0, count: 3)
        let loadOK = getloadavg(&load, 3) == 3

        defer {
            // Bazę przesuwamy tylko po wystarczająco długim interwale – krótsze dają szum.
            if prevAt == nil || now.timeIntervalSince(prevAt!) >= minInterval { prevTicks = ticks; prevAt = now }
        }
        guard let at = prevAt, now.timeIntervalSince(at) >= minInterval, prevTicks.count == ticks.count else { return nil }

        var perCore: [Double] = []
        var busyAll = 0.0, totalAll = 0.0
        for i in 0..<ticks.count {
            let d = (0..<4).map { Double(ticks[i][$0] &- prevTicks[i][$0]) }
            let total = d.reduce(0, +)
            let busy = d[0] + d[1] + d[3]            // user + system + nice
            perCore.append(total > 0 ? busy / total * 100 : 0)
            busyAll += busy; totalAll += total
        }
        let pct = totalAll > 0 ? min(100, max(0, busyAll / totalAll * 100)) : 0
        return CPUStats(totalPercent: pct, perCore: perCore, loadAverage: loadOK ? load : [], coreCount: coreCount)
    }

    private static func readTicks() -> [[UInt32]]? {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var out: [[UInt32]] = []
        for i in 0..<Int(numCPU) {
            let b = i * Int(CPU_STATE_MAX)
            out.append([UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                        UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])])
        }
        return out
    }
}
#endif
