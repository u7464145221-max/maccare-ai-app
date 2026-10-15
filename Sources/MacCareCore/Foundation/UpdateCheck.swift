import Foundation

/// Sprawdzanie aktualizacji (decyzja właściciela 15.10.2026): jedno zapytanie GET o najnowsze wydanie w PUBLICZNYM repozytorium GitHub – tylko na
/// żądanie albo raz w tygodniu po świadomym włączeniu. Bez wysyłania danych o Macu, bez pobierania i bez instalowania: wynik to informacja i link
/// do strony wydania otwierany w przeglądarce. Tu czysta logika (testowalna); połączenie – `UpdateChecker` w aplikacji.
public enum UpdateCheck {
    public static let owner = "u7464145221-max"
    public static let repo = "maccare-ai-app"
    /// Jedyny adres sieciowy poza 127.0.0.1, z którym łączy się MacCare.
    public static let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    public static let interval: TimeInterval = 7 * 24 * 3600

    public struct Release: Equatable, Sendable {
        public var version: [Int]
        public var tag: String
        public var page: URL
    }

    /// „v1.2.3” / „1.2” ⇒ [1, 2, 3] / [1, 2]; nil, gdy to nie jest numer wersji.
    public static func version(_ s: String) -> [Int]? {
        let t = s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let nums = parts.compactMap { Int($0) }
        return nums.count == parts.count && nums.allSatisfy({ $0 >= 0 }) ? nums : nil
    }

    public static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Odczyt odpowiedzi API. Nieufnie: tylko wydanie (nie szkic, nie testowe), numer wersji w tagu, strona wydania WYŁĄCZNIE z tego repozytorium.
    public static func parse(_ data: Data) -> Release? {
        guard data.count <= 512 * 1024, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, let v = version(tag),
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true,
              let html = obj["html_url"] as? String, let url = URL(string: html), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(owner)/\(repo)/releases/") else { return nil }
        return Release(version: v, tag: tag, page: url)
    }

    /// Czy w trybie cotygodniowym pora sprawdzić (wyłączone ⇒ nigdy).
    public static func isDue(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }
}
