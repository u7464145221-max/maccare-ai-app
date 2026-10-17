import SwiftUI
import AppKit

/// Audyt 2 (4.13): ustawienie systemowe „Ogranicz ruch” (Dostępność → Ekran) wyłącza animacje przejść, rozwijania i zapętlone ruchy.
/// Dla kodu poza widokiem (model, akcje przycisków) – odczyt z `NSWorkspace`; w widokach także `\.accessibilityReduceMotion`.
@MainActor
enum Motion {
    /// Testy podstawiają wartość; nil = ustawienie systemu.
    static var overrideReduced: Bool?
    static var reduced: Bool { overrideReduced ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Animacja albo nil (zmiana natychmiastowa), gdy ruch ma być ograniczony.
    static func animation(_ a: Animation) -> Animation? { reduced ? nil : a }

    /// `withAnimation`, które przy „Ogranicz ruch” wykonuje zmianę bez animacji.
    static func perform<R>(_ a: Animation = .default, _ body: () throws -> R) rethrows -> R {
        reduced ? try body() : try withAnimation(a, body)
    }
}
