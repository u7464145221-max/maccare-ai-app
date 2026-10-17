#if os(macOS)
import Foundation
import CoreServices
import MacCareCore

public enum AppSource: String, Sendable, Codable {
    case system, appStore, homebrew, developerID, other
    public var label: String {
        switch self {
        case .system: return String(localized: "System"); case .appStore: return String(localized: "App Store"); case .homebrew: return String(localized: "Homebrew (cask)")
        case .developerID: return String(localized: "Developer ID"); case .other: return String(localized: "Inne")
        }
    }
}

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var name: String
    public var bundleID: String
    public var version: String
    public var path: String
    public var size: UInt64
    public var lastUsed: Date?
    public var signature: SignatureStatus
    public var source: AppSource
    public var architectures: [String]
    public var isSystem: Bool { path.hasPrefix("/System/") }
    public var daysUnused: Int? { lastUsed.map { Int(Date().timeIntervalSince($0) / 86400) } }
    public var isIntelOnly: Bool { !architectures.isEmpty && !architectures.contains("arm64") }
}

/// Inwentarz zainstalowanych aplikacji (tylko odczyt): `/Applications`, `~/Applications`, `/System/Applications`.
public enum AppInventory {
    /// Audyt 16.10 (2.2): czy system (LaunchServices) zna aplikację o tym identyfikatorze – w DOWOLNYM miejscu (dysk zewnętrzny, Pobrane, głęboko
    /// w podfolderach), a nie tylko w przeglądanych katalogach Programów. Sprawdza też identyfikator „rodzica” (`com.x.App.helper` → `com.x.App`).
    /// Tylko odczyt bazy LaunchServices.
    public static func launchServicesKnows(_ bundleID: String) -> Bool {
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            let id = parts.joined(separator: ".")
            if let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL], !urls.isEmpty { return true }
            parts.removeLast()
        }
        return false
    }

    public struct Ref: Sendable { public let path: String; public let name: String; public let bundleID: String; public let version: String; public let executable: String? }

    /// Szybkie wyliczenie aplikacji (bez rozmiarów i podpisów) – wynik pojawia się natychmiast.
    public static func enumerate(home: String = NSHomeDirectory(), roots: [String]? = nil) -> [Ref] {
        let rs = roots ?? ["/Applications", home + "/Applications", "/System/Applications"]
        var out: [Ref] = []
        var seen = Set<String>()
        for root in rs {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                guard u.pathExtension == "app", seen.insert(u.path).inserted else { continue }
                let info = Bundle(url: u)?.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? u.deletingPathExtension().lastPathComponent
                out.append(Ref(path: u.path, name: name, bundleID: info["CFBundleIdentifier"] as? String ?? "",
                               version: info["CFBundleShortVersionString"] as? String ?? "", executable: info["CFBundleExecutable"] as? String))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Architektury z nagłówka Mach-O (fat lub thin). Czysta funkcja – testowana na syntetycznych bajtach.
    public static func architectures(header d: Data) -> [String] {
        func name(_ cpu: UInt32) -> String? {
            switch cpu { case 0x0100000c: return "arm64"; case 0x01000007: return "x86_64"; case 0x0000000c: return "arm"; case 7: return "i386"; default: return nil }
        }
        func be(_ o: Int) -> UInt32? { o + 4 <= d.count ? d[o..<(o + 4)].reduce(0) { $0 << 8 | UInt32($1) } : nil }
        func le(_ o: Int) -> UInt32? { o + 4 <= d.count ? d[o..<(o + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) } : nil }
        guard let magic = be(0) else { return [] }
        if magic == 0xcafebabe || magic == 0xcafebabf {                         // fat (big-endian)
            guard let n = be(4), n < 16 else { return [] }
            let stride = magic == 0xcafebabe ? 20 : 32
            return (0..<Int(n)).compactMap { be(8 + $0 * stride) }.compactMap(name)
        }
        if magic == 0xcffaedfe || magic == 0xcefaedfe { return le(4).flatMap(name).map { [$0] } ?? [] }   // thin (little-endian)
        return []
    }

    /// Źródło: System, App Store (paragon `_MASReceipt`), Homebrew cask (Caskroom), Developer ID (podpis), inne.
    public static func source(path: String, signature: SignatureStatus, casks: Set<String>, name: String) -> AppSource {
        if path.hasPrefix("/System/") { return .system }
        if FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") { return .appStore }
        let slug = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased().replacingOccurrences(of: " ", with: "-")
        if casks.contains(slug) || casks.contains(name.lowercased().replacingOccurrences(of: " ", with: "-")) { return .homebrew }
        if signature == .developerID || signature == .developerIDNotNotarized { return .developerID }
        if signature == .appStore { return .appStore }
        return .other
    }

    public static func homebrewCasks() -> Set<String> {
        Set(["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }.map { $0.lowercased() })   // try? świadomie: nieczytelny katalog ⇒ brak wpisów (tylko odczyt)
    }

    /// Audyt 2 (4.8): odcisk pakietu do pamięci rozmiarów – folder `.app` i jego `Contents/Info.plist` (urządzenie, i-węzeł, rozmiar, data zmiany).
    /// Aktualizacja aplikacji podmienia Info.plist (i zwykle cały pakiet), więc rozmiar liczony jest wtedy od nowa. nil = nie da się odczytać ⇒ pomiar.
    public static func sizeKey(_ path: String, version: String) -> String? {
        guard let b = FileStat.of(path), !b.isSymlink, let i = FileStat.of(path + "/Contents/Info.plist") else { return nil }
        return [FileFingerprint(b).encoded, FileFingerprint(i).encoded, version].joined(separator: "|")
    }

    /// Szczegóły jednej aplikacji (rozmiar, ostatnie użycie, podpis, architektury). Podpis przez serializowaną kolejkę.
    /// Audyt 2 (4.8): `knownSize` = rozmiar z pamięci podręcznej (pakiet bez zmian od ostatniego pomiaru) – bez ponownego liczenia.
    public static func details(_ r: Ref, casks: Set<String>, knownSize: UInt64? = nil) async -> InstalledApp {
        let url = URL(fileURLWithPath: r.path)
        var used: Date?
        if let item = MDItemCreateWithURL(nil, url as CFURL), let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { used = d }
        let size: UInt64
        if let knownSize { size = knownSize } else { size = await Task.detached(priority: .utility) { DiskUsage.measure(r.path).allocated }.value }
        let sig = await CodeSignatureChecker.check(path: r.path, deep: false)
        var arch: [String] = []
        // Audyt 3: nazwa pliku z nieufnego Info.plist – bez „/” i „..”, odczyt bez podążania za dowiązaniem, tylko plik zwykły (FIFO nie zawiesi listy).
        if let exe = r.executable, !exe.isEmpty, !exe.contains("/"), exe != "..", let d = SafeRead.prefix(r.path + "/Contents/MacOS/" + exe, bytes: 512) {
            arch = architectures(header: d)
        }
        return InstalledApp(name: r.name, bundleID: r.bundleID, version: r.version, path: r.path, size: size, lastUsed: used,
                            signature: sig.status, source: source(path: r.path, signature: sig.status, casks: casks, name: r.name), architectures: arch)
    }
}
#endif
