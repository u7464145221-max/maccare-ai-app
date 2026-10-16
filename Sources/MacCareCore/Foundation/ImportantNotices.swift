import Foundation

/// Powiadomienie systemowe o ważnej sprawie (decyzja właściciela 15.10.2026: tylko ważne, najwyżej raz na dobę na rodzaj, domyślnie wyłączone).
public struct Notice: Equatable, Sendable {
    /// Rodzaj – klucz ograniczenia częstotliwości (np. `disk.low`, `update.v0.2.0`).
    public var kind: String
    public var title: String
    public var body: String
}

/// Decyzja, co powiadomić – czysta funkcja (bez zegara, sieci i systemu powiadomień), żeby dało się ją sprawdzić testem.
public enum ImportantNotices {
    /// Mało miejsca: mniej niż 10 GB dostępnych na wolumenie katalogu domowego.
    public static let lowDiskBytes: Int64 = 10_000_000_000
    /// Najwyżej jedno powiadomienie danego rodzaju na dobę.
    public static let minInterval: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - freeBytes: dostępne miejsce (nil = nieznane – bez powiadomienia, brak danych to nie alarm).
    ///   - findings: bieżące ustalenia; liczą się tylko krytyczne z kategorii Ochrona.
    ///   - newVersion: znacznik nowszego wydania, jeśli sprawdzanie aktualizacji je znalazło (każda wersja – raz).
    ///   - lastSent: kiedy ostatnio wysłano dany rodzaj.
    public static func due(freeBytes: Int64?, findings: [Finding], newVersion: String?, lastSent: [String: Date], now: Date) -> [Notice] {
        var out: [Notice] = []
        func allowed(_ kind: String) -> Bool { lastSent[kind].map { now.timeIntervalSince($0) >= minInterval } ?? true }
        if let free = freeBytes, free >= 0, free < lowDiskBytes, allowed("disk.low") {
            out.append(Notice(kind: "disk.low", title: String(localized: "Mało miejsca na dysku"),
                              body: String(localized: "Zostało \(ByteFormat.string(UInt64(free))). Porządki w MacCare pokażą, co można bezpiecznie przenieść do Kosza.")))
        }
        let critical = findings.filter { $0.category == .security && $0.severity == .critical }.sorted { $0.id < $1.id }
        if let first = critical.first, allowed("security.critical") {
            let more = critical.count > 1 ? String(localized: " (i \(critical.count - 1) więcej)") : ""
            out.append(Notice(kind: "security.critical", title: String(localized: "Ochrona: wymaga uwagi"), body: first.title + more))
        }
        if let v = newVersion, !v.isEmpty, lastSent["update." + v] == nil {
            out.append(Notice(kind: "update." + v, title: String(localized: "Dostępna nowa wersja MacCare"),
                              body: String(localized: "Wersja \(v) jest na stronie wydań. MacCare niczego nie pobiera sam – otwórz Ustawienia → Aktualizacje.")))
        }
        return out
    }
}
