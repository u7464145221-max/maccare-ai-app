import Foundation

/// 17.10 (decyzja właściciela): prywatność przeglądarek – WYŁĄCZNIE podgląd i informacja. Czyszczenie historii i ciasteczek jest nieodwracalne
/// (wylogowuje ze stron), więc MacCare go nie wykonuje; podpowiada, gdzie zrobić to w samej przeglądarce.
/// Odczyt: tylko `lstat` rozmiaru znanych plików i pomiar folderów pamięci podręcznej – treści plików (adresy, ciasteczka) nie są czytane.
/// Kontener Safari (`~/Library/Containers/com.apple.Safari`) jest pomijany: dostęp do danych innej aplikacji wywołałby systemowe pytanie o zgodę.
public struct BrowserPrivacy: Sendable, Equatable, Identifiable {
    public enum Engine: String, Sendable { case safari, chromium, firefox }
    public var id: String { name }
    public var name: String
    public var engine: Engine
    public var profiles: Int
    /// nil = nie udało się odczytać (np. Safari bez pełnego dostępu do dysku) – to „nie wiadomo”, nie „0 B”.
    public var historyBytes: UInt64?
    public var cookiesBytes: UInt64?
    public var cacheBytes: UInt64?
    /// Audyt 3: pomiar pamięci podręcznej niepełny (limit czasu albo część bez dostępu) – `cacheBytes` to dolna granica.
    public var cachePartial = false

    /// Gdzie wyczyścić dane w samej przeglądarce.
    public var clearHint: String {
        switch engine {
        case .safari: return String(localized: "Safari → Historia → Wyczyść historię…; ciasteczka: Safari → Ustawienia → Prywatność → Zarządzaj danymi witryn…")
        case .chromium: return String(localized: "W przeglądarce: Ustawienia → Prywatność i bezpieczeństwo → Usuń dane przeglądania (⌘⇧⌫).")
        case .firefox: return String(localized: "Firefox → Ustawienia → Prywatność i bezpieczeństwo → Ciasteczka i dane stron / Historia → Wyczyść.")
        }
    }

    struct Spec: Sendable { let name: String; let engine: Engine; let root: String; let cacheRoot: String? }

    /// Znane przeglądarki: katalog danych względem `~/Library` i katalog pamięci podręcznej (profile Chromium: `Default`, `Profile N`).
    static let specs: [Spec] = [
        Spec(name: "Safari", engine: .safari, root: "Safari", cacheRoot: "Caches/com.apple.Safari"),
        Spec(name: "Google Chrome", engine: .chromium, root: "Application Support/Google/Chrome", cacheRoot: "Caches/Google/Chrome"),
        Spec(name: "Brave", engine: .chromium, root: "Application Support/BraveSoftware/Brave-Browser", cacheRoot: "Caches/BraveSoftware/Brave-Browser"),
        Spec(name: "Microsoft Edge", engine: .chromium, root: "Application Support/Microsoft Edge", cacheRoot: "Caches/Microsoft Edge"),
        Spec(name: "Arc", engine: .chromium, root: "Application Support/Arc/User Data", cacheRoot: "Caches/Arc/User Data"),
        Spec(name: "Vivaldi", engine: .chromium, root: "Application Support/Vivaldi", cacheRoot: "Caches/Vivaldi"),
        Spec(name: "Firefox", engine: .firefox, root: "Application Support/Firefox/Profiles", cacheRoot: "Caches/Firefox/Profiles"),
    ]

    /// Przeglądarki, których katalog danych istnieje. `cacheDeadline` – limit pomiaru pamięci podręcznej jednej przeglądarki.
    public static func read(home: String, cacheDeadline: TimeInterval = 5) -> [BrowserPrivacy] {
        let lib = home + "/Library/"
        return specs.compactMap { s in
            let root = lib + s.root
            guard dirExists(root) else { return nil }
            var partial = false
            let cache = s.cacheRoot.flatMap { c -> UInt64? in
                let p = lib + c
                guard FileStat.of(p)?.isDirectory == true else { return 0 }
                var seen = Set<FileID>()
                let u = DiskUsage.measure(p, deadline: Date().addingTimeInterval(cacheDeadline), seen: &seen)
                if u.unreadable > 0 && u.allocated == 0 { return nil }
                partial = u.timedOut || u.unreadable > 0
                return u.allocated
            }
            switch s.engine {
            case .safari:
                return BrowserPrivacy(name: s.name, engine: s.engine, profiles: 1, historyBytes: files(root, ["History.db", "History.db-wal"]),
                                      cookiesBytes: nil, cacheBytes: cache, cachePartial: partial)
            case .chromium:
                let profiles = subdirs(root).filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                guard !profiles.isEmpty else { return nil }
                let h = sum(profiles.map { files(root + "/" + $0, ["History", "History-journal"]) })
                let c = sum(profiles.map { files(root + "/" + $0, ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]) })
                return BrowserPrivacy(name: s.name, engine: s.engine, profiles: profiles.count, historyBytes: h, cookiesBytes: c, cacheBytes: cache, cachePartial: partial)
            case .firefox:
                let profiles = subdirs(root)
                guard !profiles.isEmpty else { return nil }
                let h = sum(profiles.map { files(root + "/" + $0, ["places.sqlite", "places.sqlite-wal"]) })
                let c = sum(profiles.map { files(root + "/" + $0, ["cookies.sqlite", "cookies.sqlite-wal"]) })
                return BrowserPrivacy(name: s.name, engine: s.engine, profiles: profiles.count, historyBytes: h, cookiesBytes: c, cacheBytes: cache, cachePartial: partial)
            }
        }
    }

    /// Suma rozmiarów istniejących plików zwykłych (bez podążania za dowiązaniami). nil = żaden nie dał się odczytać, a katalog jest nieczytelny.
    static func files(_ dir: String, _ names: [String]) -> UInt64? {
        let stats = names.compactMap { FileStat.of(dir + "/" + $0) }.filter(\.isRegular)
        if stats.isEmpty { return readable(dir) ? 0 : nil }
        return stats.reduce(0) { $0 + $1.logicalSize }
    }

    static func sum(_ parts: [UInt64?]) -> UInt64? {
        let known = parts.compactMap { $0 }
        return known.isEmpty && !parts.isEmpty ? nil : known.reduce(0, +)
    }

    static func subdirs(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])                // try? świadomie: nieczytelny katalog ⇒ brak profili (pozycja pominięta)
            .filter { !$0.hasPrefix(".") && FileStat.of(dir + "/" + $0)?.isDirectory == true }.sorted()
    }

    static func readable(_ dir: String) -> Bool { (try? FileManager.default.contentsOfDirectory(atPath: dir)) != nil }   // try? świadomie: odmowa dostępu = „nie wiadomo”
    static func dirExists(_ p: String) -> Bool { FileStat.of(p)?.isDirectory == true }
}
