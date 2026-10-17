import SwiftUI
import MacCareCore

/// Karta: pełne tło (białe / ciemnoszare), wyraźny obrys (≥ 3:1 względem tła okna) i cień. Moduł daje akcent w nagłówkach i ikonach, nie zalewa karty kolorem.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var radius: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(radius, 20), style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: shape)
            .overlay(shape.stroke(Theme.Palette.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: 10, y: 3)
    }
}

/// Przycisk główny: wypełnienie i etykieta z `AccentSet` modułu (kontrast etykiety ≥ 4,5:1 w obu motywach).
struct ProminentButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? Theme.Metrics.primaryButtonFontSize : Theme.Metrics.buttonFontSize, weight: .semibold))
            .foregroundStyle(enabled ? label : Theme.Palette.disabledLabel)
            .padding(.horizontal, large ? 24 : 16)
            .frame(minHeight: large ? Theme.Metrics.primaryActionHeight : Theme.Metrics.actionHeight)
            .background((enabled ? fill : Theme.Palette.disabledFill).opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
            .contentShape(Capsule())
            .overlay(Capsule().stroke(Theme.Palette.disabledOutline, lineWidth: enabled ? 0 : 1.5))
    }
}
extension ButtonStyle where Self == ProminentButtonStyle {
    static func prominent(_ m: AppModule, large: Bool = false) -> ProminentButtonStyle { ProminentButtonStyle(fill: m.fill, label: m.label, large: large) }
}

/// Przycisk drugorzędny: pole + obrys + tekst główny (kontrast ≥ 4,5:1 na karcie i na tle okna).
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.Metrics.buttonFontSize, weight: .semibold))
            .foregroundStyle(enabled ? Theme.Palette.text : Theme.Palette.disabledLabel)
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.Metrics.actionHeight)
            .background(Theme.Palette.surfaceAlt.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
    }
}
extension ButtonStyle where Self == SoftButtonStyle { static var soft: SoftButtonStyle { SoftButtonStyle() } }

/// Pole wyboru na listach (W3): znak 18 pt, obszar kliknięcia 28 × 28 pt, kontrastowy obrys; wyłączone ma własne tokeny (jak przyciski).
struct LargeCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: Theme.Metrics.checkboxSize, weight: .regular))
                    .foregroundStyle(enabled ? (configuration.isOn ? Theme.Palette.accent : Theme.Palette.textSecondary) : Theme.Palette.disabledLabel)
                    .frame(width: Theme.Metrics.checkboxHitArea, height: Theme.Metrics.checkboxHitArea)
                    .contentShape(Rectangle())
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? String(localized: "zaznaczone") : String(localized: "niezaznaczone"))
        .accessibilityAddTraits(.isButton)
    }
}
extension ToggleStyle where Self == LargeCheckboxStyle { static var largeCheckbox: LargeCheckboxStyle { LargeCheckboxStyle() } }

extension View {
    /// Cel kliknięcia dla przycisków `.plain` / ikonowych: min. 32 pt wysokości i pełny obszar (nie tylko piksele tekstu).
    func actionTarget(minWidth: CGFloat? = nil) -> some View {
        self.frame(minWidth: minWidth, minHeight: Theme.Metrics.actionHeight).contentShape(Rectangle())
    }
}

/// Przełącznik segmentowy (W3) zamiast systemowego `Picker(.segmented)` (ten ma 22–28 pt): segmenty min. 32 pt, etykieta 13 pt semibold,
/// zaznaczenie wypełnieniem modułu (kontrast etykiety ≥ 4,5:1 jak w przyciskach głównych), tło pola z obrysem. VoiceOver: grupa z przyciskami, stan „zaznaczone”.
/// `width` ≠ nil ⇒ segmenty mają równą szerokość w zadanej szerokości całości.
struct SegmentedSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var module: AppModule = .smartScan
    /// Kolor zaznaczenia zależny od opcji (np. tryb wykonania: odczyt = niebieski, Edycja = bursztynowy); domyślnie `module`.
    var moduleFor: ((Value) -> AppModule)? = nil
    var width: CGFloat? = nil
    var accessibilityName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { value in
                let on = value == selection
                Button {
                    if reduceMotion { selection = value } else { withAnimation(.snappy(duration: 0.18)) { selection = value } }
                } label: {
                    Text(title(value))
                        .font(.system(size: Theme.Metrics.buttonFontSize, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(on ? (moduleFor?(value) ?? module).label : Theme.Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: width == nil ? nil : .infinity, minHeight: Theme.Metrics.actionHeight)
                        .background(on ? (moduleFor?(value) ?? module).fill : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: width)
        .background(Theme.Palette.surfaceAlt, in: Capsule())
        .overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}

/// Pasek głównej akcji przypięty do dołu okna (W3): przycisk jest zawsze w całości widoczny, a treść przewija się pod paskiem
/// (ten sam token tła co górny pasek – spójnie w obu motywach). Używany z `.safeAreaInset(edge: .bottom, spacing: 0)`.
struct MainActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(Theme.Palette.surface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
    }
}

/// Ilustracja modułu: szklista bryła z poświatą i kompozycją SF Symbols (bez grafik zewnętrznych).
struct ModuleHero: View {
    let module: AppModule
    var size: CGFloat = 220
    var tint: Color? = nil
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = tint ?? module.color
        ZStack {
            Circle().fill(c.opacity(0.35)).blur(radius: size * 0.22).scaleEffect(1.05)
            Circle()
                .fill(LinearGradient(colors: [c.opacity(0.95), Color.mix(0x101A33, module.hex, 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 2))
                .overlay(alignment: .top) {
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.62, height: size * 0.32).offset(y: size * 0.06)
                }
                .frame(width: size * 0.82, height: size * 0.82)
                .shadow(color: c.opacity(0.5), radius: size * 0.12, y: size * 0.05)
            Image(systemName: module.symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .white.opacity(0.65))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            Image(systemName: "sparkle").font(.system(size: size * 0.12)).foregroundStyle(.white.opacity(0.9)).offset(x: size * 0.28, y: -size * 0.26)
            Image(systemName: "sparkle").font(.system(size: size * 0.07)).foregroundStyle(.white.opacity(0.7)).offset(x: -size * 0.3, y: size * 0.2)
        }
        .frame(width: size, height: size)
        .offset(y: float ? -6 : 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: float)
        .onAppear { float = !reduceMotion }                                              // audyt 2 (4.13): bez zapętlonego unoszenia przy „Ogranicz ruch”
        .accessibilityHidden(true)
    }
}

/// Okrągły przycisk główny (Skanuj / Podgląd zmian). W trakcie skanowania: obracający się pierścień i pulsująca poświata.
/// Kolory z `AccentSet` modułu: etykieta ma kontrast ≥ 4,5:1 na wypełnieniu.
struct ScanButton: View {
    let title: String
    var module: AppModule
    var scanning = false
    var progress: Double? = nil
    var disabled = false
    var help: String = ""
    let action: () -> Void
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let off = disabled && !scanning                       // wyłączony: własne tokeny (etykieta ≥ 4,5:1, obrys ≥ 3:1), bez przezroczystości
        Button(action: action) {
            ZStack {
                if !off { Circle().fill(module.fill.opacity(scanning ? 0.45 : 0.28)).blur(radius: 16).scaleEffect(pulse && scanning ? 1.25 : 1.06) }
                Circle().fill(off ? Theme.Palette.disabledFill : module.fill)
                    .overlay(Circle().stroke(off ? Theme.Palette.disabledOutline : module.label.opacity(0.55), lineWidth: 2).padding(off ? 0 : 3))
                    .shadow(color: .black.opacity(off ? 0 : 0.22), radius: 6, y: 3)
                if scanning {
                    Circle().trim(from: 0, to: progress.map { max(0.05, $0) } ?? 0.28)
                        .stroke(module.label, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(pulse ? 360 : 0))
                        .animation(reduceMotion ? nil : progress == nil ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .default, value: pulse)
                        .padding(7)
                }
                Text(scanning ? "…" : title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(off ? Theme.Palette.disabledLabel : module.label)
            }
            .frame(width: 92, height: 92)
        }
        .buttonStyle(.plain)
        .disabled(disabled || scanning)
        .help(help)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = !reduceMotion }                                              // audyt 2 (4.13): bez pulsowania i obrotu przy „Ogranicz ruch”
    }
}

/// Kafel wyniku (Smart Scan): checkbox + nazwa, wielka liczba, opis, „Przejrzyj”.
struct ResultTile: View {
    let module: AppModule
    let number: String
    let caption: String
    var note: String? = nil
    var checked = true
    var onToggle: (() -> Void)? = nil
    let onReview: () -> Void

    var body: some View {
        SurfaceCard(padding: 18, radius: 20) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: module.symbol).font(.system(size: 64, weight: .bold))
                    .foregroundStyle(module.fill.opacity(0.16)).offset(x: 10, y: -8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let onToggle { Button(action: onToggle) { Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: Theme.Metrics.checkboxSize)).foregroundStyle(module.foreground).frame(width: Theme.Metrics.checkboxHitArea, height: Theme.Metrics.checkboxHitArea).contentShape(Rectangle()) }.buttonStyle(.plain) }
                        Text(module.title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                    }
                    Spacer(minLength: 14)
                    Text(number).font(.system(size: 46, weight: .semibold, design: .rounded)).foregroundStyle(Theme.Palette.text)
                        .contentTransition(.numericText()).minimumScaleFactor(0.5).lineLimit(1)
                    Text(caption).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                    if let note { Text(note).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary).lineLimit(3) }
                    HStack {
                        Spacer()
                        Button("Przejrzyj", action: onReview).buttonStyle(.soft)
                    }
                }
            }
        }
        .frame(height: 230)
    }
}

/// Karta „bento”: rozmiar + nazwa kategorii, opis, ikona, przyciski.
struct BentoCard: View {
    let symbol: String
    let module: AppModule
    let big: String
    let title: String
    let detail: String
    var large = false
    var primaryTitle: String? = nil
    var primaryHelp = ""
    var primaryDisabled = false
    var onReview: () -> Void
    var onPrimary: (() -> Void)? = nil

    var body: some View {
        SurfaceCard(padding: 18, radius: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ZStack { Circle().fill(module.fill); Image(systemName: symbol).font(.system(size: large ? 22 : 15, weight: .semibold)).foregroundStyle(module.label) }
                        .frame(width: large ? 46 : 32, height: large ? 46 : 32)
                    Spacer()
                }
                Spacer(minLength: large ? 40 : 6)
                Text(big).font(.system(size: large ? 44 : 28, weight: .semibold, design: .rounded)).foregroundStyle(Theme.Palette.text).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
                Text(title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text).lineLimit(2)
                Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(large ? 4 : 3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Przejrzyj", action: onReview).buttonStyle(.soft)
                    if let primaryTitle, let onPrimary {
                        Button(primaryTitle, action: onPrimary).buttonStyle(.prominent(module)).disabled(primaryDisabled).help(primaryHelp)
                    }
                    Spacer()
                }.padding(.top, 4)
            }
        }
    }
}

/// Wstępny stan: ilustracja + tytuł + opis + 3 funkcje + przycisk (start modułu).
struct ModuleStart<Extra: View>: View {
    let module: AppModule
    let scanTitle: String
    var scanning = false
    var progress: Double? = nil
    var stage: String? = nil
    /// P2-4: „Zatrzymaj” w trakcie skanu (nil = skanu nie da się przerwać).
    var onCancel: (() -> Void)? = nil
    let onScan: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 56) {
                VStack(spacing: 10) {
                    ModuleHero(module: module, size: 300)
                    Text(module.title).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    Text(module.title).font(.system(size: 44, weight: .semibold, design: .rounded)).foregroundStyle(Theme.Palette.text)
                    Text(module.tagline).font(.system(size: 16)).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(module.features.enumerated()), id: \.offset) { _, f in
                            HStack(spacing: 12) {
                                ZStack { Circle().fill(module.fill); Image(systemName: f.symbol).foregroundStyle(module.label) }.frame(width: 34, height: 34)
                                Text(f.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Palette.text)
                            }
                        }
                    }
                    extra
                }
                .frame(maxWidth: 440, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 48).frame(maxHeight: .infinity)
            VStack(spacing: 8) {
                ScanButton(title: scanTitle, module: module, scanning: scanning, progress: progress, action: onScan)
                Text(stage ?? " ").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).frame(height: 14)
                if scanning, let onCancel {
                    Button("Zatrzymaj", action: onCancel).buttonStyle(.soft).keyboardShortcut(.cancelAction)
                        .help("Przerywa skan. Wynik będzie oznaczony jako niepełny.")
                }
            }
            .padding(.bottom, 28)
        }
    }
}
extension ModuleStart where Extra == EmptyView {
    init(module: AppModule, scanTitle: String, scanning: Bool = false, progress: Double? = nil, stage: String? = nil, onCancel: (() -> Void)? = nil, onScan: @escaping () -> Void) {
        self.init(module: module, scanTitle: scanTitle, scanning: scanning, progress: progress, stage: stage, onCancel: onCancel, onScan: onScan) { EmptyView() }
    }
}

/// Wynik modułu: nagłówek + „Zacznij od nowa”. Gdy tytuł się mieści, przycisk stoi w jednej linii z tytułem (oszczędza ok. 40 pt wysokości –
/// ekrany wyników mieszczą się w oknie 1280 × 800); w wąskim oknie przechodzi do osobnego wiersza nad tytułem, więc nigdy nie nachodzi na tekst.
struct ResultHeader: View {
    let module: AppModule
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    let onRestart: () -> Void

    private var restart: some View {
        Button(action: onRestart) { Label("Zacznij od nowa", systemImage: "chevron.left") }.buttonStyle(.soft).fixedSize()
    }
    private var titleText: some View {
        Text(title).font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(Theme.Palette.text).multilineTextAlignment(.center)
            .contentTransition(.numericText())
    }

    var body: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    restart.frame(width: 184, alignment: .leading)
                    titleText.fixedSize().frame(maxWidth: .infinity)
                    Color.clear.frame(width: 184, height: 1)
                }
                VStack(spacing: 6) {
                    HStack { restart; Spacer() }
                    titleText
                }
            }
            if let subtitle { Text(subtitle).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center) }
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction).buttonStyle(.prominent(module, large: true)).padding(.top, 6)
            }
        }
    }
}
