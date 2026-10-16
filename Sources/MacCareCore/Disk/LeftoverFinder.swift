import Foundation

/// Możliwa pozostałość po odinstalowanej aplikacji: wpis w `~/Library` nazwany identyfikatorem pakietu, którego nie ma wśród zainstalowanych aplikacji.
public struct AppLeftover: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    /// Identyfikator pakietu wyczytany z nazwy (np. `com.example.Editor`).
    public var bundleID: String
    /// Gdzie leży (np. „Application Support”, „Preferencje”).
    public var location: String
    public var size: UInt64
    public var modified: Date
    /// Application Support lub kontener – mogą zawierać dokumenty i ustawienia (audyt 2.2: nie zaznaczane razem z resztą).
    public var risky: Bool = false
}

/// Wyszukiwanie pozostałości (P2-12, część: tylko odczyt). Heurystyka – dlatego wynik to „możliwe pozostałości”: nazwa w odwrotnej notacji DNS,
/// której nie pasuje żaden zainstalowany pakiet (także jako prefiks – pomocnicy `com.x.App.helper`) ani znane wyjątki (Apple, kontenery grup, usługi systemowe).
public enum LeftoverFinder {
    /// Miejsca w `~/Library` przeglądane płytko (tylko pierwszy poziom).
    public static let locations: [(rel: String, label: String)] = [
        ("Library/Application Support", "Application Support"), ("Library/Caches", String(localized: "Pamięć podręczna")), ("Library/Preferences", String(localized: "Preferencje")),
        ("Library/Containers", String(localized: "Kontenery")), ("Library/Saved Application State", String(localized: "Stan okien"))]
    // Pominięte celowo: HTTPStorages/WebKit/Logs – tworzy je każdy proces korzystający z sieci (także narzędzia bez aplikacji), więc dawały głównie fałszywe trafienia
    // (pomiar 14.10.2026 na tym Macu: 111 kandydatów, w tym 28 HTTPStorages).

    /// Rodziny wpisów, które nie są aplikacjami: aktualizatory, reportery awarii, biblioteki i narzędzia deweloperskie.
    static let nonAppMarkers = ["update", "crash", "breakpad", "sparkle", "telemetry", "analytics", "installer", ".install"]
    static let nonAppPrefixes = ["org.swift.", "org.webkit.", "org.python.", "org.llvm.", "io.flutter.", "com.github.git", "org.cups."]

    /// Identyfikator pakietu z nazwy wpisu: `com.example.App.plist` / `com.example.App.savedState` / `com.example.App` ⇒ `com.example.App`; nil, gdy nazwa nie wygląda na identyfikator.
    public static func bundleID(fromEntryName name: String) -> String? {
        var n = name
        for ext in [".plist", ".savedState", ".binarycookies"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
        let parts = n.split(separator: ".")
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              n.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil else { return nil }
        let tld = parts[0].lowercased()
        guard ["com", "org", "net", "io", "app", "dev", "de", "pl", "co", "us", "uk", "fr", "jp", "me", "ch", "eu", "at", "nl", "se", "it", "info", "tv"].contains(tld) else { return nil }
        return n
    }

    /// Czy wpis należy do zainstalowanej aplikacji albo jest wyjątkiem (Apple, usługi systemowe).
    public static func isOwned(_ id: String, installed: Set<String>) -> Bool {
        let l = id.lowercased()
        if l.hasPrefix("com.apple.") || l.hasPrefix("group.") || l.hasPrefix("systemgroup.") { return true }
        if nonAppPrefixes.contains(where: { l.hasPrefix($0) }) || nonAppMarkers.contains(where: { l.contains($0) }) { return true }
        // Ten sam producent (`com.vendor`) ma zainstalowaną aplikację ⇒ wpis może należeć do jej składników – nie oznaczamy (lepiej przeoczyć niż fałszywie wskazać).
        let vendor = vendorPrefix(l)
        return installed.contains { i in
            let x = i.lowercased()
            return !x.isEmpty && (l == x || l.hasPrefix(x + ".") || x.hasPrefix(l + ".") || (vendor != nil && vendorPrefix(x) == vendor))
        }
    }

    /// `com.vendor` z `com.vendor.App` (nil dla zbyt krótkich identyfikatorów).
    static func vendorPrefix(_ id: String) -> String? {
        let p = id.split(separator: ".")
        return p.count >= 3 ? p.prefix(2).joined(separator: ".") : nil
    }

    /// Wpisy zgrupowane po identyfikatorze (jedna pozycja = jedna aplikacja, suma rozmiarów), największe najpierw.
    public static func grouped(_ items: [AppLeftover]) -> [AppLeftoverGroup] {
        Dictionary(grouping: items, by: { $0.bundleID.lowercased() }).map { _, v in
            AppLeftoverGroup(bundleID: v[0].bundleID, items: v.sorted { $0.size > $1.size })
        }.sorted { $0.size != $1.size ? $0.size > $1.size : $0.bundleID < $1.bundleID }
    }

    /// Przegląda `home` (tylko odczyt, płytko) i zwraca możliwe pozostałości, największe najpierw.
    public static func find(home: String, installedBundleIDs: Set<String>, measure: Bool = true) -> [AppLeftover] {
        let fm = FileManager.default
        var out: [AppLeftover] = []
        for (rel, label) in locations {
            let dir = home + "/" + rel
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard let id = bundleID(fromEntryName: name), !isOwned(id, installed: installedBundleIDs) else { continue }
                let p = dir + "/" + name
                guard let st = FileStat.of(p), !st.isSymlink else { continue }
                let size = measure ? DiskUsage.measure(p).allocated : st.allocatedSize
                out.append(AppLeftover(path: p, bundleID: id, location: label, size: size, modified: st.modified,
                                       risky: rel.hasSuffix("Application Support") || rel.hasSuffix("Containers")))
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

/// Pozostałości jednej aplikacji (wszystkie miejsca w `~/Library`).
public struct AppLeftoverGroup: Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    public var bundleID: String
    public var items: [AppLeftover]
    public var size: UInt64 { items.reduce(0) { $0 + $1.size } }
    public var locations: String { items.map(\.location).joined(separator: ", ") }
    public var lastModified: Date { items.map(\.modified).max() ?? .distantPast }
    public var safeItems: [AppLeftover] { items.filter { !$0.risky } }
    public var riskyItems: [AppLeftover] { items.filter(\.risky) }
}
