import SwiftUI
import AppKit

/// Moduły aplikacji. Każdy ma własny kolor, który staje się motywem CAŁEGO okna (tło + pasek boczny) – płynne przejście przy zmianie modułu.
enum AppModule: String, CaseIterable, Identifiable {
    // Główne
    case smartScan, cleanup, protection, performance, apps, files
    // Asystent (przypięty na dole)
    case assistant
    // Narzędzia i aktywność
    case tools, activity, history, notifications, knowledge, settings

    var id: String { rawValue }

    /// Czy moduł ma działający widok (P2-15 / AUD-UI-7). Niegotowe moduły NIE są pokazywane w nawigacji – zamiast pustego ekranu „w budowie”.
    var isBuilt: Bool {
        switch self {
        case .tools, .activity, .notifications, .knowledge: return false
        default: return true
        }
    }

    static let main: [AppModule] = [.smartScan, .cleanup, .protection, .performance, .apps, .files]
    static let secondary: [AppModule] = [.tools, .activity, .history, .notifications, .knowledge, .settings]

    var title: String {
        switch self {
        case .smartScan: return String(localized: "Smart Scan"); case .cleanup: return String(localized: "Porządki"); case .protection: return String(localized: "Ochrona")
        case .performance: return String(localized: "Wydajność"); case .apps: return String(localized: "Aplikacje"); case .files: return String(localized: "Moje pliki")
        case .assistant: return String(localized: "Asystent"); case .tools: return String(localized: "Moje narzędzia"); case .activity: return String(localized: "Aktywność")
        case .history: return String(localized: "Historia"); case .notifications: return String(localized: "Powiadomienia"); case .knowledge: return String(localized: "Wiedza"); case .settings: return String(localized: "Ustawienia")
        }
    }

    var symbol: String {
        switch self {
        case .smartScan: return "wand.and.stars"; case .cleanup: return "sparkles"; case .protection: return "shield.lefthalf.filled"
        case .performance: return "gauge.with.dots.needle.67percent"; case .apps: return "square.grid.2x2.fill"; case .files: return "circle.hexagongrid.fill"
        case .assistant: return "bubble.left.and.text.bubble.right.fill"; case .tools: return "wrench.and.screwdriver.fill"
        case .activity: return "chart.bar.xaxis"; case .history: return "clock.arrow.circlepath"; case .notifications: return "bell.fill"
        case .knowledge: return "books.vertical.fill"; case .settings: return "gearshape.fill"
        }
    }

    /// Kolor bazowy modułu (paleta MacCare – własna, z `docs/UX_REFERENCJA.md` §6).
    var hex: UInt32 {
        switch self {
        case .smartScan: return 0x6C7BFF      // indygo
        case .cleanup: return 0x2EC4B6        // turkus
        case .protection: return 0x4C8DF6     // błękit
        case .performance: return 0xF5B841    // bursztyn
        case .apps: return 0x7C6CF2           // fiolet chłodny
        case .files: return 0x1FB58F          // zieleń morska
        case .assistant: return 0x8E9BFF
        case .tools: return 0x5FB7D9; case .activity: return 0x2EC4B6; case .history: return 0x6C8AB8
        case .notifications: return 0xF2825B; case .knowledge: return 0x9A86E8; case .settings: return 0x7C8DA6
        }
    }

    /// Surowy kolor bazowy – WYŁĄCZNIE dekoracje (ilustracje, poświata). Tekst, ikony, przyciski i wykresy używają `fill`/`label`/`foreground`.
    var color: Color { Color(hex: hex) }

    // MARK: Akcenty zgodne z WCAG (wyprowadzone z `hex`, patrz `AccentSet`)
    /// Tła, na których akcent musi być czytelny: karta, tło okna z poświatą modułu, pasek boczny z zabarwieniem.
    func accentBackgrounds(dark: Bool) -> [UInt32] {
        [Theme.PaletteHex.surface.value(dark: dark), washedBackground(dark: dark), sidebarBackground(dark: dark),
         Theme.PaletteHex.background.value(dark: dark)]
    }
    func washedBackground(dark: Bool) -> UInt32 {
        WCAG.composite(hex, alpha: Theme.PaletteHex.wash(dark: dark), over: Theme.PaletteHex.background.value(dark: dark))
    }
    func sidebarBackground(dark: Bool) -> UInt32 {
        WCAG.composite(hex, alpha: Theme.PaletteHex.sidebarTintAlpha, over: Theme.PaletteHex.sidebar.value(dark: dark))
    }
    func accentSet(dark: Bool) -> AccentSet {
        AccentSet.derive(from: hex, dark: dark, surface: Theme.PaletteHex.surface.value(dark: dark), backgrounds: accentBackgrounds(dark: dark))
    }
    private static let accentCache: [AppModule: (light: AccentSet, dark: AccentSet)] =
        Dictionary(uniqueKeysWithValues: AppModule.allCases.map { ($0, (light: $0.accentSet(dark: false), dark: $0.accentSet(dark: true))) })
    /// Wypełnienie (przyciski, kafle ikon).
    var fill: Color { let a = AppModule.accentCache[self]!; return Theme.dynamic(light: a.light.fill, dark: a.dark.fill) }
    /// Tekst/ikona na `fill`.
    var label: Color { let a = AppModule.accentCache[self]!; return Theme.dynamic(light: a.light.label, dark: a.dark.label) }
    /// Kolor modułu jako tekst/ikona/wykres na kartach i tle okna.
    var foreground: Color { let a = AppModule.accentCache[self]!; return Theme.dynamic(light: a.light.foreground, dark: a.dark.foreground) }
    /// Zabarwienie paska bocznego: kolor modułu o krytyciu `sidebarTintAlpha` (warstwa nad neutralnym tłem paska).
    var sidebarTint: Color { Color(hex: hex, alpha: Theme.PaletteHex.sidebarTintAlpha) }

    /// Jednozdaniowy opis (ekran startowy modułu).
    var tagline: String {
        switch self {
        case .smartScan: return String(localized: "Jedno skanowanie sprawdzi porządki, ochronę i wydajność – bez zmieniania czegokolwiek.")
        case .cleanup: return String(localized: "Znajdź pamięć podręczną, logi i pozostałości, które można bezpiecznie odzyskać – z uczciwym rozliczeniem, ile miejsca realnie wróci.")
        case .protection: return String(localized: "Sprawdź stan zabezpieczeń, autostart i podpisy programów. Pokazujemy fakty i dowody, nie straszymy.")
        case .performance: return String(localized: "Zobacz, co obciąża procesor, pamięć i baterię – i czy powodem jest aplikacja, czy system.")
        case .apps: return String(localized: "Przejrzyj zainstalowane aplikacje, ich rozmiar, ostatnie użycie i pozostałości po odinstalowanych.")
        case .files: return String(localized: "Mapa dysku, największe pliki i duplikaty. Zobacz, co naprawdę zajmuje miejsce.")
        case .assistant: return String(localized: "Zapytaj o stan Maca. Lokalny model odpowiada na podstawie pomiarów – z dowodami i poziomem pewności, bez wysyłania danych.")
        default: return ""
        }
    }

    /// Trzy funkcje modułu pokazywane na ekranie startowym.
    var features: [(symbol: String, title: String)] {
        switch self {
        case .smartScan: return [("sparkles", String(localized: "Porządki i odzyskiwalne miejsce")), ("lock.shield", String(localized: "Stan zabezpieczeń i autostart")), ("speedometer", String(localized: "Obciążenie i pamięć"))]
        case .cleanup: return [("square.stack.3d.up", String(localized: "Pamięć podręczna i logi")), ("hammer", String(localized: "Narzędzia programistyczne")), ("arrow.down.circle", String(localized: "Instalatory i stare pliki"))]
        case .protection: return [("checkmark.shield", String(localized: "Stan zabezpieczeń systemu")), ("power", String(localized: "Audyt autostartu")), ("signature", String(localized: "Podpisy aplikacji"))]
        case .performance: return [("cpu", String(localized: "Najwięksi konsumenci")), ("memorychip", String(localized: "Pamięć i swap")), ("battery.75", String(localized: "Bateria i temperatura"))]
        case .apps: return [("app.badge.checkmark", String(localized: "Rozmiar i ostatnie użycie")), ("trash.slash", String(localized: "Pozostałości po aplikacjach")), ("cpu", String(localized: "Podpis i architektura (Intel / Apple Silicon)"))]
        case .files: return [("circle.hexagongrid", String(localized: "Mapa dysku")), ("doc.badge.clock", String(localized: "Największe pliki")), ("square.on.square", String(localized: "Duplikaty"))]
        default: return []
        }
    }

    var section: String {
        AppModule.main.contains(self) ? "main" : (self == .assistant ? "assistant" : "secondary")
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    /// Liniowe mieszanie dwóch kolorów hex.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        return Color(.sRGB, red: (ch(a, 16) * (1 - t) + ch(b, 16) * t) / 255, green: (ch(a, 8) * (1 - t) + ch(b, 8) * t) / 255,
                     blue: (ch(a, 0) * (1 - t) + ch(b, 0) * t) / 255, opacity: 1)
    }
}

/// Tło okna: spokojne, neutralne tło + delikatna poświata w kolorze aktywnego modułu tylko u góry (akcent, nie zalew).
/// Każdy moduł ma własną warstwę; przełączanie to płynne zanikanie (~0,4 s).
struct ModuleBackground: View {
    let module: AppModule
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Palette.background
            ForEach(AppModule.allCases) { m in
                LinearGradient(colors: [Color(hex: m.hex, alpha: Theme.PaletteHex.wash(dark: scheme == .dark)), Color(hex: m.hex, alpha: 0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(m == module ? 1 : 0)
            }
        }
        .animation(Motion.animation(.easeInOut(duration: 0.4)), value: module)
        .ignoresSafeArea()
    }
}
