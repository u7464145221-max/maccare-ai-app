import Foundation

/// Waga problemu. Kolejność ma znaczenie (porównywanie).
public enum Severity: Int, Codable, Comparable, CaseIterable, Sendable {
    case info = 0, warning = 1, critical = 2
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self { case .info: return String(localized: "Informacja"); case .warning: return String(localized: "Ostrzeżenie"); case .critical: return String(localized: "Krytyczne") }
    }
    public init(parsing s: String?) {
        switch s?.lowercased() { case "critical", "krytyczne": self = .critical; case "warning", "ostrzeżenie": self = .warning; default: self = .info }
    }
}

/// Klasyfikacja ryzyka operacji. Decyduje o wymaganym poziomie zatwierdzenia.
public enum RiskLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    /// Tylko odczyt – brak skutków ubocznych.
    case none = 0
    /// Odwracalne, dotyczy danych odtwarzalnych (np. cache przeniesiony do kwarantanny).
    case low = 1
    /// Odwracalne, ale może wpłynąć na pracę użytkownika (zamknięcie aplikacji, kosz).
    case medium = 2
    /// Trudno odwracalne lub dotyczy danych prywatnych / zabezpieczeń / chmury.
    case high = 3
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self { case .none: return String(localized: "Brak (odczyt)"); case .low: return String(localized: "Niskie"); case .medium: return String(localized: "Średnie"); case .high: return String(localized: "Wysokie") }
    }
}

/// Stopień pewności wniosku. Panel i asystent zawsze rozróżniają te kategorie.
public enum Certainty: String, Codable, Sendable, CaseIterable {
    /// Wynika bezpośrednio z deterministycznego pomiaru i reguły.
    case confirmed
    /// Prawdopodobna przyczyna – reguła widzi korelację, ale nie dowód.
    case probable
    /// Hipoteza modelu językowego – wymaga weryfikacji.
    case aiHypothesis
    public var label: String {
        switch self { case .confirmed: return String(localized: "Potwierdzone pomiarem"); case .probable: return String(localized: "Prawdopodobne"); case .aiHypothesis: return String(localized: "Hipoteza AI") }
    }
}

public enum ByteFormat {
    /// Format dziesiętny (jak Finder), np. „1,2 GB” (po angielsku „1.2 GB” – separator wg języka interfejsu; walidator ugruntowania przyjmuje oba).
    public static func string(_ bytes: UInt64, english: Bool = AppLanguage.isEnglish) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(bytes); var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(bytes) B" }
        let s = v >= 100 ? String(format: "%.0f", v) : (v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
        return (english ? s : s.replacingOccurrences(of: ".", with: ",")) + " " + units[i]
    }
    public static func string(_ bytes: Int64) -> String { bytes < 0 ? "-" + string(UInt64(-bytes)) : string(UInt64(bytes)) }
}

/// Źródło czasu – wstrzykiwane, aby testy były deterministyczne.
public protocol Clock: Sendable { var now: Date { get } }
public struct SystemClock: Clock { public init() {}; public var now: Date { Date() } }
public struct FixedClock: Clock { public var now: Date; public init(_ d: Date) { now = d } }

/// Uniwersalna wartość JSON – argumenty narzędzi AI i eksport raportów.
public enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    public static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
    public var jsonString: String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? "null"
    }
    public var description: String { jsonString }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral e: JSONValue...) { self = .array(e) }
    public init(dictionaryLiteral e: (String, JSONValue)...) { self = .object(Dictionary(e, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

/// Katalog danych aplikacji (konfigurowalny – testy używają katalogu tymczasowego).
public struct AppPaths: Sendable {
    public let support: URL
    public var database: URL { support.appendingPathComponent("maccare.sqlite") }
    public var quarantine: URL { support.appendingPathComponent("Quarantine", isDirectory: true) }
    public var reports: URL { support.appendingPathComponent("Reports", isDirectory: true) }
    public init(support: URL) {
        self.support = support
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    public static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(support: base.appendingPathComponent("MacCareAI", isDirectory: true))
    }
}
