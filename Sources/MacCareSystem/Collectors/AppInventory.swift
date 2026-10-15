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
        Set(["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }.map { $0.lowercased() })
    }

    /// Szczegóły jednej aplikacji (rozmiar, ostatnie użycie, podpis, architektury). Podpis przez serializowaną kolejkę.
    public static func details(_ r: Ref, casks: Set<String>) async -> InstalledApp {
        let url = URL(fileURLWithPath: r.path)
        var used: Date?
        if let item = MDItemCreateWithURL(nil, url as CFURL), let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { used = d }
        let size = await Task.detached(priority: .utility) { DiskUsage.measure(r.path).allocated }.value
        let sig = await CodeSignatureChecker.check(path: r.path, deep: false)
        var arch: [String] = []
        if let exe = r.executable, let h = FileHandle(forReadingAtPath: r.path + "/Contents/MacOS/" + exe) {
            arch = architectures(header: (try? h.read(upToCount: 512)) ?? Data()); try? h.close()
        }
        return InstalledApp(name: r.name, bundleID: r.bundleID, version: r.version, path: r.path, size: size, lastUsed: used,
                            signature: sig.status, source: source(path: r.path, signature: sig.status, casks: casks, name: r.name), architectures: arch)
    }
}
#endif
