import Foundation

/// Wpis kwarantanny – wystarczający do przywrócenia elementu na oryginalne miejsce.
public struct QuarantineEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var batchID: String
    public var originalPath: String
    public var storedPath: String
    public var size: UInt64
    public var ruleID: String?
    public var quarantinedAt: Date
}

public enum QuarantineError: Error, LocalizedError, Equatable {
    case sourceMissing(String), destinationOccupied(String), moveFailed(String), unknownEntry(String), readOnlyMode
    /// Tryb Edycja jest włączony, ale jego zakres nie obejmuje tej operacji (`EditScope.trashSelectedOnly`).
    case notAllowed(String)
    /// Wpis manifestu wskazuje poza katalog kwarantanny (uszkodzony albo podmieniony plik stanu) – nic nie zostało ruszone.
    case entryOutsideQuarantine(String)
    /// Miejsce przywrócenia z manifestu nie przechodzi polityki ścieżek – nic nie zostało ruszone.
    case restoreTargetNotAllowed(String)
    /// Błąd odpowiadający aktualnemu trybowi: odczyt ⇒ `.readOnlyMode`, Edycja poza zakresem ⇒ `.notAllowed`.
    static func refusal(for op: MutatingOperation) -> QuarantineError { ExecutionGuard.isReadOnly ? .readOnlyMode : .notAllowed(ExecutionGuard.refusalMessage(for: op)) }
    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let p): return String(localized: "Element nie istnieje: \(p)")
        case .destinationOccupied(let p): return String(localized: "Miejsce docelowe jest zajęte: \(p)")
        case .moveFailed(let m): return String(localized: "Nie udało się przenieść: \(m)")
        case .unknownEntry(let id): return String(localized: "Nieznany wpis kwarantanny: \(id)")
        case .readOnlyMode: return ExecutionGuard.message
        case .notAllowed(let m): return m
        case .entryOutsideQuarantine(let p): return String(localized: "Wpis kwarantanny wskazuje poza jej katalog (uszkodzony lub podmieniony manifest) – nic nie ruszono: \(p)")
        case .restoreTargetNotAllowed(let m): return String(localized: "Miejsce przywrócenia jest niedozwolone – nic nie ruszono: \(m)")
        }
    }
}

/// Kontrolowana kwarantanna: elementy są PRZENOSZONE (rename w obrębie wolumenu – natychmiastowe),
/// manifest zapisywany atomowo przed i po operacji (odporność na przerwanie/utratę zasilania).
/// Uwaga: miejsce na dysku wraca dopiero po `purge` – UI musi to komunikować.
public final class QuarantineStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let clock: Clock
    /// Polityka ścieżek dla miejsca przywracania (zakres `.restore`); `home`/`tempDir` jak w skanerze czyszczenia.
    private let policy: PathPolicy
    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    public private(set) var entries: [QuarantineEntry] = []

    public init(root: URL, clock: Clock = SystemClock(), home: String = PathTools.home, tempDir: String = NSTemporaryDirectory()) {
        self.root = root; self.clock = clock
        policy = PathPolicy(home: home, ruleRoots: CleanupCatalog.allowedRoots(home: home, tempDir: tempDir))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: manifestURL), let e = try? JSONDecoder.iso.decode([QuarantineEntry].self, from: d) { entries = e }
        else { rebuildFromSidecars() }
        recoverInterrupted()
    }

    // MARK: Odporność manifestu (P1-3 / AUD-DEL-5)
    /// Opis wpisu zapisywany OBOK danych (`<root>/<batch>/<id>/.maccare-entry.json`). Gdy manifest jest uszkodzony albo zniknął, wpisy odtwarzamy z tych plików –
    /// dane w kwarantannie nie zostają osierocone. Ścieżkę danych bierzemy z rzeczywistego położenia (nie z pliku), cel przywrócenia i tak sprawdza `restore`.
    static let sidecarName = ".maccare-entry.json"
    /// Manifest był uszkodzony/brakował i wpisy odtworzono z opisów (informacja dla UI).
    public private(set) var rebuiltFromSidecars = false

    private func rebuildFromSidecars() {
        let fm = FileManager.default
        var found: [QuarantineEntry] = []
        for batch in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where batch != ".journal" && !batch.hasPrefix("manifest") {
            let bdir = root.appendingPathComponent(batch, isDirectory: true)
            for id in (try? fm.contentsOfDirectory(atPath: bdir.path)) ?? [] {
                let dir = bdir.appendingPathComponent(id, isDirectory: true)
                guard let d = try? Data(contentsOf: dir.appendingPathComponent(Self.sidecarName)),
                      var e = try? JSONDecoder.iso.decode(QuarantineEntry.self, from: d), e.id == id, e.batchID == batch else { continue }
                let stored = dir.appendingPathComponent((e.storedPath as NSString).lastPathComponent).path
                guard isQuarantineEntryPath(stored), FileStat.of(stored) != nil else { continue }
                e.storedPath = stored
                found.append(e)
            }
        }
        guard !found.isEmpty else { return }
        entries = found.sorted { $0.quarantinedAt < $1.quarantinedAt }
        rebuiltFromSidecars = true
        // Zapis odtworzonego manifestu (z kopią uszkodzonego) tylko, gdy wolno zmieniać kwarantannę – w trybie odczytu wpisy są widoczne, ale nic nie jest zapisywane.
        guard ExecutionGuard.allows(.quarantineRecover) else { return }
        if fm.fileExists(atPath: manifestURL.path) {
            // bez kopii uszkodzonego manifestu NIE nadpisujemy go (wpisy i tak są w pamięci, a opisy obok danych zostają)
            guard (try? fm.moveItem(at: manifestURL, to: root.appendingPathComponent("manifest.json.corrupt-\(Int(clock.now.timeIntervalSince1970))"))) != nil else { return }   // try? świadomie: wynik sprawdzany
        }
        try? saveManifest()
    }

    /// - Parameter allowedDirectory: zakres dla wywołań spoza reguł czyszczenia (np. `~/Library/LaunchAgents` przy wyłączaniu agenta) – rozwiązana ścieżka
    ///   musi w nim leżeć; nil = polityka reguł czyszczenia (`.ruleCleanup`).
    public func quarantine(path: String, size: UInt64, ruleID: String?, batchID: String, within allowedDirectory: String? = nil) throws -> QuarantineEntry {
        guard ExecutionGuard.allows(.quarantineMove) else { throw QuarantineError.refusal(for: .quarantineMove) }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard FileStat.of(path) != nil else { throw QuarantineError.sourceMissing(path) }
        // P1-1 (AUD-DEL-1): ponowna kontrola polityki TUŻ przed przeniesieniem (rozwiązuje dowiązania) – katalog nadrzędny podmieniony po wcześniejszej
        // kontroli dowiązaniem poza listę dozwolonych jest odrzucany, nic nie jest przenoszone.
        if let dir = allowedDirectory {
            let resolved = PathTools.canonicalLenient(path), base = PathTools.canonicalLenient(dir)
            guard PathTools.isWithin(resolved, base), resolved != base else { throw QuarantineError.notAllowed(String(localized: "Cel zmienił się po sprawdzeniu albo leży poza \(dir) – nic nie ruszono: \(path)")) }
        } else if case .denied(let why) = policy.check(path, scope: .ruleCleanup) {
            throw QuarantineError.notAllowed(String(localized: "Cel zmienił się po sprawdzeniu albo leży poza dozwolonymi miejscami (\(why)) – nic nie ruszono: \(path)"))
        }
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(batchID, isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((path as NSString).lastPathComponent)
        let entry = QuarantineEntry(id: id, batchID: batchID, originalPath: path, storedPath: dest.path, size: size, ruleID: ruleID, quarantinedAt: clock.now)
        // 1) zapis intencji (journal) – po awarii wiemy, co przywrócić
        try writeJournal(entry)
        do { try fm.moveItem(atPath: path, toPath: dest.path) }
        catch { try? fm.removeItem(at: dir); clearJournal(entry.id); throw QuarantineError.moveFailed(error.localizedDescription) }   // try? świadomie: pusty katalog wpisu po nieudanym przeniesieniu; błąd przeniesienia i tak jest zgłaszany
        try? JSONEncoder.iso.encode(entry).write(to: dir.appendingPathComponent(Self.sidecarName), options: .atomic)     // P1-3: opis obok danych
        entries.append(entry)
        try saveManifest()
        clearJournal(entry.id)
        return entry
    }

    public func restore(_ id: String) throws {
        guard ExecutionGuard.allows(.quarantineRestore) else { throw QuarantineError.refusal(for: .quarantineRestore) }
        lock.lock(); defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw QuarantineError.unknownEntry(id) }
        let e = entries[i]
        let fm = FileManager.default
        // Manifest to dane z dysku, nie zaufane wejście: źródło musi leżeć w kwarantannie (AUD-DEL-2b), a cel przejść politykę ścieżek (AUD-DEL-6).
        guard isQuarantineEntryPath(e.storedPath) else { throw QuarantineError.entryOutsideQuarantine(e.storedPath) }
        if case .denied(let why) = policy.check(e.originalPath, scope: .restore) { throw QuarantineError.restoreTargetNotAllowed("\(e.originalPath): \(why)") }
        guard FileStat.of(e.storedPath) != nil else { throw QuarantineError.sourceMissing(e.storedPath) }
        guard FileStat.of(e.originalPath) == nil else { throw QuarantineError.destinationOccupied(e.originalPath) }
        try fm.createDirectory(atPath: (e.originalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try fm.moveItem(atPath: e.storedPath, toPath: e.originalPath) }
        catch { throw QuarantineError.moveFailed(error.localizedDescription) }
        try? fm.removeItem(atPath: (e.storedPath as NSString).deletingLastPathComponent)   // try? świadomie: katalog wpisu po przywróceniu (został w nim tylko opis) – pozostałość niczego nie psuje
        entries.remove(at: i)
        try saveManifest()
    }

    /// Wynik `purgeDetailed`: zwolnione bajty oraz identyfikatory wpisów, których NIE usunięto, bo wskazują poza katalog kwarantanny.
    public struct PurgeOutcome: Sendable, Equatable {
        public var freed: UInt64
        public var refused: [String]
        /// P2-1 (AUD-DEL-3): wpisy, których danych NIE udało się usunąć – zostają w manifeście i nie są liczone jako zwolnione.
        public var failed: [String] = []
    }

    /// Trwałe usunięcie wpisów starszych niż `olderThan` (domyślnie 7 dni) lub wskazanych.
    @discardableResult
    public func purge(olderThan age: TimeInterval? = 7 * 86400, ids: Set<String>? = nil) -> UInt64 {
        purgeDetailed(olderThan: age, ids: ids).freed
    }

    /// Jak `purge`, ale zwraca też wpisy odrzucone: wpis, którego `storedPath` nie leży w kwarantannie (uszkodzony/podmieniony manifest), NIE jest kasowany
    /// i zostaje w manifeście (AUD-DEL-2) – kasowanie `dirname(storedPath)` z takiego wpisu usunęłoby dowolny katalog.
    public func purgeDetailed(olderThan age: TimeInterval? = 7 * 86400, ids: Set<String>? = nil) -> PurgeOutcome {
        guard ExecutionGuard.allows(.quarantinePurge) else { return PurgeOutcome(freed: 0, refused: []) }          // odczyt i Edycja poza zakresem: nic nie usuwamy
        lock.lock(); defer { lock.unlock() }
        var freed: UInt64 = 0
        var refused: [String] = [], failed: [String] = []
        let now = clock.now
        entries.removeAll { e in
            let hit = ids.map { $0.contains(e.id) } ?? (age.map { now.timeIntervalSince(e.quarantinedAt) >= $0 } ?? true)
            guard hit else { return false }
            guard isQuarantineEntryPath(e.storedPath) else { refused.append(e.id); return false }
            do { try FileManager.default.removeItem(atPath: (e.storedPath as NSString).deletingLastPathComponent) }
            catch { failed.append(e.id); return false }                    // dane nadal na dysku ⇒ wpis zostaje, nic nie „zwolniono”
            freed += e.size
            return true
        }
        try? saveManifest()
        return PurgeOutcome(freed: freed, refused: refused, failed: failed)
    }

    public var totalSize: UInt64 { entries.reduce(0) { $0 + $1.size } }

    // MARK: Dziennik operacji (odporność na przerwanie)
    private var journalDir: URL { root.appendingPathComponent(".journal", isDirectory: true) }
    private func writeJournal(_ e: QuarantineEntry) throws {
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(e).write(to: journalDir.appendingPathComponent(e.id + ".json"), options: .atomic)
    }
    private func clearJournal(_ id: String) { try? FileManager.default.removeItem(at: journalDir.appendingPathComponent(id + ".json")) }   // try? świadomie: niezdjęty wpis dziennika obsłuży `recoverInterrupted` (bez duplikatów)

    /// Czy `path` leży ŚCIŚLE wewnątrz katalogu kwarantanny, w miejscu przewidzianym dla wpisu: `<root>/<batch>/<id>/<nazwa>` (po rozwiązaniu dowiązań i „..”),
    /// więc `dirname` to `<root>/<batch>/<id>` – nigdy `<root>`, `.journal` ani nic poza kwarantanną.
    func isQuarantineEntryPath(_ path: String) -> Bool {
        let r = PathTools.canonicalLenient(root.path), p = PathTools.canonicalLenient(path)
        guard PathTools.isWithin(p, r), p != r else { return false }
        let rel = p.dropFirst(r.count + 1).split(separator: "/")
        return rel.count >= 3 && rel.first != ".journal"
    }

    /// Po awarii: jeśli element zdążył się przenieść – dopisz do manifestu; jeśli nie – usuń intencję.
    /// W4 (AUD-DEL-8/8b, minimalny zakres): (1) nic nie robi, gdy `ExecutionGuard` nie dopuszcza `.quarantineRecover` – wcześniej działało przy KAŻDYM starcie aplikacji,
    /// także w trybie tylko do odczytu; (2) wpis dziennika, którego `storedPath` nie leży w katalogu kwarantanny, jest ignorowany – nie trafia do manifestu i nic poza
    /// kwarantanną nie jest kasowane (dziennik to dane z dysku, nie zaufane wejście). Kasowany jest wyłącznie sam plik dziennika (leży w `.journal`).
    private func recoverInterrupted() {
        guard ExecutionGuard.allows(.quarantineRecover) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: journalDir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            guard let d = try? Data(contentsOf: f), let e = try? JSONDecoder.iso.decode(QuarantineEntry.self, from: d) else { continue }
            if isQuarantineEntryPath(e.storedPath) {
                if FileStat.of(e.storedPath) != nil, !entries.contains(where: { $0.id == e.id }) { entries.append(e) }
                else if FileStat.of(e.storedPath) == nil { try? FileManager.default.removeItem(atPath: (e.storedPath as NSString).deletingLastPathComponent) }   // try? świadomie: pusty katalog niedokończonego wpisu w kwarantannie
            }
            try? FileManager.default.removeItem(at: f)   // try? świadomie: przetworzony plik dziennika (leży w `.journal`)
        }
        try? saveManifest()
    }

    private func saveManifest() throws {
        try JSONEncoder.iso.encode(entries).write(to: manifestURL, options: .atomic)
    }
}

extension JSONEncoder {
    public static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
extension JSONDecoder {
    public static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Usługa Kosza systemowego – implementacja na macOS w MacCareSystem (FileManager.trashItem).
public protocol TrashService: Sendable {
    /// Zwraca ścieżkę w Koszu (do ewentualnego przywrócenia).
    func moveToTrash(_ path: String) throws -> String?
}

public struct UnavailableTrash: TrashService {
    public init() {}
    public struct NotSupported: Error, LocalizedError { public var errorDescription: String? { String(localized: "Kosz systemowy niedostępny na tej platformie") } }
    public func moveToTrash(_ path: String) throws -> String? { throw NotSupported() }
}
