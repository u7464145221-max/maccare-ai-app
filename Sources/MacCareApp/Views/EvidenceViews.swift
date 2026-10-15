import SwiftUI
import MacCareCore

/// Chip z identyfikatorem dowodu; klik pokazuje pomiar (źródło, wartość, czas). Gdy dowodu nie ma w bieżącej migawce – mówi to wprost.
struct EvidenceChip: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 9, weight: .semibold))
                Text(id).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(minHeight: 28)
            .background(Theme.Palette.surfaceAlt, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Pokaż dowód (pomiar)")
        .popover(isPresented: $shown, arrowEdge: .bottom) { EvidencePopover(id: id).environmentObject(model) }
    }
}

struct EvidencePopover: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let e = model.evidence(id) {
                Text(e.label).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text(e.value).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.accent)
                Divider()
                row(String(localized: "Identyfikator"), e.id)
                row(String(localized: "Źródło pomiaru"), e.source)
                row(String(localized: "Zmierzono"), e.measuredAt.formatted(date: .abbreviated, time: .standard))
                if e.synthetic { Pill(text: String(localized: "Dane testowe (synthetic)"), color: Theme.Palette.hypothesis, symbol: "flask") }
            } else {
                Text("Brak dowodu w bieżącej migawce").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text("Identyfikator „\(id)” nie występuje wśród aktualnych pomiarów. Wniosek opiera się na danych, których panel nie potrafi teraz pokazać.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(Theme.Space.l).frame(width: 320, alignment: .leading)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary).frame(width: 100, alignment: .leading)
            Text(v).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.text).textSelection(.enabled)
        }
    }
}

/// Układ chipów/legendy zawijany do kolejnych wierszy (nic nie jest ucinane ani chowane w poziomym przewijaniu).
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = Theme.Space.xs
    var lineSpacing: CGFloat = Theme.Space.xs
    @ViewBuilder var content: Content
    var body: some View { WrapLayout(spacing: spacing, lineSpacing: lineSpacing) { content } }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    /// Podział na wiersze (indeksy elementów): element zaczyna nowy wiersz, gdy by się nie zmieścił; za szeroki element dostaje własny wiersz.
    static func breakRows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [], current: [Int] = [], x: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !current.isEmpty, x + spacing + w > maxWidth { rows.append(current); current = []; x = 0 }
            x += (current.isEmpty ? 0 : spacing) + w
            current.append(i)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let maxW = proposal.width ?? .infinity
        let rows = Self.breakRows(widths: sizes.map { $0.width }, maxWidth: maxW, spacing: spacing)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for (n, r) in rows.enumerated() {
            var rowW: CGFloat = 0
            var rowH: CGFloat = 0
            for i in r { rowW += sizes[i].width; rowH = max(rowH, sizes[i].height) }
            rowW += spacing * CGFloat(max(0, r.count - 1))
            width = max(width, rowW)
            height += rowH + (n > 0 ? lineSpacing : 0)
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = Self.breakRows(widths: sizes.map { $0.width }, maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for r in rows {
            var x = bounds.minX
            let h = r.map { sizes[$0].height }.max() ?? 0
            for i in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += h + lineSpacing
        }
    }
}
