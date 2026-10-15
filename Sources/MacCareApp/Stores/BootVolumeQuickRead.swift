import Foundation
import MacCareCore

/// Szybki odczyt zajętości dysku startowego (jedno zapytanie o zasoby wolumenu `/`, bez skanowania plików) – stopka „Moje pliki” nie zależy od skanu folderu
/// ani od pierwszego pełnego pomiaru systemu. Tylko odczyt.
enum BootVolumeQuickRead {
    static func read() -> VolumeStats? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys), let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return VolumeStats(mountPoint: "/", name: v.volumeName ?? String(localized: "Dysk"), total: UInt64(total),
                           availableImportant: UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0)),
                           availableStrict: UInt64(max(0, v.volumeAvailableCapacity ?? 0)))
    }
}
