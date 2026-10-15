#if os(macOS)
import Foundation
import IOKit
import MacCareCore

/// Przepustowość i latencja dysku z liczników `IOBlockStorageDriver` → `Statistics` (delty).
struct DiskIOCollector {
    struct Totals {
        var readBytes: UInt64 = 0, writeBytes: UInt64 = 0
        var readOps: UInt64 = 0, writeOps: UInt64 = 0
        var readTimeNs: UInt64 = 0, writeTimeNs: UInt64 = 0
    }
    private var prev: Totals?
    private var prevAt: Date?

    mutating func sample(now: Date) -> DiskIOStats? {
        guard let t = Self.read() else { return nil }
        defer { if prevAt == nil || now.timeIntervalSince(prevAt!) >= 0.25 { prev = t; prevAt = now } }
        guard let p = prev, let at = prevAt else { return nil }
        let dt = now.timeIntervalSince(at)
        guard dt >= 0.25, t.readBytes >= p.readBytes, t.writeBytes >= p.writeBytes, t.readOps >= p.readOps, t.writeOps >= p.writeOps else { return nil }
        let dOps = (t.readOps - p.readOps) + (t.writeOps - p.writeOps)
        let dTime = (t.readTimeNs &- p.readTimeNs) &+ (t.writeTimeNs &- p.writeTimeNs)
        let latency: Double? = dOps > 0 ? Double(dTime) / Double(dOps) / 1_000_000 : nil
        return DiskIOStats(readBytesPerSec: Double(t.readBytes - p.readBytes) / dt, writeBytesPerSec: Double(t.writeBytes - p.writeBytes) / dt,
                           readOpsPerSec: Double(t.readOps - p.readOps) / dt, writeOpsPerSec: Double(t.writeOps - p.writeOps) / dt,
                           avgLatencyMs: latency)
    }

    static func read() -> Totals? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var t = Totals()
        var found = false
        var svc = IOIteratorNext(it)
        while svc != 0 {
            if let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                func n(_ k: String) -> UInt64 { (stats[k] as? NSNumber)?.uint64Value ?? 0 }
                t.readBytes += n("Bytes (Read)"); t.writeBytes += n("Bytes (Write)")
                t.readOps += n("Operations (Read)"); t.writeOps += n("Operations (Write)")
                t.readTimeNs += n("Total Time (Read)"); t.writeTimeNs += n("Total Time (Write)")
                found = true
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        return found ? t : nil
    }
}
#endif
