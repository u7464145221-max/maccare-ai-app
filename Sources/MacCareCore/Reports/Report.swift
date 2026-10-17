import Foundation

/// Zakres ujawnianych danych w eksporcie.
public enum DisclosureLevel: String, Codable, Sendable, CaseIterable {
    /// Tylko liczby i nazwy kategorii; bez ścieżek, nazw aplikacji, nazwy użytkownika/komputera.
    case minimal
    /// Nazwy aplikacji i reguł; ścieżki zanonimizowane (~ zamiast katalogu domowego, <user>, <host>).
    case standard
    /// Pełne dane – tylko do własnego użytku.
    case full
    public var label: String { switch self { case .minimal: return String(localized: "Minimalny"); case .standard: return String(localized: "Standardowy (zanonimizowany)"); case .full: return String(localized: "Pełny") } }
}

public struct Redactor: Sendable {
    public var level: DisclosureLevel
    public var home: String
    public var userName: String
    public var hostName: String
    public init(level: DisclosureLevel, home: String = PathTools.home, userName: String = NSUserName(), hostName: String = ProcessInfo.processInfo.hostName) {
        self.level = level; self.home = home; self.userName = userName; self.hostName = hostName
    }
    public func text(_ s: String) -> String {
        guard level != .full else { return s }
        var t = s
        // e-maile najpierw (zanim nazwa użytkownika zostanie podmieniona wewnątrz adresu)
        if let re = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") {   // try? świadomie: stały wzorzec – błąd niemożliwy
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "<email>")
        }
        t = t.replacingOccurrences(of: home, with: "~")
        if userName.count >= 2 { t = t.replacingOccurrences(of: userName, with: "<user>") }
        if hostName.count >= 2 { t = t.replacingOccurrences(of: hostName, with: "<host>") }
        if level == .minimal, let re = try? NSRegularExpression(pattern: "(~|/)[^\\s,;\\]\\)]+") {   // try? świadomie: stały wzorzec – błąd niemożliwy
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "<ścieżka>")
        }
        return t
    }
}

/// Raport diagnostyczny do eksportu (JSON; PDF renderuje warstwa macOS z tej samej struktury).
public struct DiagnosticReport: Codable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var methodologyVersion: String
    public var disclosure: DisclosureLevel
    public var synthetic: Bool
    public var osVersion: String
    public var health: HealthAssessment?
    public var evidence: [Evidence]
    public var findings: [Finding]
    public var cleanupSummary: [String: UInt64]
    public var benchmarks: [String]
    public var operations: [String]

    public static func build(snapshot: SystemSnapshot, findings: [Finding], cleanup: CleanupScanResult?, benchmarks: [BenchmarkComparison],
                             operations: [AuditRecord], redactor: Redactor, appVersion: String, now: Date = Date()) -> DiagnosticReport {
        let r = redactor
        let ev = snapshot.evidence().filter { redactor.level != .minimal || !$0.id.hasPrefix("proc.") && !$0.id.hasPrefix("startup.item.") && !$0.id.hasPrefix("crash.") }
            .map { e -> Evidence in var x = e; x.label = r.text(e.label); x.value = r.text(e.value); x.id = r.level == .minimal ? e.id.components(separatedBy: ".").prefix(2).joined(separator: ".") : r.text(e.id); return x }
        let fs = findings.map { f -> Finding in
            var x = f; x.title = r.text(f.title); x.detail = r.text(f.detail)
            if r.level == .minimal { x.actions = []; x.evidenceIDs = [] }
            return x
        }
        var cs: [String: UInt64] = [:]
        for (c, items) in cleanup?.byCategory() ?? [] { cs[c.rawValue] = items.reduce(0) { $0 + $1.reclaimableSize } }
        return DiagnosticReport(generatedAt: now, appVersion: appVersion, methodologyVersion: HealthAssessment.methodologyVersion, disclosure: r.level,
                                synthetic: snapshot.synthetic, osVersion: snapshot.osVersion, health: HealthAssessment.assess(snapshot), evidence: ev, findings: fs,
                                cleanupSummary: cs, benchmarks: benchmarks.map { r.text($0.summary) },
                                operations: r.level == .minimal ? [] : operations.prefix(100).map { "\($0.at.formatted(date: .numeric, time: .shortened)) \($0.tool) → \($0.outcome.rawValue): \(r.text($0.message))" })
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder.iso; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(self)
    }

    /// Prosty HTML (do podglądu i konwersji na PDF przez WebKit na macOS).
    public func html() -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        // F12: raport w języku interfejsu – teksty jako osobne klucze (bez znaczników HTML w kluczach), `lang` dokumentu wg `AppLanguage`.
        var h = "<!doctype html><html lang=\(AppLanguage.code)><meta charset=utf-8><title>\(esc(String(localized: "Raport MacCare AI")))</title><style>body{font:13px -apple-system,Helvetica;margin:32px;color:#1d1d1f}h1{font-size:22px}h2{font-size:15px;margin-top:24px;border-bottom:1px solid #ddd}td,th{padding:4px 8px;text-align:left;border-bottom:1px solid #eee}table{border-collapse:collapse;width:100%}.s{color:#b00}</style>"
        let scope = String(localized: "zakres: \(disclosure.label)"), method = String(localized: "metodologia \(methodologyVersion)")
        h += "<h1>\(esc(String(localized: "Raport diagnostyczny MacCare AI")))</h1><p>\(esc(generatedAt.formatted(date: .long, time: .shortened))) · macOS \(esc(osVersion)) · \(esc(scope)) · \(esc(method))</p>"
        if synthetic { h += "<p class=s><b>\(esc(String(localized: "DANE TESTOWE – raport nie dotyczy rzeczywistego komputera.")))</b></p>" }
        if let hh = health {
            let overall = hh.overall.map { "\($0)/100" } ?? String(localized: "brak (za mało danych)")
            let coverage = String(localized: "pokrycie danymi \(Int(hh.coverage * 100))%")
            h += "<h2>\(esc(String(localized: "Ocena stanu")))</h2><p>\(esc(String(localized: "Wynik ogólny:"))) <b>\(esc(overall))</b>, \(esc(coverage))</p>"
            h += "<table><tr><th>\(esc(String(localized: "Komponent")))</th><th>\(esc(String(localized: "Wynik")))</th><th>\(esc(String(localized: "Powody")))</th></tr>"
            for c in hh.components { h += "<tr><td>\(esc(c.title))</td><td>\(c.score.map(String.init) ?? esc(c.note ?? String(localized: "brak danych")))</td><td>\(esc(c.deductions.map { "−\($0.points): \($0.reason)" }.joined(separator: "; ")))</td></tr>" }
            h += "</table>"
        }
        h += "<h2>\(esc(String(localized: "Wykryte problemy")))</h2><table><tr><th>\(esc(String(localized: "Waga")))</th><th>\(esc(String(localized: "Pewność")))</th><th>\(esc(String(localized: "Problem")))</th></tr>"
        for f in findings { h += "<tr><td>\(f.severity.label)</td><td>\(f.certainty.label)</td><td><b>\(esc(f.title))</b><br>\(esc(f.detail))</td></tr>" }
        if findings.isEmpty { h += "<tr><td colspan=3>\(esc(String(localized: "Brak")))</td></tr>" }
        h += "</table><h2>\(esc(String(localized: "Pomiary")))</h2><table>"
        for e in evidence { h += "<tr><td>\(esc(e.label))</td><td>\(esc(e.value))</td><td><small>\(esc(e.source))</small></td></tr>" }
        h += "</table>"
        if !benchmarks.isEmpty { h += "<h2>\(esc(String(localized: "Przed i po")))</h2>" + benchmarks.map { "<pre>\(esc($0))</pre>" }.joined() }
        if !operations.isEmpty { h += "<h2>\(esc(String(localized: "Operacje")))</h2><ul>" + operations.map { "<li>\(esc($0))</li>" }.joined() + "</ul>" }
        return h + "</html>"
    }
}
