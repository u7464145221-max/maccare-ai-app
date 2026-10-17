import Foundation
import SwiftUI
import MacCareCore

/// Audyt 16.10 (P2 „AppModel jako jeden wielki obiekt”): dane odświeżane co 2 s (migawka systemu, ocena, dowody, wykresy CPU/pamięci) w OSOBNYM
/// obiekcie. Obserwują go tylko widoki, które je pokazują – pozostałe (pasek boczny, Historia, Ustawienia, Aplikacje, Asystent…) nie są
/// przeliczane przy każdym pomiarze. Jedna publikacja na pomiar zamiast pięciu.
@MainActor
final class LiveMetrics: ObservableObject {
    struct State {
        var snapshot: SystemSnapshot?
        var assessment: HealthAssessment?
        var evidenceByID: [String: Evidence] = [:]
        var cpuLive: [Double] = []
        var memLive: [Double] = []
    }
    @Published private(set) var state = State()

    func update(snapshot s: SystemSnapshot, evidence: [Evidence]) {
        var n = state
        n.snapshot = s
        n.assessment = HealthAssessment.assess(s)
        n.evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let c = s.cpu { Self.push(&n.cpuLive, c.totalPercent) }
        if let m = s.memory, m.total > 0 { Self.push(&n.memLive, Double(m.used) / Double(m.total) * 100) }
        state = n
    }

    private static func push(_ a: inout [Double], _ v: Double) { a.append(v); if a.count > 90 { a.removeFirst(a.count - 90) } }
}
