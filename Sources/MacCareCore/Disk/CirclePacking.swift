import Foundation

/// Okrąg w układzie względnym (środek największego = (0,0)).
public struct PackedCircle: Sendable, Equatable {
    public var x: Double, y: Double, r: Double
    public var index: Int
}

/// Upakowanie okręgów do mapy dysku („bąbel w bąblu”). Własny algorytm zachłanny: kolejne okręgi (od największego) są
/// układane **stycznie do dwóch już położonych**, a z dopuszczalnych pozycji wybierana jest ta najbliższa środkowi.
/// Daje zwarty, okrągły układ z największym elementem w centrum. Złożoność O(n⁴) w najgorszym razie – dla n ≤ ~100 pomijalna.
public enum CirclePacking {
    /// - Parameters:
    ///   - radii: promienie w kolejności układania (zalecane malejąco). Wartości ≤ 0 są podnoszone do minimalnego dodatniego.
    ///   - gap: odstęp między okręgami.
    /// - Returns: okręgi w tej samej kolejności co `radii`.
    public static func pack(radii input: [Double], gap: Double = 0) -> [PackedCircle] {
        guard !input.isEmpty else { return [] }
        let floor = (input.max() ?? 1) * 1e-6
        let radii = input.map { max($0, floor) }
        var placed: [PackedCircle] = [PackedCircle(x: 0, y: 0, r: radii[0], index: 0)]
        guard radii.count > 1 else { return placed }
        placed.append(PackedCircle(x: radii[0] + radii[1] + gap, y: 0, r: radii[1], index: 1))
        let eps = 1e-9

        for k in 2..<radii.count {
            let r = radii[k]
            var best: (x: Double, y: Double, score: Double)?
            for i in 0..<placed.count {
                for j in (i + 1)..<placed.count {
                    for (x, y) in tangentPositions(placed[i], placed[j], r: r, gap: gap) {
                        guard !overlaps(x, y, r, placed, gap: gap, eps: eps) else { continue }
                        let score = hypot(x, y) + r * 0.001                 // najbliżej środka; promień tylko rozstrzyga remisy
                        if best == nil || score < best!.score { best = (x, y, score) }
                    }
                }
            }
            if let b = best { placed.append(PackedCircle(x: b.x, y: b.y, r: r, index: k)) }
            else {                                                         // awaryjnie (nie powinno się zdarzyć): obok najdalszego
                let far = placed.max { hypot($0.x, $0.y) + $0.r < hypot($1.x, $1.y) + $1.r }!
                placed.append(PackedCircle(x: far.x + far.r + r + gap, y: far.y, r: r, index: k))
            }
        }
        return placed
    }

    /// Dwie pozycje styczne jednocześnie do `a` i `b` (przecięcie okręgów o promieniach ra+r+gap i rb+r+gap).
    static func tangentPositions(_ a: PackedCircle, _ b: PackedCircle, r: Double, gap: Double) -> [(Double, Double)] {
        let ra = a.r + r + gap, rb = b.r + r + gap
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        guard d > 1e-12, d <= ra + rb, d >= abs(ra - rb) else { return [] }
        let t = (ra * ra - rb * rb + d * d) / (2 * d)
        let h2 = ra * ra - t * t
        guard h2 >= 0 else { return [] }
        let h = h2.squareRoot()
        let mx = a.x + t * dx / d, my = a.y + t * dy / d
        return [(mx + h * dy / d, my - h * dx / d), (mx - h * dy / d, my + h * dx / d)]
    }

    static func overlaps(_ x: Double, _ y: Double, _ r: Double, _ placed: [PackedCircle], gap: Double, eps: Double) -> Bool {
        for c in placed where hypot(c.x - x, c.y - y) < c.r + r + gap - eps { return true }
        return false
    }

    /// Okrąg otaczający wszystkie okręgi (przybliżenie Bădoiu–Clarkson, dokładność ~0,1%).
    public static func enclosing(_ circles: [PackedCircle]) -> (x: Double, y: Double, r: Double) {
        guard !circles.isEmpty else { return (0, 0, 0) }
        var cx = circles.reduce(0) { $0 + $1.x } / Double(circles.count)
        var cy = circles.reduce(0) { $0 + $1.y } / Double(circles.count)
        for i in 1...400 {
            let far = circles.max { hypot($0.x - cx, $0.y - cy) + $0.r < hypot($1.x - cx, $1.y - cy) + $1.r }!
            let dx = far.x - cx, dy = far.y - cy
            let dist = hypot(dx, dy)
            guard dist > 1e-12 else { break }
            let step = 1.0 / Double(i + 1)
            cx += dx / dist * max(0, dist) * step
            cy += dy / dist * max(0, dist) * step
        }
        let r = circles.map { hypot($0.x - cx, $0.y - cy) + $0.r }.max() ?? 0
        return (cx, cy, r)
    }

    /// Promienie proporcjonalne do pierwiastka rozmiaru (pole ∝ rozmiar), z dolnym ograniczeniem czytelności.
    public static func radii(forSizes sizes: [UInt64], minFraction: Double = 0.07) -> [Double] {
        guard let mx = sizes.max(), mx > 0 else { return sizes.map { _ in 1 } }
        return sizes.map { max(Double($0).squareRoot() / Double(mx).squareRoot(), minFraction) }
    }
}
