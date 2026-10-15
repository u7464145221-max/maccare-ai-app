import Foundation

/// Jawna metodologia oceny (opisana w docs/METODOLOGIA.md).
///
/// Zasady:
/// 1. Ocena składa się z komponentów. Każdy komponent liczony jest WYŁĄCZNIE z pomiarów.
/// 2. Brak danych ⇒ komponent jest wyłączony z oceny i oznaczony „brak danych” (nie dostaje 100 punktów).
/// 3. Każda odjęta wartość ma powód i identyfikator dowodu.
/// 4. Wynik ogólny = średnia ważona dostępnych komponentów. Gdy dostępnych wag < 50%, wynik ogólny = nil.
public struct HealthAssessment: Codable, Sendable {
    public struct Deduction: Codable, Sendable, Hashable {
        public var points: Int
        public var reason: String
        public var evidenceID: String
    }
    public struct Component: Codable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var weight: Double
        public var score: Int?               // nil = brak danych
        public var deductions: [Deduction]
        public var note: String?
    }
    public var components: [Component]
    public var overall: Int?
    public var coverage: Double              // udział wag z danymi (0…1)
    public static let methodologyVersion = "1.0"

    public static func assess(_ s: SystemSnapshot) -> HealthAssessment {
        var comps: [Component] = []

        // Dysk (waga 0.25): wolne miejsce na dysku startowym.
        if let v = s.bootVolume, v.total > 0 {
            var d: [Deduction] = []
            let f = v.freeFraction
            if f < 0.05 { d.append(.init(points: 70, reason: String(localized: "Wolne < 5%"), evidenceID: "disk.free")) }
            else if f < 0.10 { d.append(.init(points: 45, reason: String(localized: "Wolne < 10%"), evidenceID: "disk.free")) }
            else if f < 0.15 { d.append(.init(points: 25, reason: String(localized: "Wolne < 15%"), evidenceID: "disk.free")) }
            else if f < 0.25 { d.append(.init(points: 10, reason: String(localized: "Wolne < 25%"), evidenceID: "disk.free")) }
            comps.append(component("storage", "Dysk", 0.25, d))
        } else { comps.append(Component(id: "storage", title: String(localized: "Dysk"), weight: 0.25, score: nil, deductions: [], note: String(localized: "brak danych"))) }

        // Pamięć (0.25): ciśnienie pamięci (wskaźnik systemowy) + swap jako sygnał pomocniczy.
        if let m = s.memory {
            var d: [Deduction] = []
            switch m.pressure {
            case .critical: d.append(.init(points: 60, reason: String(localized: "Krytyczne ciśnienie pamięci"), evidenceID: "mem.pressure"))
            case .warning: d.append(.init(points: 30, reason: String(localized: "Podwyższone ciśnienie pamięci"), evidenceID: "mem.pressure"))
            case .normal: break
            }
            if m.total > 0 {
                let ratio = Double(m.swapUsed) / Double(m.total)
                if ratio > 0.5 { d.append(.init(points: 15, reason: String(localized: "Swap > 50% RAM"), evidenceID: "mem.swap")) }
                else if ratio > 0.25 { d.append(.init(points: 5, reason: String(localized: "Swap > 25% RAM"), evidenceID: "mem.swap")) }
            }
            comps.append(component("memory", "Pamięć", 0.25, d))
        } else { comps.append(Component(id: "memory", title: String(localized: "Pamięć"), weight: 0.25, score: nil, deductions: [], note: String(localized: "brak danych"))) }

        // Procesor i temperatura (0.15): stan termiczny i obciążenie chwilowe (sygnał słaby – mała kara).
        if s.cpu != nil || s.thermal != nil {
            var d: [Deduction] = []
            if let th = s.thermal {
                if th == .critical { d.append(.init(points: 60, reason: String(localized: "Krytyczny stan termiczny"), evidenceID: "thermal.state")) }
                else if th == .serious { d.append(.init(points: 35, reason: String(localized: "Ograniczanie wydajności (throttling)"), evidenceID: "thermal.state")) }
                else if th == .fair { d.append(.init(points: 5, reason: String(localized: "Podwyższona temperatura"), evidenceID: "thermal.state")) }
            }
            if let c = s.cpu, c.totalPercent > 90 { d.append(.init(points: 10, reason: String(localized: "CPU > 90% w chwili pomiaru"), evidenceID: "cpu.total")) }
            comps.append(component("cpu", "Procesor i temperatura", 0.15, d))
        } else { comps.append(Component(id: "cpu", title: String(localized: "Procesor i temperatura"), weight: 0.15, score: nil, deductions: [], note: String(localized: "brak danych"))) }

        // Bezpieczeństwo (0.25): tylko stany ODCZYTANE. Nieznane nie są karane.
        if let p = s.security {
            var d: [Deduction] = []
            if p.sip == .disabled { d.append(.init(points: 40, reason: String(localized: "SIP wyłączony"), evidenceID: "sec.sip")) }
            if p.gatekeeper == .disabled { d.append(.init(points: 30, reason: String(localized: "Gatekeeper wyłączony"), evidenceID: "sec.gatekeeper")) }
            if p.fileVault == .disabled { d.append(.init(points: 20, reason: String(localized: "FileVault wyłączony"), evidenceID: "sec.filevault")) }
            if p.firewall == .disabled { d.append(.init(points: 5, reason: String(localized: "Zapora wyłączona"), evidenceID: "sec.firewall")) }
            let known = [p.sip, p.gatekeeper, p.fileVault, p.firewall].filter { $0 != .unknown }.count
            var c = component("security", "Bezpieczeństwo", 0.25, d)
            if known == 0 { c.score = nil; c.note = String(localized: "brak danych") } else if known < 4 { c.note = String(localized: "odczytano \(known) z 4 ustawień") }
            comps.append(c)
        } else { comps.append(Component(id: "security", title: String(localized: "Bezpieczeństwo"), weight: 0.25, score: nil, deductions: [], note: String(localized: "brak danych"))) }

        // Bateria (0.10): tylko w laptopach.
        if let b = s.battery {
            var d: [Deduction] = []
            if let h = b.healthPercent {
                if h < 60 { d.append(.init(points: 50, reason: String(localized: "Kondycja < 60%"), evidenceID: "bat.health")) }
                else if h < 80 { d.append(.init(points: 25, reason: String(localized: "Kondycja < 80%"), evidenceID: "bat.health")) }
            }
            if let cond = b.condition?.lowercased(), cond.contains("service") { d.append(.init(points: 30, reason: String(localized: "System zaleca serwis"), evidenceID: "bat.condition")) }
            var c = component("battery", "Bateria", 0.10, d)
            if b.healthPercent == nil && b.condition == nil { c.score = nil; c.note = String(localized: "system nie udostępnia kondycji") }
            comps.append(c)
        }

        let avail = comps.filter { $0.score != nil }
        let totalW = comps.reduce(0) { $0 + $1.weight }
        let availW = avail.reduce(0) { $0 + $1.weight }
        let coverage = totalW > 0 ? availW / totalW : 0
        var overall: Int? = nil
        if coverage >= 0.5, availW > 0 {
            overall = Int((avail.reduce(0.0) { $0 + Double($1.score!) * $1.weight } / availW).rounded())
        }
        return HealthAssessment(components: comps, overall: overall, coverage: coverage)
    }

    private static func component(_ id: String, _ title: String, _ w: Double, _ d: [Deduction]) -> Component {
        Component(id: id, title: title, weight: w, score: max(0, 100 - d.reduce(0) { $0 + $1.points }), deductions: d, note: nil)
    }
}
