#if os(macOS)
import Foundation
import MacCareCore

/// Raporty awarii z `~/Library/Logs/DiagnosticReports`. Format `.ips`: pierwsza linia = nagłówek JSON
/// (`app_name`, `bug_type`, `timestamp`…), reszta = JSON z `exception`, `termination`, `threads`, `usedImages`.
public struct CrashReportCollector: Sendable {
    let directory: String
    let home: String

    public init(directory: String = NSHomeDirectory() + "/Library/Logs/DiagnosticReports", home: String = NSHomeDirectory()) {
        self.directory = directory; self.home = home
    }

    struct Header { var app: String; var name: String?; var bugType: String?; var date: Date?; var version: String? }

    private static let maxFileBytes = 8_000_000

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSS Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func parseHeader(firstLine: Data) -> Header? {
        guard let o = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
              let app = (o["app_name"] as? String) ?? (o["name"] as? String) else { return nil }
        return Header(app: app, name: o["name"] as? String, bugType: o["bug_type"] as? String,
                      date: (o["timestamp"] as? String).flatMap(parseDate), version: o["app_version"] as? String)
    }

    /// Typ zdarzenia. Zweryfikowano na prawdziwych danych tylko `crash` (bug_type 309, klucz `exception`);
    /// pozostałe wynikają z nazwy pliku (starsze formaty .hang/.spin/.diag) – nieznane ⇒ "other".
    static func kind(fileName: String, body: [String: Any]?, bugType: String?) -> String {
        let n = fileName.lowercased()
        if n.hasSuffix(".hang") || n.hasSuffix(".spin") || n.contains("_hang") { return "hang" }
        if n.contains("cpu_resource") { return "cpu_resource" }
        if n.contains("wakeups_resource") { return "wakeups" }
        if n.contains("jetsam") { return "jetsam" }
        if let b = body, b["exception"] != nil { return "crash" }
        if bugType == "309" || bugType == "109" { return "crash" }
        return "other"
    }

    private struct Entry { var file: String; var header: Header; var date: Date; var kind: String }

    private func entries(since: Date) -> [Entry] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory)) ?? []           // try? świadomie: nieczytelność zgłasza `directoryUnreadable()` (migawka: nieznane)
        var out: [Entry] = []
        for f in files where [".ips", ".diag", ".hang", ".spin", ".crash"].contains(where: { f.hasSuffix($0) }) {
            let path = directory + "/" + f
            guard let attrs = try? fm.attributesOfItem(atPath: path), let mtime = attrs[.modificationDate] as? Date else { continue }   // try? świadomie: brak wartości ⇒ nieznane
            var header: Header?
            if f.hasSuffix(".ips"), let h = FileHandle(forReadingAtPath: path) {
                defer { try? h.close() }   // try? świadomie: zamknięcie uchwytu tylko do odczytu
                let chunk = (try? h.read(upToCount: 8192)) ?? Data()   // try? świadomie: nieudany odczyt ⇒ brak danych
                if let nl = chunk.firstIndex(of: 0x0A) { header = Self.parseHeader(firstLine: chunk[..<nl]) }
            }
            let h = header ?? Header(app: Self.processName(fromFile: f), name: nil, bugType: nil, date: nil, version: nil)
            let date = h.date ?? mtime
            guard date >= since else { continue }
            out.append(Entry(file: f, header: h, date: date, kind: Self.kind(fileName: f, body: nil, bugType: h.bugType)))
        }
        return out
    }

    static func processName(fromFile f: String) -> String {
        var base = (f as NSString).deletingPathExtension
        if let r = base.range(of: "-20\\d\\d-\\d\\d-\\d\\d", options: .regularExpression) { base = String(base[..<r.lowerBound]) }
        if let u = base.firstIndex(of: "_") { base = String(base[..<u]) }
        return base
    }

    /// Audyt 16.10 (`try?`): katalog istnieje, ale nie da się go odczytać ⇒ wynik NIEZNANY (nil w migawce), a nie „0 awarii”. Brak katalogu = brak raportów.
    public func directoryUnreadable() -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory)) == nil   // try? świadomie: tu właśnie sprawdzamy, czy odczyt się udaje
    }

    /// Grupowanie z ostatnich `days` dni.
    public func summaries(days: Int = 14, now: Date = Date()) -> [CrashReportSummary] {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        var map: [String: (count: Int, last: Date, kinds: Set<String>)] = [:]
        for e in entries(since: since) {
            var v = map[e.header.app] ?? (0, .distantPast, [])
            v.count += 1; v.last = max(v.last, e.date); v.kinds.insert(e.kind)
            map[e.header.app] = v
        }
        return map.map { CrashReportSummary(process: $0.key, count: $0.value.count, lastDate: $0.value.last, kinds: $0.value.kinds.sorted()) }
            .sorted { $0.lastDate > $1.lastDate }
    }

    /// Streszczenie najnowszego raportu procesu: wyjątek, zakończenie, 5 górnych ramek wątku, który się wysypał (≤ 1500 znaków).
    public func crashSummary(process: String, now: Date = Date()) -> String? {
        let want = process.lowercased()
        let candidates = entries(since: now.addingTimeInterval(-90 * 86400)).filter {
            $0.header.app.lowercased() == want || $0.header.name?.lowercased() == want
        }.sorted { $0.date > $1.date }
        guard let e = candidates.first else { return nil }
        let path = directory + "/" + e.file
        guard e.file.hasSuffix(".ips"),
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= Self.maxFileBytes,   // try? świadomie: brak wartości ⇒ nieznane
              let data = FileManager.default.contents(atPath: path), let nl = data.firstIndex(of: 0x0A),
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...]) as? [String: Any] else {   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
            return Self.truncate(String(localized: "Raport \(e.kind) procesu \(e.header.app) z \(e.date.formatted(date: .abbreviated, time: .shortened)) (bez szczegółów – nieobsługiwany format)."))
        }
        return Self.truncate(Self.describe(header: e.header, date: e.date, body: body).replacingOccurrences(of: home, with: "~"))
    }

    static func describe(header: Header, date: Date, body: [String: Any]) -> String {
        var lines: [String] = []
        lines.append(String(localized: "Awaria: \(header.app)\(header.version.map { " \($0)" } ?? "") z \(date.formatted(date: .abbreviated, time: .shortened))"))
        if let ex = body["exception"] as? [String: Any] {
            let t = ex["type"] as? String ?? "?"
            let sig = ex["signal"] as? String
            let sub = ex["subtype"] as? String
            lines.append(String(localized: "Wyjątek: \(t)\(sig.map { " (\($0))" } ?? "")\(sub.map { ", \($0)" } ?? "")"))
        }
        if let term = body["termination"] as? [String: Any] {
            let ind = term["indicator"] as? String ?? ""
            let ns = term["namespace"] as? String ?? ""
            let code = (term["code"] as? NSNumber)?.stringValue ?? ""
            lines.append(String(localized: "Zakończenie: \(ind) [\(ns) \(code)]").trimmingCharacters(in: .whitespaces))
        }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? NSNumber)?.intValue
        let crashed = threads.first { ($0["triggered"] as? Bool) == true } ?? faulting.flatMap { $0 < threads.count ? threads[$0] : nil }
        if let t = crashed, let frames = t["frames"] as? [[String: Any]] {
            lines.append(String(localized: "Wątek \(faulting.map(String.init) ?? "?"), górne ramki:"))
            for (i, f) in frames.prefix(5).enumerated() {
                let sym = (f["symbol"] as? String) ?? "?"
                let idx = (f["imageIndex"] as? NSNumber)?.intValue
                let image = idx.flatMap { $0 < images.count ? (images[$0]["name"] as? String) : nil } ?? "?"
                lines.append("  \(i). \(sym) (\(image))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ s: String, max: Int = 1500) -> String { s.count <= max ? s : String(s.prefix(max - 1)) + "…" }
}
#endif
