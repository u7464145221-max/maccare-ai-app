import Foundation

/// 17.10 (decyzja właściciela „4 tak”): tempo zapełniania dysku startowego z zapisanych próbek wolnego miejsca (`disk.free`, co pomiar; po 7 dniach
/// średnie godzinowe). Prosta regresja liniowa z ostatnich dni – to szacunek, nie pomiar przyszłości; za mało danych = nil (nie „wszystko OK”).
public struct DiskTrend: Equatable, Sendable {
    /// Wolne miejsce w ostatniej próbce.
    public var freeBytes: Double
    /// Wolne miejsce w pierwszej próbce okna (zmierzona zmiana = `freeBytes - firstFreeBytes`, bez regresji).
    public var firstFreeBytes: Double = 0
    /// Zmiana wolnego miejsca na dobę (ujemna = dysk się zapełnia).
    public var bytesPerDay: Double
    /// Okres, z którego policzono tempo.
    public var span: TimeInterval
    public var since: Date

    /// Minimalny okres danych, żeby mówić o tempie (krótszy – za duży wpływ jednorazowych pobrań i Kosza).
    public static let minSpan: TimeInterval = 2 * 86400
    /// Ostrzeżenie: zapełnienie przewidywane w ciągu 14 dni albo mniej niż `ImportantNotices.lowDiskBytes` wolnego.
    public static let warnDays: Double = 14

    /// Za ile dni zabraknie miejsca przy obecnym tempie (nil – dysk się nie zapełnia).
    public var daysToFull: Double? { bytesPerDay < 0 ? freeBytes / -bytesPerDay : nil }

    /// Audyt 3: prognoza dopiero z co najmniej 3 dni danych – jednorazowe duże pobranie w krótkim oknie dawało fałszywe „skończy się za 9 dni”.
    public static let forecastMinSpan: TimeInterval = 3 * 86400
    public var isLow: Bool { freeBytes < Double(ImportantNotices.lowDiskBytes) }
    public var isWarning: Bool {
        isLow || (span >= Self.forecastMinSpan && (daysToFull.map { $0 < Self.warnDays } ?? false))
    }
    /// Zmierzona zmiana wolnego miejsca w oknie (ujemna = ubyło) – tylko gdy okno obejmuje co najmniej 5 dni („w tym tygodniu”).
    public var weeklyMeasuredChange: Double? { span >= 5 * 86400 ? freeBytes - firstFreeBytes : nil }

    /// - Parameter samples: (czas, wolne bajty), dowolna kolejność; brane są tylko z ostatnich `window` sekund.
    public static func compute(_ samples: [(Date, Double)], now: Date, window: TimeInterval = 7 * 86400) -> DiskTrend? {
        let pts = samples.filter { $0.0 <= now && now.timeIntervalSince($0.0) <= window && $0.1 >= 0 }.sorted { $0.0 < $1.0 }
        guard pts.count >= 3, let first = pts.first, let last = pts.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= minSpan else { return nil }
        let xs = pts.map { $0.0.timeIntervalSince(first.0) / 86400 }, ys = pts.map(\.1)
        let n = Double(pts.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        guard den > 0 else { return nil }
        return DiskTrend(freeBytes: last.1, firstFreeBytes: first.1, bytesPerDay: num / den, span: span, since: first.0)
    }

    /// Jedno zdanie do paska menu i powiadomień.
    public var summary: String {
        if isLow { return String(localized: "Mało wolnego miejsca: \(ByteFormat.string(UInt64(max(0, freeBytes)))).") }
        if span >= Self.forecastMinSpan, let d = daysToFull, d < 365 {
            let days = Int(d.rounded())
            return days < 1 ? String(localized: "Przy obecnym tempie miejsce skończy się w ciągu doby.")
                            : String(localized: "Przy obecnym tempie miejsce skończy się za ok. \(PolishPlural.counted(days, one: "dzień", few: "dni", many: "dni")).")
        }
        return bytesPerDay < 0 ? String(localized: "Dysk zapełnia się powoli.") : String(localized: "Wolnego miejsca nie ubywa.")
    }
}

/// 17.10 (decyzja właściciela „5 tak”): tygodniowe podsumowanie „co urosło”. Źródła: tempo z próbek wolnego miejsca i – jeśli mapa dysku ma
/// wcześniejszy pomiar katalogu domowego – foldery, które urosły najbardziej. Bez nowego skanu w tle (właściciel: nie przeciążać Maca).
public enum WeeklyGrowth {
    public static let kind = "weekly.growth"
    public static let interval: TimeInterval = 7 * 86400
    /// Pomijalna zmiana tygodniowa (mniej niż 1 GB i brak folderów) – bez powiadomienia.
    public static let minWeeklyChange: Double = 1_000_000_000

    public struct Grown: Equatable, Sendable { public var name: String; public var delta: Int64; public init(name: String, delta: Int64) { self.name = name; self.delta = delta } }

    /// - Parameters:
    ///   - grown: foldery, które urosły od pomiaru z dnia `grownSince` (nil = brak porównywalnego pomiaru).
    public static func notice(trend: DiskTrend?, grown: [Grown], grownSince: Date? = nil, lastSent: Date?, now: Date) -> Notice? {
        if let l = lastSent, now.timeIntervalSince(l) < interval { return nil }
        let top = grown.filter { $0.delta > 0 }.sorted { $0.delta > $1.delta }.prefix(3)
        let change = trend?.weeklyMeasuredChange                                            // audyt 3: zmierzona różnica, nie nachylenie prostej × 7
        guard !top.isEmpty || (change.map { $0.magnitude >= minWeeklyChange } ?? false) else { return nil }
        var parts: [String] = []
        if let c = change, c.magnitude >= minWeeklyChange {
            let b = ByteFormat.string(UInt64(c.magnitude))
            parts.append(c < 0 ? String(localized: "W tym tygodniu ubyło ok. \(b) wolnego miejsca.") : String(localized: "W tym tygodniu przybyło ok. \(b) wolnego miejsca."))
        }
        if let t = trend, t.isWarning { parts.append(t.summary) }
        if !top.isEmpty {
            let list = top.map { "\($0.name) +\(ByteFormat.string(UInt64($0.delta)))" }.joined(separator: ", ")
            if let since = grownSince {
                parts.append(String(localized: "Najbardziej urosły od \(since.formatted(date: .abbreviated, time: .omitted)): \(list)."))
            } else {
                parts.append(String(localized: "Najbardziej urosły: \(list)."))
            }
        }
        return Notice(kind: kind, title: String(localized: "Co urosło w tym tygodniu"), body: parts.joined(separator: " "))
    }
}

/// 17.10 (decyzja właściciela „6 tak”): automatyczny Smart Scan. Domyślnie wyłączony. Działa tylko, gdy MacCare jest uruchomiony
/// (bez agenta logowania i usług w tle), wyłącznie odczyt – nic nie jest czyszczone.
public enum SmartScanSchedule: String, CaseIterable, Sendable {
    case off, daily, weekly
    public static let storageKey = "smartScan.schedule"
    public static let lastRunKey = "smartScan.lastAuto"

    public var interval: TimeInterval? {
        switch self { case .off: return nil; case .daily: return 86400; case .weekly: return 7 * 86400 }
    }

    /// Czy pora na automatyczny skan. Pierwsze uruchomienie po włączeniu – nie od razu, tylko po upływie okresu od `enabledAt`.
    public func isDue(lastRun: Date?, enabledAt: Date?, now: Date) -> Bool {
        guard let i = interval else { return false }
        guard let ref = lastRun ?? enabledAt else { return false }
        return now.timeIntervalSince(ref) >= i || now < ref                                   // zegar cofnięty – licz od nowa przy najbliższej okazji
    }

    public static func summaryNotice(health: Int?, issues: Int, safeReclaimable: UInt64, complete: Bool) -> Notice {
        var parts: [String] = []
        if let h = health { parts.append(String(localized: "Ocena \(h)/100.")) } else { parts.append(String(localized: "Ocena: brak danych.")) }
        parts.append(issues == 0 ? String(localized: "Nic nie wymaga uwagi.") : String(localized: "Do sprawdzenia: \(issues)."))
        if safeReclaimable > 0 { parts.append(String(localized: "Bezpiecznie do odzyskania: \(ByteFormat.string(safeReclaimable)).")) }
        if !complete { parts.append(String(localized: "Skan był niepełny – część miejsc nie została sprawdzona.")) }
        parts.append(String(localized: "Nic nie zostało usunięte."))
        return Notice(kind: "smartscan.summary", title: String(localized: "Smart Scan – podsumowanie"), body: parts.joined(separator: " "))
    }
}
