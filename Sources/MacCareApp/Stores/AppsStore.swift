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

    let home: String
    /// Katalogi z aplikacjami (testy podają piaskownicę; nil = /Applications, ~/Applications, /System/Applications).
    var roots: [String]?
    static let unusedDays = 90

    init(home: String) { self.home = home }

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
        progress = ScanProgress(done: 0, total: refs.count, latest: nil)
        var collected: [InstalledApp] = []
        var lastFlush = Date.distantPast
        await withTaskGroup(of: InstalledApp.self) { g in
            var it = refs.makeIterator()
            for _ in 0..<4 { if let r = it.next() { g.addTask { await AppInventory.details(r, casks: casks) } } }   // najwyżej 4 naraz
            for await a in g {
                collected.append(a)
                progress = ScanProgress(done: collected.count, total: refs.count, latest: a.name)
                if Date().timeIntervalSince(lastFlush) > 0.3 { apps = collected; lastFlush = Date() }
                if let r = it.next() { g.addTask { await AppInventory.details(r, casks: casks) } }
            }
        }
        apps = collected
        let ids = Set(refs.map(\.bundleID).filter { !$0.isEmpty })
        leftovers = await Task.detached(priority: .utility) { LeftoverFinder.grouped(LeftoverFinder.find(home: home, installedBundleIDs: ids)) }.value
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
