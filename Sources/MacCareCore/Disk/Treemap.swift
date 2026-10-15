import Foundation

/// Prostokąt mapy (bez zależności od CoreGraphics – rdzeń działa też poza macOS).
public struct TreemapRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var area: Double { width * height }
}

/// F11 (Radix): mapa prostokątów „squarified” (Bruls, Huizing, van Wijk 2000) – pole każdego prostokąta proporcjonalne do rozmiaru,
/// proporcje boków możliwie bliskie kwadratu (łatwo porównać i podpisać). Wejście: rozmiary posortowane malejąco; zera pomijane (pusty prostokąt).
public enum Treemap {
    public static func squarify(_ sizes: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        var out = [TreemapRect](repeating: TreemapRect(x: bounds.x, y: bounds.y, width: 0, height: 0), count: sizes.count)
        let total = sizes.reduce(0) { $0 + max(0, $1) }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return out }
        let scale = bounds.area / total
        let items = sizes.enumerated().filter { $0.element > 0 }.map { (index: $0.offset, area: $0.element * scale) }
        var free = bounds
        var row: [(index: Int, area: Double)] = []
        var i = 0
        while i < items.count {
            let side = min(free.width, free.height)
            let candidate = row + [items[i]]
            if row.isEmpty || worst(candidate, side) <= worst(row, side) {
                row = candidate; i += 1
            } else {
                free = layout(row, in: free, into: &out); row = []
            }
        }
        if !row.isEmpty { _ = layout(row, in: free, into: &out) }
        return out
    }

    /// Najgorsza proporcja boków w wierszu ułożonym wzdłuż boku `side`.
    static func worst(_ row: [(index: Int, area: Double)], _ side: Double) -> Double {
        let s = row.reduce(0) { $0 + $1.area }
        guard s > 0, side > 0, let mx = row.map(\.area).max(), let mn = row.map(\.area).min(), mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }

    /// Układa wiersz wzdłuż krótszego boku wolnego obszaru; zwraca pozostały obszar.
    static func layout(_ row: [(index: Int, area: Double)], in free: TreemapRect, into out: inout [TreemapRect]) -> TreemapRect {
        let s = row.reduce(0) { $0 + $1.area }
        if free.width >= free.height {                                    // wiersz jako kolumna przy lewej krawędzi
            let w = s / free.height
            var y = free.y
            for r in row { let h = r.area / w; out[r.index] = TreemapRect(x: free.x, y: y, width: w, height: h); y += h }
            return TreemapRect(x: free.x + w, y: free.y, width: max(0, free.width - w), height: free.height)
        } else {                                                          // wiersz przy górnej krawędzi
            let h = s / free.width
            var x = free.x
            for r in row { let w = r.area / h; out[r.index] = TreemapRect(x: x, y: free.y, width: w, height: h); x += w }
            return TreemapRect(x: free.x, y: free.y + h, width: free.width, height: max(0, free.height - h))
        }
    }
}
