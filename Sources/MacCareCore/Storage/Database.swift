import Foundation
import CSQLite

public struct DatabaseError: Error, LocalizedError { public var message: String; public var errorDescription: String? { "SQLite: \(message)" } }

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimalna, bezpieczna nakładka na SQLite (parametryzowane zapytania, WAL, synchronizacja przez kolejkę).
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    /// Jedno połączenie dzielone przez wiele wątków: blokada REKURENCYJNA, żeby transakcja (BEGIN…COMMIT) trzymała ją przez całe ciało,
    /// a zapisy wewnątrz ciała (ten sam wątek) mogły ją ponownie wziąć. Audyt 16.10 (2.4): wcześniej każde polecenie brało blokadę osobno,
    /// więc obcy zapis mógł wpaść w środek cudzej transakcji (albo drugi BEGIN kończył się błędem i zapis przepadał).
    private let lock = NSRecursiveLock()
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    public enum Value: Sendable, Equatable { case null, int(Int64), double(Double), text(String) }

    public init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DatabaseError(message: String(localized: "nie można otworzyć bazy \(path)"))
        }
        // busy_timeout (skill maccare-sqlite-history): przy chwilowej blokadzie bazy SQLite czeka do 3 s zamiast od razu zwracać SQLITE_BUSY (zgubiony wpis)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;")
    }
    deinit { sqlite3_close(db) }

    public func exec(_ sql: String) throws {
        try locked {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "?"; sqlite3_free(err); throw DatabaseError(message: m)
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        try locked {
            let st = try prepare(sql, params); defer { sqlite3_finalize(st) }
            let rc = sqlite3_step(st)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Liczba wierszy zmienionych przez ostatnie polecenie (w tej samej blokadzie co transakcja – blokada rekurencyjna).
    public var changes: Int { locked { Int(sqlite3_changes(db)) } }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        try locked {
            let st = try prepare(sql, params); defer { sqlite3_finalize(st) }
            var rows: [[String: Value]] = []
            while true {
                let rc = sqlite3_step(st)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
                var row: [String: Value] = [:]
                for i in 0..<sqlite3_column_count(st) {
                    let name = String(cString: sqlite3_column_name(st, i))
                    switch sqlite3_column_type(st, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(st, i))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(st, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(st, i)))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }                                                // cała transakcja pod jedną blokadą (inne wątki czekają)
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }   // try? świadomie: pierwotny błąd jest zgłaszany; nieudany ROLLBACK SQLite i tak wycofuje przy kolejnym BEGIN
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(st, idx)
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT_PTR)
            }
        }
        return st
    }
}

extension SQLiteDatabase.Value {
    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var double: Double? { switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil } }
    public var int: Int64? { switch self { case .int(let i): return i; case .double(let d): return Int64(d); default: return nil } }
}

/// Historia: skany, operacje (audyt), szeregi pomiarów, porównania przed/po, ustawienia.
public final class HistoryStore: AuditSink, @unchecked Sendable {
    public let db: SQLiteDatabase
    public static let schemaVersion = 2
    /// Migracje schematu: klucz n = przejście z wersji n do n+1 (dziś brak – schemat 1). Nowa kolumna = nowy wpis i `schemaVersion` + 1.
    static let migrations: [Int: @Sendable (SQLiteDatabase) throws -> Void] = [
        // 1 → 2 (audyt 16.10): znacznik zagęszczonej próbki jako kolumna. Wcześniej rozpoznawany po czasie „pełna godzina + 30 min”, więc zwykła
        // próbka zapisana dokładnie o hh:30:00 była brana za średnią i zostawała obok niej (dwa punkty tej samej godziny).
        1: { db in
            let hasAgg = try db.query("PRAGMA table_info(samples)").contains { $0["name"] == .text("agg") }
            if !hasAgg { try db.exec("ALTER TABLE samples ADD COLUMN agg INTEGER NOT NULL DEFAULT 0") }   // powtarzalne: kolumna mogła już powstać
            try db.exec("UPDATE samples SET agg = 1 WHERE (at - CAST(at/3600 AS INTEGER)*3600) = 1800")
        },
    ]
    /// Wersja schematu zastana w pliku przy otwarciu (nil = nowa baza).
    public private(set) var storedSchemaVersion: Int?

    /// Katalog domowy zastępowany „~” w zapisach dziennika operacji (P3-6 / AUD-PRIV-1): w bazie nie ma nazwy konta. nil = bez redakcji.
    public let redactedHome: String?

    public init(path: String, redactingHome home: String? = nil) throws {
        db = try SQLiteDatabase(path: path)
        redactedHome = home.flatMap { $0.count > 1 ? $0 : nil }
        try migrate()
    }

    /// `/Users/jan/x` ⇒ `~/x` (także w postaci z ukośnikami poprzedzonymi „\” z JSON-a).
    /// Audyt 3: zamiana tylko na granicy elementu ścieżki (`/Users/jan` nie psuje `/Users/janek`), także dla postaci kanonicznej katalogu domowego.
    func redact(_ s: String) -> String {
        guard let h = redactedHome else { return s }
        var out = s
        let canon = PathTools.canonical(h, home: h)
        for home in Set([h, canon]) where home.count > 1 {
            for form in [home, home.replacingOccurrences(of: "/", with: "\\/")] {
                let pattern = NSRegularExpression.escapedPattern(for: form) + #"(?=$|[/\\"'\s,;:)\]}])"#
                if let re = try? NSRegularExpression(pattern: pattern) {                      // try? świadomie: wzorzec z escapedPattern jest zawsze poprawny
                    out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
                }
            }
        }
        return out
    }

    // MARK: Błędy bazy (P2-17 / AUD-ARCH-5)
    /// Zapis i odczyt historii nie przerywają pracy aplikacji, ale błąd NIE jest przemilczany: liczba nieudanych operacji i ostatni komunikat
    /// są dostępne dla interfejsu (Historia pokazuje ostrzeżenie), a wynik odczytu po błędzie to „brak danych”, nie pusta historia bez słowa.
    private let errorLock = NSLock()
    private var _failures = 0
    private var _lastError: String?
    public var failureCount: Int { errorLock.lock(); defer { errorLock.unlock() }; return _failures }
    public var lastError: String? { errorLock.lock(); defer { errorLock.unlock() }; return _lastError }

    /// Wykonuje operację na bazie; błąd jest liczony i zapamiętywany (z opisem, czego dotyczył), wynik = `fallback`.
    @discardableResult
    func attempt<T>(_ what: String, _ fallback: T, _ body: () throws -> T) -> T {
        do { return try body() } catch {
            errorLock.lock(); _failures += 1; _lastError = "\(what): \(error)"; errorLock.unlock()
            return fallback
        }
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS scans(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL,
            findings INTEGER, reclaimable INTEGER, health INTEGER, payload TEXT);
        CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, call_id TEXT, at REAL NOT NULL, tool TEXT NOT NULL, origin TEXT,
            mode TEXT, outcome TEXT, args TEXT, message TEXT);
        CREATE TABLE IF NOT EXISTS reclaimed(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, operation TEXT,
            estimated INTEGER, measured INTEGER, note TEXT);
        CREATE TABLE IF NOT EXISTS samples(at REAL NOT NULL, metric TEXT NOT NULL, value REAL NOT NULL, agg INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS samples_metric_at ON samples(metric, at);
        CREATE TABLE IF NOT EXISTS findings_log(at REAL NOT NULL, finding_id TEXT NOT NULL, severity INTEGER, certainty TEXT, title TEXT);
        CREATE TABLE IF NOT EXISTS benchmarks(id TEXT PRIMARY KEY, at REAL NOT NULL, operation TEXT, verdict TEXT, payload TEXT);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
        CREATE INDEX IF NOT EXISTS operations_at ON operations(at);
        CREATE INDEX IF NOT EXISTS scans_at ON scans(at);
        CREATE INDEX IF NOT EXISTS findings_log_at ON findings_log(at);
        CREATE INDEX IF NOT EXISTS benchmarks_at ON benchmarks(at);
        """)
        // Audyt 16.10 (3.8): wersja schematu jest CZYTANA. Starsza baza przechodzi kolejne migracje (`migrations[n]` = przejście n → n+1, w transakcji);
        // baza z nowszej wersji aplikacji nie jest „cofana” – zostaje bez zmian, a problem trafia do licznika błędów (widoczny w Historii).
        let stored = (try db.query("SELECT value FROM meta WHERE key = 'schema'")).first?["value"]?.string.flatMap { Int($0) }
        storedSchemaVersion = stored
        if let v = stored, v > Self.schemaVersion {
            attempt("schemat bazy", ()) { throw DatabaseError(message: String(localized: "baza zapisana przez nowszą wersję MacCare (schemat \(v) > \(Self.schemaVersion)) – nie jest zmieniana")) }
            return
        }
        // Audyt 2: migracje i zapis wersji w JEDNEJ transakcji (przerwanie nie zostawia „zmigrowane, ale wersja stara”), a każdy krok jest powtarzalny
        // (np. po uruchomieniu v0.1.0, która zawsze zapisuje schemat 1, na bazie już zmigrowanej).
        try db.transaction {
            for from in (stored ?? Self.schemaVersion)..<Self.schemaVersion {
                guard let step = Self.migrations[from] else { throw DatabaseError(message: "brak migracji schematu \(from) → \(from + 1)") }
                try step(db)
            }
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)", [.text(String(Self.schemaVersion))])
        }
    }

    // MARK: Audyt
    public func record(_ r: AuditRecord) {
        attempt("dziennik operacji", ()) { try db.run("INSERT OR REPLACE INTO operations(id, call_id, at, tool, origin, mode, outcome, args, message) VALUES(?,?,?,?,?,?,?,?,?)",
                        [.text(r.id), .text(r.callID), .double(r.at.timeIntervalSince1970), .text(r.tool), .text(r.origin.rawValue),
                         .text(r.mode.rawValue), .text(r.outcome.rawValue), .text(redact(r.argumentsJSON)), .text(redact(r.message))]) }
    }

    public func operations(limit: Int = 200) -> [AuditRecord] {
        attempt("odczyt dziennika operacji", []) { try db.query("SELECT * FROM operations ORDER BY at DESC LIMIT ?", [.int(Int64(limit))]) }.compactMap { r in
            guard let id = r["id"]?.string, let tool = r["tool"]?.string, let at = r["at"]?.double else { return nil }
            return AuditRecord(id: id, callID: r["call_id"]?.string ?? "", tool: tool, argumentsJSON: r["args"]?.string ?? "{}",
                               origin: CallOrigin(rawValue: r["origin"]?.string ?? "") ?? .user, mode: AgentMode(rawValue: r["mode"]?.string ?? "") ?? .assistant,
                               outcome: AuditRecord.Outcome(rawValue: r["outcome"]?.string ?? "") ?? .failed, message: r["message"]?.string ?? "",
                               at: Date(timeIntervalSince1970: at))
        }
    }

    // MARK: Skany i ustalenia
    public func recordScan(kind: String, at: Date, findings: [Finding], reclaimable: UInt64, health: Int?) {
        attempt("zapis skanu", ()) { try db.transaction {
            try db.run("INSERT INTO scans(at, kind, findings, reclaimable, health, payload) VALUES(?,?,?,?,?,?)",
                       [.double(at.timeIntervalSince1970), .text(kind), .int(Int64(findings.count)), .int(Int64(reclaimable)),
                        health.map { .int(Int64($0)) } ?? .null, .text(redact(String(decoding: try JSONEncoder.iso.encode(findings), as: UTF8.self)))])   // audyt 3.2: „~” zamiast konta
            for f in findings {
                try db.run("INSERT INTO findings_log(at, finding_id, severity, certainty, title) VALUES(?,?,?,?,?)",
                           [.double(at.timeIntervalSince1970), .text(f.id), .int(Int64(f.severity.rawValue)), .text(f.certainty.rawValue), .text(redact(f.title))])
            }
        } }
    }

    public struct ScanRow: Sendable, Identifiable { public var id: Int64; public var at: Date; public var kind: String; public var findings: Int; public var reclaimable: UInt64; public var health: Int? }
    public func scans(since: Date? = nil, limit: Int = 500) -> [ScanRow] {
        attempt("odczyt skanów", []) { try db.query("SELECT id, at, kind, findings, reclaimable, health FROM scans WHERE at >= ? ORDER BY at DESC LIMIT ?",
                        [.double((since ?? .distantPast).timeIntervalSince1970), .int(Int64(limit))]) }.compactMap { r in
            guard let id = r["id"]?.int, let at = r["at"]?.double else { return nil }
            return ScanRow(id: id, at: Date(timeIntervalSince1970: at), kind: r["kind"]?.string ?? "", findings: Int(r["findings"]?.int ?? 0),
                           reclaimable: UInt64(max(0, r["reclaimable"]?.int ?? 0)), health: r["health"]?.int.map { Int($0) })
        }
    }

    // MARK: Odzyskane miejsce (zmierzone, nie deklarowane)
    public func recordReclaimed(operation: String, estimated: UInt64, measured: Int64?, note: String, at: Date) {
        attempt("zapis odzyskanego miejsca", ()) { try db.run("INSERT INTO reclaimed(at, operation, estimated, measured, note) VALUES(?,?,?,?,?)",
                        [.double(at.timeIntervalSince1970), .text(operation), .int(Int64(estimated)), measured.map { .int($0) } ?? .null, .text(redact(note))]) }
    }
    public func totalReclaimedMeasured(since: Date = .distantPast) -> Int64 {
        attempt("odczyt odzyskanego miejsca", []) { try db.query("SELECT COALESCE(SUM(measured),0) AS s FROM reclaimed WHERE at >= ? AND measured > 0", [.double(since.timeIntervalSince1970)]) }.first?["s"]?.int ?? 0
    }

    // MARK: Szeregi czasowe
    public func recordSamples(_ values: [String: Double], at: Date) {
        attempt("zapis próbek", ()) { try db.transaction { for (k, v) in values { try db.run("INSERT INTO samples(at, metric, value) VALUES(?,?,?)", [.double(at.timeIntervalSince1970), .text(k), .double(v)]) } } }
    }
    public func series(_ metric: String, since: Date) -> [(Date, Double)] {
        attempt("odczyt próbek", []) { try db.query("SELECT at, value FROM samples WHERE metric = ? AND at >= ? ORDER BY at", [.text(metric), .double(since.timeIntervalSince1970)]) }
            .compactMap { r in guard let a = r["at"]?.double, let v = r["value"]?.double else { return nil }; return (Date(timeIntervalSince1970: a), v) }
    }
    /// Retencja: próbki starsze niż N dni są agregowane (średnia godzinowa) – kontrola rozmiaru bazy.
    public func compactSamples(olderThan days: Double = 7, now: Date = Date()) {
        // audyt 16.10 (P3): odcięcie wyrównane do PEŁNEJ godziny – inaczej godzina na granicy dostawała przy kolejnym zagęszczaniu drugi punkt średniej
        let cutoff = ((now.timeIntervalSince1970 - days * 86400) / 3600).rounded(.down) * 3600
        attempt("zagęszczanie próbek", ()) { try db.transaction {
            try db.run("""
            INSERT INTO samples(at, metric, value, agg)
            SELECT CAST(at/3600 AS INTEGER)*3600 + 1800 AS hour, metric, AVG(value), 1 FROM samples
            WHERE at < ? AND agg = 0 GROUP BY hour, metric
            """, [.double(cutoff)])
            try db.run("DELETE FROM samples WHERE at < ? AND agg = 0", [.double(cutoff)])
        } }
    }

    /// Audyt 2 (4.14): retencja historii (dni). Dziennik operacji – najdłużej, bo to zapis zmian na Macu; łączna suma odzyskanego miejsca
    /// (`reclaimed`), ustawienia i metadane nie są przycinane. Wiek liczony od `now`, więc zmiana zegara do przodu przycina najwyżej starsze wpisy.
    public static let retentionDays: [(table: String, days: Double)] = [
        ("samples", 400), ("findings_log", 180), ("scans", 400), ("benchmarks", 400), ("operations", 730)
    ]

    /// Usuwa wpisy starsze niż okres retencji (jedna transakcja). Zwraca liczbę usuniętych wierszy (testy).
    @discardableResult
    public func pruneOld(now: Date = Date()) -> Int {
        attempt("retencja historii", 0) {
            var removed = 0
            try db.transaction {
                for (table, days) in Self.retentionDays {
                    try db.run("DELETE FROM \(table) WHERE at < ?", [.double(now.timeIntervalSince1970 - days * 86400)])
                    removed += db.changes
                }
            }
            return removed
        }
    }

    // MARK: Porównania przed/po
    public func recordBenchmark(_ c: BenchmarkComparison, at: Date) {
        attempt("zapis porównania", ()) { try db.run("INSERT OR REPLACE INTO benchmarks(id, at, operation, verdict, payload) VALUES(?,?,?,?,?)",
                        [.text(c.id), .double(at.timeIntervalSince1970), .text(c.operation), .text(c.overall.rawValue),
                         .text(redact(String(decoding: try JSONEncoder.iso.encode(c), as: UTF8.self)))]) }
    }
    public func benchmarks(limit: Int = 20) -> [BenchmarkComparison] {
        attempt("odczyt porównań", []) { try db.query("SELECT payload FROM benchmarks ORDER BY at DESC LIMIT ?", [.int(Int64(limit))]) }
            .compactMap { $0["payload"]?.string.flatMap { try? JSONDecoder.iso.decode(BenchmarkComparison.self, from: Data($0.utf8)) } }   // try? świadomie: wiersz w nieznanym formacie (starsza wersja) jest pomijany
    }

    // MARK: Ustawienia
    public func setting(_ key: String) -> String? { attempt("odczyt ustawienia", []) { try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) }.first?["value"]?.string }
    public func setSetting(_ key: String, _ value: String?) {
        if let value { attempt("zapis ustawienia", ()) { try db.run("INSERT OR REPLACE INTO settings(key, value) VALUES(?,?)", [.text(key), .text(value)]) } }
        else { attempt("zapis ustawienia", ()) { try db.run("DELETE FROM settings WHERE key = ?", [.text(key)]) } }
    }
}
