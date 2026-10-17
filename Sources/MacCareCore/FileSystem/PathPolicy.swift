import Foundation

/// Rodzaj operacji plikowej – każdy ma własny zakres dozwolonych ścieżek.
public enum FileOperationScope: String, Codable, Sendable {
    /// Czyszczenie wg reguł: tylko ścieżki wyprowadzone z katalogu reguł.
    case ruleCleanup
    /// Element wskazany ręcznie przez użytkownika w UI (np. duży plik, duplikat).
    case userSelected
    /// Odinstalowanie aplikacji (pakiet .app + jej dane).
    case uninstall
    /// Miejsce docelowe przywracania z kwarantanny. `originalPath` z manifestu to dane z dysku, nie zaufane wejście (AUD-DEL-6).
    case restore
}

public enum PathDecision: Equatable, Sendable {
    case allowed
    case denied(String)
    public var isAllowed: Bool { self == .allowed }
}

/// Twarde ograniczenia ścieżek. Działa niezależnie od reguł i od AI – ostatnia linia obrony executora.
public struct PathPolicy: Sendable {
    public let home: String
    /// Dodatkowe korzenie dozwolone przez reguły czyszczenia (już rozwinięte).
    public var ruleRoots: [String]
    /// Katalogi danych MacCare (historia, kwarantanna) – nigdy nie są celem operacji użytkownika (`.userSelected`).
    public var appDataRoots: [String]

    /// Postacie kanoniczne list ochronnych – liczone raz (F9), a nie przy każdym sprawdzeniu ścieżki.
    private let deniedCanonical: [(raw: String, canonical: String)]
    private let protectedCanonical: [(raw: String, canonical: String)]

    public init(home: String = PathTools.home, ruleRoots: [String] = [], appDataRoots: [String] = []) {
        let h = PathTools.canonical(home, home: home)
        self.home = h
        self.ruleRoots = ruleRoots.map { PathTools.canonical($0, home: home) }.filter { !CleanupCatalog.forbiddenRoots.contains($0) }
        self.appDataRoots = appDataRoots.map { PathTools.canonicalLenient($0, home: home) }
        deniedCanonical = Self.hardDenied(home: h).map { ($0, PathTools.canonical($0, home: h)) }
        protectedCanonical = Self.protectedSubtrees(home: h).map { ($0, PathTools.canonical($0, home: h)) }
    }

    /// Lokalizacje, których MacCare nie rusza NIGDY (nawet na wyraźne żądanie).
    public var hardDenied: [String] { Self.hardDenied(home: home) }
    static func hardDenied(home: String) -> [String] {
        ["/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/cores", "/dev", "/opt", "/Library", "/Volumes",
         "/Applications/Utilities", "/System/Applications", "/Network",
         home, home + "/Library", home + "/Library/Keychains", home + "/Library/Mail", home + "/Library/Messages",
         home + "/Library/Mobile Documents", home + "/Library/CloudStorage", home + "/Library/Group Containers",
         home + "/Library/Accounts", home + "/Library/Cookies", home + "/Library/Safari", home + "/Library/Preferences",
         home + "/Library/Application Support/com.apple.TCC", home + "/Library/Application Support/AddressBook",
         home + "/Library/Calendars", home + "/Library/Photos", home + "/Pictures/Photos Library.photoslibrary",
         home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.kube", home + "/.config",
         home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Pictures", home + "/Movies", home + "/Music",
         home + "/Applications",
         // F9 (z PureMac): pliki z danymi logowania i magazyny ciasteczek
         home + "/.netrc", home + "/.git-credentials", home + "/.npmrc", home + "/.pypirc", home + "/.docker", home + "/.azure",
         home + "/.password-store", home + "/Library/HTTPStorages"]
    }

    /// Podkatalogi, których zawartość jest zawsze chroniona (nie tylko sam katalog).
    public var protectedSubtrees: [String] { Self.protectedSubtrees(home: home) }
    static func protectedSubtrees(home: String) -> [String] {
        ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/dev",
         home + "/Library/Keychains", home + "/Library/Messages", home + "/Library/Accounts",
         home + "/Library/Application Support/com.apple.TCC", home + "/Library/Mobile Documents", home + "/Library/CloudStorage",
         home + "/.ssh", home + "/.gnupg", home + "/.aws",
         // F9: konfiguracje z tokenami i hasłami (gh, gcloud, rclone…), klucze chmur i kontenerów, ciasteczka
         home + "/.config", home + "/.kube", home + "/.docker", home + "/.azure", home + "/.password-store", home + "/Library/Cookies"]
    }

    /// F9 (z PureMac): foldery dostawców chmury w katalogu domowym (oprócz iCloud/File Provider w ~/Library). Usunięcie elementu z nich
    /// usuwa go także z chmury, więc Porządki ich nie ruszają, a ręczne zaznaczenie wymaga osobnego przełącznika „Także pliki w chmurze”.
    static let cloudFolderNames: Set<String> = ["Dropbox", "Google Drive", "OneDrive", "Box", "Box Sync", "pCloud Drive", "MEGA", "MEGAsync",
                                                "Sync", "Nextcloud", "ownCloud", "Seafile", "Tresorit", "iCloud Drive (Archive)", "Yandex.Disk"]

    /// Element w chmurze: iCloud Drive / File Provider, folder znanego dostawcy w katalogu domowym albo plik nieobecny na dysku (dataless).
    public static func isCloudLocation(_ path: String, home: String) -> Bool {
        let h = PathTools.canonical(home, home: home)
        if PathTools.isWithin(path, h + "/Library/CloudStorage") || PathTools.isWithin(path, h + "/Library/Mobile Documents") { return true }
        if PathTools.isWithin(path, h), path != h, let first = path.dropFirst(h.count + 1).split(separator: "/").first.map(String.init) {
            if cloudFolderNames.contains(first) || first.hasPrefix("OneDrive - ") || first.hasPrefix("Dropbox (") || first.hasPrefix("Google Drive (") { return true }
        }
        return FileFlags.isDataless(path)
    }

    static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    public func check(_ rawPath: String, scope: FileOperationScope) -> PathDecision {
        guard !rawPath.isEmpty else { return .denied(String(localized: "Pusta ścieżka")) }
        if rawPath.contains("\0") { return .denied(String(localized: "Niedozwolony znak w ścieżce")) }
        let p = resolvedTarget(rawPath)
        guard p.hasPrefix("/") else { return .denied(String(localized: "Ścieżka musi być bezwzględna")) }
        if rawPath.split(separator: "/").contains("..") { return .denied("Niedozwolony segment „..”") }

        // Audyt 3: porównanie z listą chronionych bez rozróżniania wielkości liter i postaci Unicode (domyślny APFS: „~/.SSH” to ten sam katalog
        // co „~/.ssh”). Na woluminie rozróżniającym wielkość liter daje to najwyżej więcej odmów – nigdy mniej.
        let fp = Self.fold(p)
        for d in deniedCanonical where fp == Self.fold(d.canonical) { return .denied("Chroniona lokalizacja: \(d.raw)") }
        for d in protectedCanonical where PathTools.isWithin(fp, Self.fold(d.canonical)) { return .denied("Chroniony obszar: \(d.raw)") }
        // F9: wykluczenie chroni też folder nadrzędny – element ZAWIERAJĄCY chronioną lokalizację (np. ~/Library/Application Support z danymi TCC) jest odrzucany
        if let inner = (deniedCanonical + protectedCanonical).first(where: { Self.fold($0.canonical) != fp && PathTools.isWithin(Self.fold($0.canonical), fp) }) {
            return .denied(String(localized: "Zawiera chronioną lokalizację: \(inner.raw)"))
        }
        // F9: elementy chronione przez system (SIP) albo zablokowane (immutable, append-only)
        if FileFlags.isSystemProtected(p) { return .denied(String(localized: "Element chroniony przez system (SIP) albo zablokowany przed zmianami")) }

        switch scope {
        case .ruleCleanup:
            guard ruleRoots.contains(where: { PathTools.isWithin(p, $0) && p != $0 || p == $0 && isDeletableRoot($0) }) else {
                return .denied(String(localized: "Ścieżka spoza listy dozwolonych lokalizacji czyszczenia"))
            }
            if Self.isCloudLocation(p, home: home) { return .denied(String(localized: "Element w chmurze – Porządki go nie ruszają (usunięcie skasowałoby go też w chmurze)")) }
            if PathTools.isWithin(p, "/Applications") {
                // jedyny dozwolony przypadek: pozostawione instalatory systemu „Install macOS …”.app
                let comps = p.dropFirst("/Applications/".count).split(separator: "/")
                guard comps.count == 1, comps[0].hasPrefix("Install macOS"), comps[0].hasSuffix(".app") else { return .denied(String(localized: "W /Applications czyszczone są tylko instalatory macOS")) }
            }
            return .allowed
        case .userSelected:
            guard PathTools.isWithin(p, home) else { return .denied(String(localized: "Poza katalogiem domowym – inne wolumeny niż startowy nie są obsługiwane (Kosz działa tam inaczej)")) }
            if let why = userSelectedBlockReason(p) { return .denied(why) }
            if PathTools.isWithin(p, home + "/Library") && !ruleRoots.contains(where: { PathTools.isWithin(p, $0) }) {
                return .denied(String(localized: "Dane w ~/Library usuwa się tylko przez reguły lub moduł aplikacji"))
            }
            return .allowed
        case .restore:
            // Dozwolone tylko w katalogu domowym albo w korzeniach reguł czyszczenia (stamtąd elementy pochodzą); chronione lokalizacje odrzucono wyżej.
            guard PathTools.isWithin(p, home) || ruleRoots.contains(where: { PathTools.isWithin(p, $0) }) else {
                return .denied(String(localized: "Miejsce przywrócenia leży poza katalogiem domowym i lokalizacjami czyszczenia"))
            }
            return .allowed
        case .uninstall:
            if p.hasSuffix(".app") && (PathTools.isWithin(p, "/Applications") || PathTools.isWithin(p, home + "/Applications")) {
                if PathTools.isWithin(p, "/System") { return .denied("Aplikacja systemowa") }
                return .allowed
            }
            let appData = ["Application Support", "Caches", "Containers", "Logs", "Saved Application State", "HTTPStorages", "WebKit", "LaunchAgents", "Preferences"]
            if appData.contains(where: { PathTools.isWithin(p, home + "/Library/" + $0) && p != home + "/Library/" + $0 }) {
                return .allowed
            }
            return .denied("Poza obszarem danych aplikacji")
        }
    }

    /// Katalog nadrzędny jest kanonizowany (symlinki rozwiązane), ostatni komponent – NIE.
    /// Dzięki temu operacja na dowiązaniu dotyczy samego dowiązania, a nie wskazywanego pliku,
    /// a dowiązanie w ścieżce nadrzędnej nie pozwala „uciec” z dozwolonego obszaru.
    public func resolvedTarget(_ rawPath: String) -> String {
        var raw = rawPath
        if raw == "~" { raw = home } else if raw.hasPrefix("~/") { raw = home + String(raw.dropFirst(1)) }
        guard raw.hasPrefix("/") else { return raw }
        let std = URL(fileURLWithPath: raw).standardizedFileURL
        let name = std.lastPathComponent
        if std.path == "/" { return "/" }
        let parent = PathTools.canonicalLenient(std.deletingLastPathComponent().path, home: home)      // także gdy dalsze katalogi jeszcze nie istnieją (miejsce przywracania)
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Zakres `.userSelected` (element wskazany ręcznie w UI): dodatkowe blokady – pakiety aplikacji, biblioteki Zdjęć/Muzyki/TV, dane MacCare oraz katalog domowy i jego
    /// foldery pierwszego poziomu jako CAŁOŚĆ (zawartość takiego folderu zaznacza się element po elemencie).
    private func userSelectedBlockReason(_ p: String) -> String? {
        let comps = p.split(separator: "/")
        if comps.contains(where: { $0.lowercased().hasSuffix(".app") }) { return String(localized: "Pakiet aplikacji – aplikacje odinstalowuje się osobnym modułem, nie przez Kosz") }
        if comps.contains(where: { c in [".photoslibrary", ".musiclibrary", ".tvlibrary"].contains { c.lowercased().hasSuffix($0) } }) {
            return String(localized: "Biblioteka Zdjęć/Muzyki/TV – elementy usuwa się z poziomu aplikacji Apple")
        }
        if PathTools.isWithin(p, home + "/Music/Music") || PathTools.isWithin(p, home + "/Music/iTunes") { return String(localized: "Biblioteka aplikacji Muzyka – elementy usuwa się z poziomu aplikacji Apple") }
        if appDataRoots.contains(where: { PathTools.isWithin(p, $0) }) { return String(localized: "Dane MacCare (historia, kwarantanna) nie są celem operacji użytkownika") }
        if (p as NSString).deletingLastPathComponent == home, FileStat.of(p)?.isDirectory == true {
            return String(localized: "Folder pierwszego poziomu katalogu domowego jako całość – zaznacz jego zawartość element po elemencie")
        }
        return nil
    }

    /// Sam korzeń reguły można usunąć tylko, gdy to wyspecjalizowany katalog cache (np. ~/.npm/_cacache), a nie katalog ogólny.
    private func isDeletableRoot(_ root: String) -> Bool {
        let general = [home + "/Library/Caches", home + "/Library/Logs", home + "/.Trash", home + "/Downloads", home + "/Desktop"]
        return !general.contains(root) && !deniedCanonical.contains { $0.canonical == root }
    }
}
