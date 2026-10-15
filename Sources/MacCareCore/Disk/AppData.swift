import Foundation

/// F15 (odinstalowywanie przez Kosz, decyzja właściciela 15.10.2026): dane zainstalowanej aplikacji w `~/Library`, z poziomem pewności powiązania
/// (skill `maccare-app-inventory`). Tylko wpisy NAZWANE identyfikatorem aplikacji (pewne) albo jej pomocnika `<id>.<coś>` (prawdopodobne) – nigdy
/// po podobnej nazwie, producencie ani w kontenerach grup. Miejsca z danymi użytkownika (Application Support, kontener) są „ryzykowne” i domyślnie odznaczone.
public struct AppDataItem: Sendable, Hashable, Identifiable {
    public enum Association: String, Sendable { case certain, probable }
    public var id: String { path }
    public var path: String
    public var location: String
    public var association: Association
    /// Może zawierać dokumenty lub ustawienia użytkownika – nie zaznaczamy domyślnie.
    public var risky: Bool
    public var size: UInt64
    public var defaultSelected: Bool { association == .certain && !risky }
}

public enum AppData {
    /// (podkatalog `~/Library`, czy ryzykowny)
    public static let locations: [(rel: String, risky: Bool)] = [
        ("Library/Caches", false), ("Library/Preferences", false), ("Library/Saved Application State", false), ("Library/Logs", false),
        ("Library/HTTPStorages", false), ("Library/WebKit", false),
        ("Library/Application Support", true), ("Library/Containers", true)]

    /// Powiązanie wpisu (nazwa pierwszego poziomu w jednym z `locations`) z aplikacją; nil – wpis nie należy do niej.
    public static func association(entryName: String, appBundleID: String) -> AppDataItem.Association? {
        guard let id = LeftoverFinder.bundleID(fromEntryName: entryName)?.lowercased() else { return nil }
        let app = appBundleID.lowercased()
        guard !app.isEmpty, !app.hasPrefix("com.apple.") else { return nil }
        if id == app { return .certain }
        if id.hasPrefix(app + ".") { return .probable }
        return nil
    }

    /// Czy `path` to wpis pierwszego poziomu w jednym ze znanych miejsc (niezależnie od interfejsu – wykonanie sprawdza to ponownie).
    public static func location(of path: String, home: String) -> (rel: String, risky: Bool)? {
        let parent = (path as NSString).deletingLastPathComponent
        return locations.first { home + "/" + $0.rel == parent }
    }

    /// Dane aplikacji na dysku (tylko odczyt, płytko + rozmiar).
    public static func find(appBundleID: String, home: String) -> [AppDataItem] {
        var out: [AppDataItem] = []
        let fm = FileManager.default
        for loc in locations {
            let dir = home + "/" + loc.rel
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names {
                guard let a = association(entryName: n, appBundleID: appBundleID) else { continue }
                let p = dir + "/" + n
                guard let st = FileStat.of(p), !st.isSymlink else { continue }
                out.append(AppDataItem(path: p, location: (loc.rel as NSString).lastPathComponent, association: a, risky: loc.risky, size: DiskUsage.measure(p).allocated))
            }
        }
        return out.sorted { ($0.defaultSelected ? 0 : 1, $1.size) < ($1.defaultSelected ? 0 : 1, $0.size) }
    }
}
