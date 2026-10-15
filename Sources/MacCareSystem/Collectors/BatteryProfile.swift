#if os(macOS)
import Foundation
import MacCareCore

/// Stan i pojemność baterii z `system_profiler SPPowerDataType -json` – to wartości, które pokazuje sam macOS
/// (IOPS `BatteryHealth` bywało np. „Check Battery” przy 97% pojemności). Wynik cache'owany na godzinę.
struct BatteryProfile: Sendable, Equatable {
    var condition: String?
    var maxCapacityPercent: Double?
    static let source = "system_profiler SPPowerDataType"

    /// Czysty parser (testowany na prawdziwym wyjściu z macOS 26.5).
    static func parse(_ json: String) -> BatteryProfile? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for it in items {
            guard let h = it["sppower_battery_health_info"] as? [String: Any] else { continue }
            var p = BatteryProfile()
            p.condition = h["sppower_battery_health"] as? String
            if let cap = h["sppower_battery_health_maximum_capacity"] as? String {
                p.maxCapacityPercent = Double(cap.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
            } else if let n = h["sppower_battery_health_maximum_capacity"] as? NSNumber { p.maxCapacityPercent = n.doubleValue }
            return p.condition == nil && p.maxCapacityPercent == nil ? nil : p
        }
        return nil
    }
}

/// Cache profilu baterii (1 h). Wywołanie `system_profiler` trwa ~0,1–1 s, więc nie robimy go przy każdej próbce.
actor BatteryProfileCache {
    private(set) var value: BatteryProfile?
    private(set) var fetchedAt = Date.distantPast
    let ttl: TimeInterval
    init(ttl: TimeInterval = 3600) { self.ttl = ttl }

    func current(now: Date, hasBattery: Bool) async -> BatteryProfile? {
        guard hasBattery else { return nil }
        if now.timeIntervalSince(fetchedAt) < ttl { return value }
        fetchedAt = now                                              // także przy błędzie – nie ponawiamy co próbkę
        let r = await CommandRunner.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"], timeout: 20)
        if r.status == 0, let p = BatteryProfile.parse(r.output) { value = p }
        return value
    }
}
#endif
