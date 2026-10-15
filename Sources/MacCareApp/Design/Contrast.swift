import Foundation

/// Kontrast wg WCAG 2.2 (luminancja względna, sRGB). Czysta matematyka – używana przez motyw i przez `ContrastTests`.
enum WCAG {
    static let textMin = 4.5          // tekst normalny
    static let largeTextMin = 3.0     // tekst ≥ 24 pt lub ≥ 18,66 pt pogrubiony
    static let graphicMin = 3.0       // elementy UI, obrysy, ikony niosące informację

    static func channel(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }

    static func luminance(_ hex: UInt32) -> Double {
        func lin(_ c: Double) -> Double { let s = c / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(channel(hex, 16)) + 0.7152 * lin(channel(hex, 8)) + 0.0722 * lin(channel(hex, 0))
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Mieszanie liniowe w sRGB: `t` = udział `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ s: UInt32) -> UInt32 { UInt32(max(0, min(255, (channel(a, s) * (1 - t) + channel(b, s) * t).rounded()))) << s }
        return ch(16) | ch(8) | ch(0)
    }

    /// Kolor `fg` o przezroczystości `alpha` położony na `bg`.
    static func composite(_ fg: UInt32, alpha: Double, over bg: UInt32) -> UInt32 { mix(bg, fg, alpha) }

    static let black: UInt32 = 0x0B0E13
    static let white: UInt32 = 0xFFFFFF

    /// Czarny albo biały – to, co daje lepszy kontrast na danym tle.
    static func readable(on bg: UInt32) -> UInt32 { ratio(bg, white) >= ratio(bg, black) ? white : black }

    /// Przyciemnia (`towardDark`) albo rozjaśnia kolor krokami po 1%, aż kontrast z KAŻDYM tłem z listy ≥ `min`.
    /// Gdy się nie da (czerń/biel nie wystarczają), zwraca skrajny kolor.
    static func ensure(_ hex: UInt32, against bgs: [UInt32], min: Double, towardDark: Bool) -> UInt32 {
        let target: UInt32 = towardDark ? 0x000000 : 0xFFFFFF
        for step in 0...100 {
            let c = mix(hex, target, Double(step) / 100)
            if bgs.allSatisfy({ ratio(c, $0) >= min }) { return c }
        }
        return target
    }
}

/// Wypełnienie + etykieta + akcent wyprowadzone z koloru modułu tak, by spełniały progi WCAG.
struct AccentSet: Equatable {
    /// Wypełnienie przycisków i kafli (kontrast ≥ 3:1 względem karty – element UI jest rozpoznawalny).
    let fill: UInt32
    /// Kolor tekstu/ikony na wypełnieniu (kontrast ≥ 4,5:1).
    let label: UInt32
    /// Kolor modułu jako tekst/ikona/wykres na karcie i na tle okna (kontrast ≥ 4,5:1).
    let foreground: UInt32

    /// - Parameters:
    ///   - hex: kolor bazowy modułu
    ///   - surface: kolor karty, `backgrounds`: najjaśniejsze/najciemniejsze tła okna, na których akcent ma być czytelny
    static func derive(from hex: UInt32, dark: Bool, surface: UInt32, backgrounds: [UInt32]) -> AccentSet {
        let fg: UInt32 = WCAG.ensure(hex, against: [surface] + backgrounds, min: WCAG.textMin, towardDark: !dark)
        if dark {
            // Ciemny motyw: jasny, nasycony kolor z ciemną etykietą (kontrast etykiety ≥ 4,5; kolor vs karta ≥ 3).
            let label = WCAG.readable(on: hex)
            if WCAG.ratio(label, hex) >= WCAG.textMin, WCAG.ratio(hex, surface) >= WCAG.graphicMin { return AccentSet(fill: hex, label: label, foreground: fg) }
            let f = WCAG.ensure(hex, against: [surface], min: WCAG.graphicMin, towardDark: false)
            return AccentSet(fill: f, label: WCAG.readable(on: f), foreground: fg)
        }
        // Jasny motyw: biała etykieta na przyciemnionym kolorze (do ~36% zmiany); inaczej czarna na kolorze przyciemnionym do 3:1 vs karta.
        for step in 0...36 {
            let f = WCAG.mix(hex, 0x000000, Double(step) / 100)
            if WCAG.ratio(f, WCAG.white) >= WCAG.textMin, WCAG.ratio(f, surface) >= WCAG.graphicMin { return AccentSet(fill: f, label: WCAG.white, foreground: fg) }
        }
        let f = WCAG.ensure(hex, against: [surface], min: WCAG.graphicMin, towardDark: true)
        return AccentSet(fill: f, label: WCAG.readable(on: f), foreground: fg)
    }
}
