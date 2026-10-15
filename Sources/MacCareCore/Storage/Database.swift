import Foundation
import CSQLite

public struct DatabaseError: Error, LocalizedError { public var message: String; public var errorDescription: String? { "SQLite: \(message)" } }

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimalna, bezpieczna nakładka na SQLite (parametryzowane zapytania, WAL, synchronizacja przez kolejkę).
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "maccare.sqlite")

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
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "?"; sqlite3_free(err); throw DatabaseError(message: m)
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        try queue.sync {
            let st = try prepare(sql, params); defer { sqlite3_finalize(st) }
            let rc = sqlite3_step(st)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        try queue.sync {
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
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
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
    public static let schemaVersion = 1

    /// Katalog domowy zastępowany „~” w zapisach dziennika operacji (P3-6 / AUD-PRIV-1): w bazie nie ma nazwy konta. nil = bez redakcji.
    public let redactedHome: String?

    public init(path: String, redactingHome home: String? = nil) throws {
        db = try SQLiteDatabase(path: path)
        redactedHome = home.flatMap { $0.count > 1 ? $0 : nil }
        try migrate()
    }

    /// `/Users/jan/x` ⇒ `~/x` (także w postaci z ukośnikami poprzedzonymi „\” z JSON-a).
    func redact(_ s: String) -> String {
        guard let h = redactedHome else { return s }
        return s.replacingOccurrences(of: h, with: "~").replacingOccurrences(of: h.replacingOccurrences(of: "/", with: "\\/"), with: "~")
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
        CREATE TABLE IF NOT EXISTS samples(at REAL NOT NULL, metric TEXT NOT NULL, value REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS samples_metric_at ON samples(metric, at);
        CREATE TABLE IF NOT EXISTS findings_log(at REAL NOT NULL, finding_id TEXT NOT NULL, severity INTEGER, certainty TEXT, title TEXT);
        CREATE TABLE IF NOT EXISTS benchmarks(id TEXT PRIMARY KEY, at REAL NOT NULL, operation TEXT, verdict TEXT, payload TEXT);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
        """)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)", [.text(String(Self.schemaVersion))])
    }

    // MARK: Audyt
    public func record(_ r: AuditRecord) {
        _ = try? db.run("INSERT OR REPLACE INTO operations(id, call_id, at, tool, origin, mode, outcome, args, message) VALUES(?,?,?,?,?,?,?,?,?)",
                        [.text(r.id), .text(r.callID), .double(r.at.timeIntervalSince1970), .text(r.tool), .text(r.origin.rawValue),
                         .text(r.mode.rawValue), .text(r.outcome.rawValue), .text(redact(r.argumentsJSON)), .text(redact(r.message))])
    }

    public func operations(limit: Int = 200) -> [AuditRecord] {
        ((try? db.query("SELECT * FROM operations ORDER BY at DESC LIMIT ?", [.int(Int64(limit))])) ?? []).compactMap { r in
            guard let id = r["id"]?.string, let tool = r["tool"]?.string, let at = r["at"]?.double else { return nil }
            return AuditRecord(id: id, callID: r["call_id"]?.string ?? "", tool: tool, argumentsJSON: r["args"]?.string ?? "{}",
                               origin: CallOrigin(rawValue: r["origin"]?.string ?? "") ?? .user, mode: AgentMode(rawValue: r["mode"]?.string ?? "") ?? .assistant,
                               outcome: AuditRecord.Outcome(rawValue: r["outcome"]?.string ?? "") ?? .failed, message: r["message"]?.string ?? "",
                               at: Date(timeIntervalSince1970: at))
        }
    }

    // MARK: Skany i ustalenia
    public func recordScan(kind: String, at: Date, findings: [Finding], reclaimable: UInt64, health: Int?) {
        try? db.transaction {
            try db.run("INSERT INTO scans(at, kind, findings, reclaimable, health, payload) VALUES(?,?,?,?,?,?)",
                       [.double(at.timeIntervalSince1970), .text(kind), .int(Int64(findings.count)), .int(Int64(reclaimable)),
                        health.map { .int(Int64($0)) } ?? .null, .text(String(decoding: (try? JSONEncoder.iso.encode(findings)) ?? Data(), as: UTF8.self))])
            for f in findings {
                try db.run("INSERT INTO findings_log(at, finding_id, severity, certainty, title) VALUES(?,?,?,?,?)",
                           [.double(at.timeIntervalSince1970), .text(f.id), .int(Int64(f.severity.rawValue)), .text(f.certainty.rawValue), .text(f.title)])
            }
        }
    }

    public struct ScanRow: Sendable, Identifiable { public var id: Int64; public var at: Date; public var kind: String; public var findings: Int; public var reclaimable: UInt64; public var health: Int? }
    public func scans(since: Date? = nil, limit: Int = 500) -> [ScanRow] {
        ((try? db.query("SELECT id, at, kind, findings, reclaimable, health FROM scans WHERE at >= ? ORDER BY at DESC LIMIT ?",
                        [.double((since ?? .distantPast).timeIntervalSince1970), .int(Int64(limit))])) ?? []).compactMap { r in
            guard let id = r["id"]?.int, let at = r["at"]?.double else { return nil }
            return ScanRow(id: id, at: Date(timeIntervalSince1970: at), kind: r["kind"]?.string ?? "", findings: Int(r["findings"]?.int ?? 0),
                           reclaimable: UInt64(max(0, r["reclaimable"]?.int ?? 0)), health: r["health"]?.int.map { Int($0) })
        }
    }

    // MARK: Odzyskane miejsce (zmierzone, nie deklarowane)
    public func recordReclaimed(operation: String, estimated: UInt64, measured: Int64?, note: String, at: Date) {
        _ = try? db.run("INSERT INTO reclaimed(at, operation, estimated, measured, note) VALUES(?,?,?,?,?)",
                        [.double(at.timeIntervalSince1970), .text(operation), .int(Int64(estimated)), measured.map { .int($0) } ?? .null, .text(note)])
    }
    public func totalReclaimedMeasured(since: Date = .distantPast) -> Int64 {
        (try? db.query("SELECT COALESCE(SUM(measured),0) AS s FROM reclaimed WHERE at >= ? AND measured > 0", [.double(since.timeIntervalSince1970)]))?.first?["s"]?.int ?? 0
    }

    // MARK: Szeregi czasowe
    public func recordSamples(_ values: [String: Double], at: Date) {
        try? db.transaction { for (k, v) in values { try db.run("INSERT INTO samples(at, metric, value) VALUES(?,?,?)", [.double(at.timeIntervalSince1970), .text(k), .double(v)]) } }
    }
    public func series(_ metric: String, since: Date) -> [(Date, Double)] {
        ((try? db.query("SELECT at, value FROM samples WHERE metric = ? AND at >= ? ORDER BY at", [.text(metric), .double(since.timeIntervalSince1970)])) ?? [])
            .compactMap { r in guard let a = r["at"]?.double, let v = r["value"]?.double else { return nil }; return (Date(timeIntervalSince1970: a), v) }
    }
    /// Retencja: próbki starsze niż N dni są agregowane (średnia godzinowa) – kontrola rozmiaru bazy.
    public func compactSamples(olderThan days: Double = 7, now: Date = Date()) {
        let cutoff = now.timeIntervalSince1970 - days * 86400
        try? db.transaction {
            try db.run("""
            INSERT INTO samples(at, metric, value)
            SELECT CAST(at/3600 AS INTEGER)*3600 + 1800 AS hour, metric, AVG(value) FROM samples
            WHERE at < ? AND (at - CAST(at/3600 AS INTEGER)*3600) <> 1800 GROUP BY hour, metric
            """, [.double(cutoff)])
            try db.run("DELETE FROM samples WHERE at < ? AND (at - CAST(at/3600 AS INTEGER)*3600) <> 1800", [.double(cutoff)])
        }
    }

    // MARK: Porównania przed/po
    public func recordBenchmark(_ c: BenchmarkComparison, at: Date) {
        _ = try? db.run("INSERT OR REPLACE INTO benchmarks(id, at, operation, verdict, payload) VALUES(?,?,?,?,?)",
                        [.text(c.id), .double(at.timeIntervalSince1970), .text(c.operation), .text(c.overall.rawValue),
                         .text(String(decoding: (try? JSONEncoder.iso.encode(c)) ?? Data(), as: UTF8.self))])
    }
    public func benchmarks(limit: Int = 20) -> [BenchmarkComparison] {
        ((try? db.query("SELECT payload FROM benchmarks ORDER BY at DESC LIMIT ?", [.int(Int64(limit))])) ?? [])
            .compactMap { $0["payload"]?.string.flatMap { try? JSONDecoder.iso.decode(BenchmarkComparison.self, from: Data($0.utf8)) } }
    }

    // MARK: Ustawienia
    public func setting(_ key: String) -> String? { (try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]))?.first?["value"]?.string }
    public func setSetting(_ key: String, _ value: String?) {
        if let value { _ = try? db.run("INSERT OR REPLACE INTO settings(key, value) VALUES(?,?)", [.text(key), .text(value)]) }
        else { _ = try? db.run("DELETE FROM settings WHERE key = ?", [.text(key)]) }
    }
}
