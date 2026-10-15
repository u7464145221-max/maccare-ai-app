import Foundation

/// Ochrona działających aplikacji (z PureMac, pkt 3): do kogo należy działający proces i czy element do sprzątnięcia należy do działającej aplikacji.
/// Czysta logika – listę procesów dostarcza warstwa systemowa (`RunningApps`).
public enum RunningOwners {
    /// Zewnętrzny pakiet aplikacji pliku wykonywalnego: pomocnik w `X.app/Contents/Frameworks/…/Helper.app/Contents/MacOS/…` należy do `X.app`
    /// (pierwsze wystąpienie „.app/” na ścieżce). nil – proces spoza pakietu aplikacji (narzędzie wiersza poleceń, demon systemowy).
    public static func outermostApp(of executable: String) -> String? {
        guard let r = executable.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(executable[..<executable.index(r.lowerBound, offsetBy: 4)])
    }

    /// Nazwa w postaci identyfikatora pakietu (com.firma.aplikacja) – tak nazywają się foldery pamięci podręcznej i logów aplikacji.
    public static func looksLikeBundleID(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$"#, options: .regularExpression) != nil
    }

    /// Identyfikatory aplikacji, do których należą procesy o podanych ścieżkach (także procesy pomocnicze i działające bez okna).
    public static func bundleIDs(executables: [String], bundleID: (String) -> String?) -> Set<String> {
        var apps = Set<String>(), ids = Set<String>()
        for e in executables { if let a = outermostApp(of: e) { apps.insert(a) } }
        for a in apps { if let id = bundleID(a) { ids.insert(id.lowercased()) } }
        return ids
    }

    /// Element należy do działającej aplikacji: reguła wskazuje jej identyfikator albo nazwa elementu jest identyfikatorem działającej aplikacji.
    public static func ownerRunning(ruleOwners: [String], itemName: String, running: Set<String>) -> Bool {
        ruleOwners.contains { running.contains($0.lowercased()) } || (looksLikeBundleID(itemName) && running.contains(itemName.lowercased()))
    }
}
