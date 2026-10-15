import Foundation

/// Odmiana polskich liczebników: 1 → mianownik lp.; 2–4 (poza 12–14) → mianownik lm.; reszta (0, 5–21, 25–31 …) → dopełniacz lm.
/// Jedno miejsce dla etykiet w rdzeniu i w interfejsie (aplikacja deleguje tu `Plural`).
public enum PolishPlural {
    /// `english` – interfejs po angielsku (domyślnie wg `AppLanguage`; parametr pozwala testom sprawdzić obie ścieżki bez zmiany stanu globalnego).
    public static func form(_ n: Int, one: String, few: String, many: String, english: Bool = AppLanguage.isEnglish) -> String {
        if english, let en = EnglishPlurals.form(n, one: one, few: few, many: many) { return en }   // i18n: interfejs po angielsku
        let a = abs(n)
        if a == 1 { return one }
        return (2...4).contains(a % 10) && !(12...14).contains(a % 100) ? few : many
    }

    /// „3 elementy”, „1 element”, „5 elementów”.
    public static func counted(_ n: Int, one: String, few: String, many: String, english: Bool = AppLanguage.isEnglish) -> String {
        "\(n) \(form(n, one: one, few: few, many: many, english: english))"
    }

    public static func elements(_ n: Int) -> String { counted(n, one: "element", few: "elementy", many: "elementów") }
}
