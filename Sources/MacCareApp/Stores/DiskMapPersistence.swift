import Foundation
import MacCareCore

/// F4: pamięć wyników mapy dysku zapisana między uruchomieniami (pomysł z Radixa – tam zapis był tylko ręczny; u nas automatyczny).
/// Plik w katalogu danych aplikacji, JSON skompresowany LZFSE, zapis atomowy. Ścieżki z „~” zamiast katalogu domowego (nazwa konta nie trafia do pliku).
/// Odczyt jest nieufny: wersja, limity rozmiaru (także po dekompresji), ścieżki bezwzględne bez „..”, nazwy bez „/” – inaczej wpis (albo cały plik) jest pomijany.
/// Zaznaczenia NIE są zapisywane (ich odciski muszą być świeże – W5).
enum DiskMapPersistence {
    static let version = 1
    static let maxCompressedBytes = 8 * 1024 * 1024
    static let maxJSONBytes = 64 * 1024 * 1024

    struct File: Codable {
        var version: Int
        var savedAt: Date
        var listings: [Listing]
    }
    struct Listing: Codable {
        var dir: String
        var measuredAt: Date
        var dirMTime: Date
        var inaccessible: [String]
        var unreadableInside: Int
        var nodes: [Node]
        /// F8: punkt kontrolny dziennika zmian z chwili pomiaru i liczniki „bez dostępu” per dziecko (pliki sprzed F8 ich nie mają – wtedy stare reguły).
        var eventID: UInt64?
        var eventStore: String?
        var unreadableByChild: [String: Int]?
        /// F11: punkt odniesienia porównania (rozmiary dzieci z wcześniejszego pomiaru).
        var previousSizes: [String: UInt64]?
        var previousAt: Date?
    }
    struct Node: Codable {
        var name: String
        var size: UInt64
        var isDirectory: Bool
        var items: Int
        var category: String
        var breakdown: [String: UInt64]
    }

    /// Jeden folder z pamięci wyników (wartość przenoszona między `DiskMapStore` a plikiem).
    struct Entry {
        var dir: String
        var nodes: [MapNode]
        var measuredAt: Date
        var dirMTime: Date
        var inaccessible: [String]
        var unreadableInside: Int
        var checkpoint: ChangeCheckpoint? = nil
        var unreadableByChild: [String: Int] = [:]
        var previousSizes: [String: UInt64] = [:]
        var previousAt: Date? = nil
    }

    static func redact(_ path: String, home: String) -> String {
        path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
    static func expand(_ path: String, home: String) -> String {
        path == "~" ? home : (path.hasPrefix("~/") ? home + path.dropFirst(1) : path)
    }

    static func encode(_ entries: [Entry], home: String, now: Date = Date()) throws -> Data {
        let file = File(version: version, savedAt: now, listings: entries.map { e in
            Listing(dir: redact(e.dir, home: home), measuredAt: e.measuredAt, dirMTime: e.dirMTime,
                    inaccessible: e.inaccessible.map { redact($0, home: home) }, unreadableInside: e.unreadableInside,
                    nodes: e.nodes.map { n in
                        Node(name: n.name, size: n.size, isDirectory: n.isDirectory, items: n.items, category: n.category.rawValue,
                             breakdown: Dictionary(n.breakdown.map { ($0.category.rawValue, $0.bytes) }, uniquingKeysWith: +))
                    },
                    eventID: e.checkpoint?.eventID, eventStore: e.checkpoint?.storeUUID, unreadableByChild: e.unreadableByChild.isEmpty ? nil : e.unreadableByChild,
                    previousSizes: e.previousSizes.isEmpty ? nil : e.previousSizes, previousAt: e.previousAt)
        })
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970        // pełna precyzja (ISO 8601 gubi ułamki sekundy ⇒ każda data zmiany katalogu wyglądałaby na inną)
        let json = try enc.encode(file)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    /// Odczyt z walidacją; zwraca tylko poprawne wpisy (nil = plik nie do użycia: wersja, rozmiar, format).
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }

    static func decode(_ data: Data, home: String) -> [Entry]? {
        guard data.count <= maxCompressedBytes, let json = try? (data as NSData).decompressed(using: .lzfse) as Data,   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
              json.count <= maxJSONBytes, let file = try? decoder.decode(File.self, from: json), file.version == version else { return nil }   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
        return file.listings.compactMap { l -> Entry? in
            let dir = expand(l.dir, home: home)
            guard isSafeAbsolute(dir), l.nodes.count <= 100_000 else { return nil }
            var nodes: [MapNode] = []
            for n in l.nodes {
                guard isSafeName(n.name), let cat = MapCategory(rawValue: n.category) else { return nil }
                let shares = n.breakdown.compactMap { k, v in MapCategory(rawValue: k).map { CategoryShare(category: $0, bytes: v) } }.sorted { $0.bytes > $1.bytes }
                nodes.append(MapNode(path: dir + "/" + n.name, name: n.name, size: n.size, isDirectory: n.isDirectory, items: max(0, n.items), category: cat, breakdown: shares))
            }
            let inaccessible = l.inaccessible.map { expand($0, home: home) }
            guard inaccessible.allSatisfy({ isSafeAbsolute($0) && $0.hasPrefix(dir + "/") }) else { return nil }
            let byChild = l.unreadableByChild ?? [:]
            guard byChild.count <= 100_000, byChild.allSatisfy({ isSafeName($0.key) && $0.value >= 0 }) else { return nil }
            let previous = l.previousSizes ?? [:]
            guard previous.count <= 100_000, previous.keys.allSatisfy(isSafeName) else { return nil }
            var checkpoint: ChangeCheckpoint?
            if let id = l.eventID, let store = l.eventStore, UUID(uuidString: store) != nil { checkpoint = ChangeCheckpoint(eventID: id, storeUUID: store) }
            return Entry(dir: dir, nodes: nodes.sorted { $0.size > $1.size }, measuredAt: l.measuredAt, dirMTime: l.dirMTime,
                         inaccessible: inaccessible, unreadableInside: max(0, l.unreadableInside), checkpoint: checkpoint, unreadableByChild: byChild,
                         previousSizes: previous, previousAt: previous.isEmpty ? nil : l.previousAt)
        }
    }

    static func isSafeName(_ n: String) -> Bool { !n.isEmpty && n != "." && n != ".." && !n.contains("/") && !n.contains("\0") }
    static func isSafeAbsolute(_ p: String) -> Bool {
        p.hasPrefix("/") && !p.contains("\0") && !p.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}
