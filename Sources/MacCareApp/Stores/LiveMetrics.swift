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
    /// Audyt 2 (4.5): rzadko zmieniane fakty dla dużych widoków (lista Porządków, mapa) – osobny obiekt, publikuje tylko przy realnej zmianie.
    let disk = LiveDiskFacts()

    func update(snapshot s: SystemSnapshot, evidence: [Evidence]) {
        var n = state
        n.snapshot = s
        n.assessment = HealthAssessment.assess(s)
        n.evidenceByID = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let c = s.cpu { Self.push(&n.cpuLive, c.totalPercent) }
        if let m = s.memory, m.total > 0 { Self.push(&n.memLive, Double(m.used) / Double(m.total) * 100) }
        state = n
        disk.update(s)
    }

    private static func push(_ a: inout [Double], _ v: Double) { a.append(v); if a.count > 90 { a.removeFirst(a.count - 90) } }
}

/// Audyt 2 (4.5): liczba lokalnych migawek i dysk startowy. Lista Porządków (setki wierszy) i mapa obserwują tylko ten obiekt, więc nie są
/// przeliczane co 2 s. Wolne miejsce publikowane dopiero po zmianie o co najmniej 0,1% pojemności (dokładność paska w stopce).
@MainActor
final class LiveDiskFacts: ObservableObject {
    @Published private(set) var localSnapshotCount: Int?                            // audyt 3: nil = nie udało się odczytać (nie „0 migawek”)
    @Published private(set) var bootVolume: VolumeStats?

    func update(_ s: SystemSnapshot) {
        let n = s.localSnapshots?.count
        if n != localSnapshotCount { localSnapshotCount = n }
        if let v = s.bootVolume, Self.differs(v, bootVolume) { bootVolume = v }
    }

    nonisolated static func differs(_ a: VolumeStats, _ b: VolumeStats?) -> Bool {
        guard let b else { return true }
        let step = max(a.total / 1000, 1)
        let diff = a.availableImportant > b.availableImportant ? a.availableImportant - b.availableImportant : b.availableImportant - a.availableImportant
        return a.name != b.name || a.mountPoint != b.mountPoint || a.total != b.total || diff >= step
    }
}
