#if os(macOS)
import Foundation
import MacCareCore

/// Pamięć: `host_statistics64` (app/wired/compressed/file-backed), ciśnienie, swap, pageouts/s z delty.
struct MemoryCollector {
    private var prevPageouts: UInt64?
    private var prevAt: Date?

    mutating func sample(now: Date) -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let appPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = appPages * page + wired + compressed

        var pressure = MemoryPressureLevel.normal
        if let lvl = Sysctl.int32("kern.memorystatus_vm_pressure_level") {
            pressure = lvl >= 4 ? .critical : (lvl >= 2 ? .warning : .normal)
        }
        var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
        if let sw = Sysctl.value("vm.swapusage", xsw_usage()) { swapUsed = sw.xsu_used; swapTotal = sw.xsu_total }

        var pageouts: Double?
        let po = UInt64(stats.pageouts)
        if let p = prevPageouts, let at = prevAt, now.timeIntervalSince(at) >= 0.25, po >= p {
            pageouts = Double(po - p) / now.timeIntervalSince(at)
        }
        if prevAt == nil || now.timeIntervalSince(prevAt!) >= 0.25 { prevPageouts = po; prevAt = now }

        return MemoryStats(total: ProcessInfo.processInfo.physicalMemory, used: used, wired: wired, compressed: compressed,
                           cachedFiles: UInt64(stats.external_page_count) * page, swapUsed: swapUsed, swapTotal: swapTotal,
                           pressure: pressure, pageoutsPerSec: pageouts)
    }
}
#endif
