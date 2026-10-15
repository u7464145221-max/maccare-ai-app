import Foundation
import MacCareCore

/// Odmiana polskich liczebników w etykietach (AUD-UI-1): 1 → mianownik lp.; 2–4 (poza 12–14) → mianownik lm.; reszta (0, 5–21, 25–31 …) → dopełniacz lm.
/// Jedno miejsce zamiast ad hoc „n == 1 ? … : …” w widokach (dla 2–4 dawało błędne „2 zadań”, „3 elementów”).
enum Plural {
    static func form(_ n: Int, one: String, few: String, many: String) -> String { PolishPlural.form(n, one: one, few: few, many: many) }

    /// „3 elementy”, „1 element”, „5 elementów”.
    static func counted(_ n: Int, one: String, few: String, many: String) -> String { PolishPlural.counted(n, one: one, few: few, many: many) }

    static func elements(_ n: Int) -> String { PolishPlural.elements(n) }
}
