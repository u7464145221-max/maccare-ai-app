#if os(macOS)
import Foundation
import IOKit
import IOKit.ps
import MacCareCore

/// Bateria: IOPowerSources (poziom, ładowanie, stan wg systemu) + `AppleSmartBattery` (cykle, pojemność, temperatura).
/// Mac bez baterii ⇒ nil.
enum BatteryCollector {
    static func read() -> BatteryStats? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var desc: [String: Any]?
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
               (d[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType { desc = d; break }
        }
        guard let d = desc else { return nil }
        let percent = d[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        var stats = BatteryStats(percent: percent,
                                 isCharging: d[kIOPSIsChargingKey as String] as? Bool ?? false,
                                 onAC: (d[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue,
                                 condition: d[kIOPSBatteryHealthKey as String] as? String,
                                 conditionSource: "IOPowerSources BatteryHealth")

        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                stats.cycleCount = (dict["CycleCount"] as? NSNumber)?.intValue
                stats.designCapacity = (dict["DesignCapacity"] as? NSNumber)?.intValue
                // Apple Silicon: AppleRawMaxCapacity (mAh); „MaxCapacity” bywa procentem, więc go nie używamy.
                stats.maxCapacity = (dict["AppleRawMaxCapacity"] as? NSNumber)?.intValue ?? (dict["NominalChargeCapacity"] as? NSNumber)?.intValue
                if let t = (dict["Temperature"] as? NSNumber)?.doubleValue { stats.temperatureC = t / 100 }
            }
        }
        return stats
    }
}
#endif
