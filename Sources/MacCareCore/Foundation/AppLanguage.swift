import Foundation

/// Język interfejsu (i18n, etap 2). Angielski wyłącznie wtedy, gdy pakiet aplikacji ZAWIERA lokalizację `en` i system ją wybrał – w testach i przy `swift run`
/// (bez zasobów) zawsze polski, więc teksty źródłowe i testy nie zależą od języka systemu.
public enum AppLanguage {
    nonisolated(unsafe) public static var isEnglish: Bool = detect()

    static func detect(bundle: Bundle = .main) -> Bool {
        bundle.preferredLocalizations.first == "en" && bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil
    }

    /// Kod języka do promptu asystenta i formatowania.
    public static var code: String { isEnglish ? "en" : "pl" }
}

/// Angielskie formy dla zestawów polskich form liczebników używanych w kodzie (klucz: „one|few|many”). Test `PluralTableTests` pilnuje, że każdy
/// zestaw użyty w `Sources/` ma tu wpis.
public enum EnglishPlurals {
    public static let table: [String: (one: String, other: String)] = [
        "element|elementy|elementów": ("item", "items"),
        "elementu|elementów|elementów": ("item", "items"),
        "aplikacja|aplikacje|aplikacji": ("app", "apps"),
        "dzień|dni|dni": ("day", "days"),
        "grupa|grupy|grup": ("group", "groups"),
        "kopia|kopie|kopii": ("copy", "copies"),
        "krok|kroki|kroków": ("step", "steps"),
        "miejsce|miejsca|miejsc": ("location", "locations"),
        "mniej ważna sprawa|mniej ważne sprawy|mniej ważnych spraw": ("minor issue", "minor issues"),
        "możliwa pozostałość|możliwe pozostałości|możliwych pozostałości": ("possible leftover", "possible leftovers"),
        "pliku|plików|plików": ("file", "files"),
        "pozycja wymaga|pozycje wymagają|pozycji wymaga": ("item needs", "items need"),
        "regułę|reguły|reguł": ("rule", "rules"),
        "spoza systemu zajmuje|spoza systemu zajmują|spoza systemu zajmuje": ("non-system app takes", "non-system apps take"),
        "sprawa do sprawdzenia|sprawy do sprawdzenia|spraw do sprawdzenia": ("issue to check", "issues to check"),
        "zadanie|zadania|zadań": ("task", "tasks"),
        "zdjęcia|zdjęć|zdjęć": ("photo", "photos"),
        "aktualizacja Apple czeka|aktualizacje Apple czekają|aktualizacji Apple czeka": ("Apple update is waiting", "Apple updates are waiting"),
        "element spoza Apple|elementy spoza Apple|elementów spoza Apple": ("non-Apple item", "non-Apple items"),
    ]

    public static func form(_ n: Int, one: String, few: String, many: String) -> String? {
        table["\(one)|\(few)|\(many)"].map { abs(n) == 1 ? $0.one : $0.other }
    }
}
