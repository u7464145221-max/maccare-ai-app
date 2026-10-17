import Foundation
import MacCareCore
import MacCareSystem

/// Moduł „Aplikacje” (P2-12, część tylko do odczytu): inwentarz aplikacji (rozmiar, ostatnie użycie, podpis, źródło, architektura) i możliwe pozostałości
/// po odinstalowanych aplikacjach w `~/Library`. Niczego nie usuwa – odinstalowanie zostaje w Finderze.
@MainActor
final class AppsStore: ObservableObject {
    enum Sort: String, CaseIterable { case size = "Rozmiar", unused = "Nieużywane", name = "Nazwa" }
    enum Filter: String, CaseIterable { case all = "Wszystkie", unused = "Nieużywane 90+ dni", intel = "Tylko Intel", untrusted = "Podpis spoza Apple" }

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var leftovers: [AppLeftoverGroup]?
    @Published private(set) var loading = false
    @Published private(set) var progress = ScanProgress(done: 0, total: 0, latest: nil)
    @Published var sort: Sort = .size
    @Published var filter: Filter = .all
    /// Ile rozmiarów wzięto z pamięci w ostatnim wczytaniu (testy).
    private(set) var lastSizeCacheHits = 0

    let home: String
    /// Katalogi z aplikacjami (testy podają piaskownicę; nil = /Applications, ~/Applications, /System/Applications).
    var roots: [String]?
    static let unusedDays = 90

    /// Audyt 2 (4.8): plik pamięci rozmiarów w katalogu danych aplikacji (nil = bez pamięci, np. testy bez katalogu danych).
    let sizeCacheURL: URL?

    init(home: String, sizeCacheURL: URL? = nil) { self.home = home; self.sizeCacheURL = sizeCacheURL }

    var loaded: Bool { !apps.isEmpty || leftovers != nil }

    var visibleApps: [InstalledApp] {
        let f: [InstalledApp]
        switch filter {
        case .all: f = apps
        case .unused: f = apps.filter { !$0.isSystem && ($0.daysUnused ?? 0) >= Self.unusedDays }
        case .intel: f = apps.filter(\.isIntelOnly)
        case .untrusted: f = apps.filter { !$0.isSystem && !$0.signature.isTrusted }
        }
        switch sort {
        case .size: return f.sorted { $0.size > $1.size }
        case .unused: return f.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return f.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var totalSize: UInt64 { apps.filter { !$0.isSystem }.reduce(0) { $0 + $1.size } }
    var leftoversSize: UInt64 { (leftovers ?? []).reduce(0) { $0 + $1.size } }

    func load(force: Bool = false) async {
        if loading || (loaded && !force) { return }
        loading = true
        let home = self.home, roots = self.roots
        let refs = await Task.detached(priority: .utility) { AppInventory.enumerate(home: home, roots: roots) }.value
        let casks = await Task.detached(priority: .utility) { AppInventory.homebrewCasks() }.value
        let cacheURL = sizeCacheURL
        let cache = await Task.detached(priority: .utility) { AppSizeCache.load(cacheURL, home: home) }.value
        let keyed = await Task.detached(priority: .utility) { refs.map { (ref: $0, key: AppInventory.sizeKey($0.path, version: $0.version)) } }.value
        func known(_ k: (ref: AppInventory.Ref, key: String?)) -> UInt64? { k.key.flatMap { cache.size(path: k.ref.path, key: $0) } }
        progress = ScanProgress(done: 0, total: refs.count, latest: nil)
        var collected: [InstalledApp] = []
        var lastFlush = Date.distantPast
        await withTaskGroup(of: InstalledApp.self) { g in
            var it = keyed.makeIterator()
            for _ in 0..<4 { if let k = it.next() { let s = known(k); g.addTask { await AppInventory.details(k.ref, casks: casks, knownSize: s) } } }   // najwyżej 4 naraz
            for await a in g {
                collected.append(a)
                progress = ScanProgress(done: collected.count, total: refs.count, latest: a.name)
                if Date().timeIntervalSince(lastFlush) > 0.3 { apps = collected; lastFlush = Date() }
                if let k = it.next() { let s = known(k); g.addTask { await AppInventory.details(k.ref, casks: casks, knownSize: s) } }
            }
        }
        apps = collected
        var fresh = AppSizeCache()
        for k in keyed { if let key = k.key, let a = collected.first(where: { $0.path == k.ref.path }) { fresh.set(path: k.ref.path, key: key, size: a.size) } }
        lastSizeCacheHits = keyed.filter { known($0) != nil }.count
        await Task.detached(priority: .utility) { fresh.save(cacheURL, home: home) }.value
        let ids = Set(refs.map(\.bundleID).filter { !$0.isEmpty })
        leftovers = await Task.detached(priority: .utility) {
            // audyt 2.2: wpis aplikacji, którą system zna w innym miejscu (dysk zewnętrzny, Pobrane…), nie jest pozostałością
            LeftoverFinder.grouped(LeftoverFinder.find(home: home, installedBundleIDs: ids).filter { !AppInventory.launchServicesKnows($0.bundleID) })
        }.value
        loading = false
    }

    /// Nagłówek listy: liczba aplikacji i zajętość tych spoza systemu (bez mylącego „0 B”, gdy wszystkie są systemowe).
    static func headline(_ apps: [InstalledApp]) -> String {
        let all = Plural.counted(apps.count, one: "aplikacja", few: "aplikacje", many: "aplikacji")
        let user = apps.filter { !$0.isSystem }
        if user.isEmpty { return apps.isEmpty ? String(localized: "Aplikacje") : String(localized: "\(all) · wszystkie systemowe") }
        return "\(all) · \(Plural.counted(user.count, one: "spoza systemu zajmuje", few: "spoza systemu zajmują", many: "spoza systemu zajmuje")) \(ByteFormat.string(user.reduce(0) { $0 + $1.size }))"
    }

    static func usageText(_ a: InstalledApp) -> String {
        guard let d = a.daysUnused else { return String(localized: "ostatnie użycie: brak danych") }
        if d < 1 { return String(localized: "używana dziś") }
        let days = Plural.counted(d, one: "dzień", few: "dni", many: "dni")
        return String(localized: "ostatnio użyta \(days) temu")
    }
}

/// Audyt 2 (4.8): zapamiętane rozmiary aplikacji (ścieżka z „~” → odcisk pakietu + rozmiar). Tylko przyspieszenie: uszkodzony lub brakujący
/// plik = pomiar od nowa. Zapis atomowy wyłącznie w katalogu danych aplikacji.
struct AppSizeCache: Codable, Sendable {
    struct Entry: Codable, Sendable { var key: String; var size: UInt64 }
    private var entries: [String: Entry] = [:]
    static let maxEntries = 2000

    func size(path: String, key: String) -> UInt64? {
        entries[Self.norm(path)].flatMap { $0.key == key ? $0.size : nil }
    }
    mutating func set(path: String, key: String, size: UInt64) { entries[Self.norm(path)] = Entry(key: key, size: size) }
    /// Jedna postać ścieżki (enumerator podaje np. /private/var/…, a katalog domowy bywa podany jako /var/…).
    static func norm(_ p: String) -> String { PathTools.canonical(p, home: "/") }

    static func load(_ url: URL?, home: String) -> AppSizeCache {
        guard let url, let data = SafeRead.regularFile(url.path, maxBytes: 4_000_000),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else { return AppSizeCache() }   // try? świadomie: brak lub uszkodzenie pamięci ⇒ pomiar od nowa
        var c = AppSizeCache()
        let canon = norm(home)
        for (p, e) in raw.prefix(maxEntries) { c.entries[DiskMapPersistence.expand(p, home: canon)] = e }
        return c
    }

    func save(_ url: URL?, home: String) {
        guard let url else { return }
        let canon = Self.norm(home)
        let redacted = Dictionary(entries.map { (DiskMapPersistence.redact($0.key, home: canon), $0.value) }, uniquingKeysWith: { a, _ in a })
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? enc.encode(redacted) else { return }                                            // try? świadomie: pamięć to tylko przyspieszenie
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)   // try? świadomie: brak katalogu ⇒ pomiar przy następnym starcie
        try? data.write(to: url, options: .atomic)                                                                        // try? świadomie: brak zapisu ⇒ pomiar przy następnym starcie
    }
}
