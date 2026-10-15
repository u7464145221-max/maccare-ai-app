import SwiftUI
import AppKit
import MacCareCore

/// System wizualny MacCare AI: wszystkie kolory, typografia, odstępy i bazowe komponenty w jednym pliku.
/// Kolory są dynamiczne (jasny/ciemny); pary dobrano tak, by tekst na tle miał kontrast ≥ 4,5:1.
enum Theme {
    // MARK: Kolory
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
    /// Wartości hex tokenów (jasny/ciemny). Jedno źródło prawdy: z nich powstają kolory, a `ContrastTests` liczy z nich kontrast WCAG.
    enum PaletteHex {
        struct Pair {
            let light: UInt32, dark: UInt32
            func value(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
        }
        static let background = Pair(light: 0xF4F5F8, dark: 0x12151A)       // tło okna (bez zabarwienia modułu)
        static let surface = Pair(light: 0xFFFFFF, dark: 0x22272E)          // karty
        static let surfaceAlt = Pair(light: 0xE9ECF1, dark: 0x2D333C)       // pola, zaznaczone wiersze, tła pastylek
        static let sidebar = Pair(light: 0xE8EBF0, dark: 0x0E1115)
        static let stroke = Pair(light: 0x79828F, dark: 0x6F7683)           // obrys karty: ≥ 3:1 względem tła okna (także zabarwionego)
        static let hairline = Pair(light: 0xD3D8DF, dark: 0x343A44)         // separatory – nie niosą informacji
        static let text = Pair(light: 0x12151A, dark: 0xF1F3F6)
        static let textSecondary = Pair(light: 0x4B5361, dark: 0xB4BBC6)
        static let textTertiary = Pair(light: 0x565F6E, dark: 0x9AA3B0)     // też ≥ 4,5:1 – nie jaśniejsza szarość
        static let accent = Pair(light: 0x0A6B65, dark: 0x3CCBC0)
        static let ok = Pair(light: 0x156B3A, dark: 0x45D88F)
        static let warning = Pair(light: 0x8A5600, dark: 0xF6B94A)
        static let critical = Pair(light: 0xB42318, dark: 0xFF7A70)
        static let info = Pair(light: 0x1F5FA8, dark: 0x6CB6F0)
        static let hypothesis = Pair(light: 0x5B3FB5, dark: 0xB89CF7)
        /// Stan wyłączony (U1b): własne tokeny zamiast przezroczystości – etykieta ≥ 4,5:1 na wypełnieniu, obrys ≥ 3:1 względem tła.
        static var disabledFill: Pair { surfaceAlt }
        static var disabledLabel: Pair { textSecondary }
        static var disabledOutline: Pair { stroke }
        /// Przezroczystość koloru modułu w „poświacie” u góry okna (delikatny akcent, nie zalew powierzchni).
        static func wash(dark: Bool) -> Double { dark ? 0.12 : 0.10 }
        /// Zabarwienie paska bocznego kolorem modułu.
        static let sidebarTintAlpha = 0.10
    }

    enum Palette {
        static let background = dynamic(PaletteHex.background)
        static let surface = dynamic(PaletteHex.surface)
        static let surfaceAlt = dynamic(PaletteHex.surfaceAlt)
        static let sidebar = dynamic(PaletteHex.sidebar)
        static let stroke = dynamic(PaletteHex.stroke)
        static let hairline = dynamic(PaletteHex.hairline)
        static let text = dynamic(PaletteHex.text)
        static let textSecondary = dynamic(PaletteHex.textSecondary)
        static let textTertiary = dynamic(PaletteHex.textTertiary)
        static let accent = dynamic(PaletteHex.accent)
        static let ok = dynamic(PaletteHex.ok)
        static let warning = dynamic(PaletteHex.warning)
        static let critical = dynamic(PaletteHex.critical)
        static let info = dynamic(PaletteHex.info)
        static let hypothesis = dynamic(PaletteHex.hypothesis)
        static let disabledFill = dynamic(PaletteHex.disabledFill)
        static let disabledLabel = dynamic(PaletteHex.disabledLabel)
        static let disabledOutline = dynamic(PaletteHex.disabledOutline)
    }
    static func dynamic(_ p: PaletteHex.Pair) -> Color { dynamic(light: p.light, dark: p.dark) }

    // MARK: Typografia
    enum Typo {
        static let largeTitle = Font.system(size: 26, weight: .semibold)
        static let title = Font.system(size: 19, weight: .semibold)
        static let headline = Font.system(size: 14, weight: .semibold)
        /// Minima czytelności (U1): treść ≥ 13 pt, tekst drugorzędny ≥ 11 pt.
        static let bodySize: CGFloat = 13
        static let captionSize: CGFloat = 12
        static let body = Font.system(size: bodySize)
        static let caption = Font.system(size: captionSize)
        static let metric = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
        static let metricSmall = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
        static let mono = Font.system(size: captionSize, design: .monospaced)
    }

    // MARK: Rozmiary kontrolek (W3 – większe, czytelniejsze przyciski; sprawdza `ButtonMetricsTests`)
    enum Metrics {
        /// Minimalna wysokość celu kliknięcia każdej akcji.
        static let actionHeight: CGFloat = 32
        /// Akcje główne ekranu (40–44 pt).
        static let primaryActionHeight: CGFloat = 42
        /// Tekst przycisków: min. 13 pt, semibold; akcje główne 15 pt.
        static let buttonFontSize: CGFloat = 13
        static let primaryButtonFontSize: CGFloat = 15
        /// Pola wyboru na listach: znak ≥ 18 pt, obszar kliknięcia ≥ 28 pt.
        static let checkboxSize: CGFloat = 18
        static let checkboxHitArea: CGFloat = 28
    }

    // MARK: Odstępy i promienie
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32 }
    enum Radius { static let s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16 }
}

// MARK: - Semantyka domenowa → kolory/etykiety

extension Severity {
    var color: Color {
        switch self { case .info: return Theme.Palette.info; case .warning: return Theme.Palette.warning; case .critical: return Theme.Palette.critical }
    }
    var symbol: String {
        switch self { case .info: return "info.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .critical: return "exclamationmark.octagon.fill" }
    }
}

extension RiskLevel {
    var color: Color {
        switch self { case .none: return Theme.Palette.textSecondary; case .low: return Theme.Palette.ok; case .medium: return Theme.Palette.warning; case .high: return Theme.Palette.critical }
    }
}

extension Certainty {
    var color: Color {
        switch self { case .confirmed: return Theme.Palette.ok; case .probable: return Theme.Palette.warning; case .aiHypothesis: return Theme.Palette.hypothesis }
    }
    var symbol: String {
        switch self { case .confirmed: return "checkmark.seal.fill"; case .probable: return "questionmark.circle.fill"; case .aiHypothesis: return "sparkles" }
    }
}

extension CleanupCategory {
    var symbol: String {
        switch self {
        case .appCaches: return "square.stack.3d.up"; case .browserCaches: return "globe"; case .logs: return "doc.text"
        case .temporary: return "clock.arrow.circlepath"; case .devTools: return "hammer"; case .aiTools: return "cpu"
        case .installers: return "shippingbox"; case .mailAttachments: return "paperclip"; case .updateLeftovers: return "arrow.triangle.2.circlepath"
        case .trash: return "trash"; case .oldDownloads: return "arrow.down.circle"; case .appLeftovers: return "app.dashed"
        }
    }
}

func scoreColor(_ score: Int) -> Color { score >= 85 ? Theme.Palette.ok : (score >= 60 ? Theme.Palette.warning : Theme.Palette.critical) }

func tildePath(_ p: String, home: String = NSHomeDirectory()) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

// MARK: - Komponenty bazowe

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).stroke(Theme.Palette.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.Palette.textSecondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View { Pill(text: String(localized: "Ryzyko: \(risk.label.lowercased())"), color: risk.color, symbol: "shield.lefthalf.filled") }
}

struct CertaintyBadge: View {
    let certainty: Certainty
    var body: some View { Pill(text: certainty.label, color: certainty.color, symbol: certainty.symbol) }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
            if let subtitle { Text(subtitle).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
        }
    }
}

struct Ring: View {
    let value: Double          // 0…1
    let color: Color
    var lineWidth: CGFloat = 10
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.004, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.Palette.accent
    var upper: Double? = nil
    var body: some View {
        GeometryReader { geo in
            let hi = max(upper ?? (values.max() ?? 1), 0.0001)
            let pts = values.enumerated().map { (i, v) in
                CGPoint(x: values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                        y: geo.size.height * (1 - CGFloat(min(max(v / hi, 0), 1))))
            }
            ZStack {
                if pts.count > 1 {
                    Path { p in p.move(to: CGPoint(x: 0, y: geo.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height)); p.closeSubpath() }
                        .fill(color.opacity(0.14))
                    Path { p in p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) } }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Theme.Palette.textTertiary)
            Text(title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
            if let detail { Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity).padding(Theme.Space.xl)
    }
}

extension View {
    func pageBackground() -> some View { background(Theme.Palette.background) }
}
