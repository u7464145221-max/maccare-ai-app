#if os(macOS)
import Foundation
import MacCareCore

/// Lokalne migawki Time Machine (`tmutil listlocalsnapshotdates /`, tylko odczyt). Migawki trzymają bloki usuniętych plików,
/// więc tłumaczą, dlaczego „odzyskiwalne” miejsce bywa dużo mniejsze niż „zajęte” (potwierdzone pomiarem na prawdziwym Macu).
public enum LocalSnapshotCollector {
    /// Linie `2026-10-03-143342` → daty (czas lokalny). Nagłówki i inne linie są ignorowane.
    public static func parse(_ output: String) -> [Date] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = .current
        return output.split(separator: "\n").compactMap { f.date(from: $0.trimmingCharacters(in: .whitespaces)) }.sorted()
    }

    /// nil = nie udało się ustalić (np. brak Time Machine/uprawnień); pusta tablica = brak migawek.
    public static func collect() async -> [Date]? {
        let r = await CommandRunner.run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], timeout: 15)
        guard r.status == 0, !r.timedOut else { return nil }
        return parse(r.output)
    }
}
#endif
