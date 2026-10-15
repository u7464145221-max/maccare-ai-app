import Foundation

public enum ToolParamType: String, Codable, Sendable { case string, integer, number, boolean, stringArray }

public struct ToolParameter: Codable, Sendable {
    public var name: String
    public var type: ToolParamType
    public var description: String
    public var required: Bool
    public var allowedValues: [String]?
    public var maxLength: Int
    public var minimum: Double?
    public var maximum: Double?
    public var maxItems: Int
    public init(_ name: String, _ type: ToolParamType, _ description: String, required: Bool = true, allowedValues: [String]? = nil,
                maxLength: Int = 512, minimum: Double? = nil, maximum: Double? = nil, maxItems: Int = 200) {
        self.name = name; self.type = type; self.description = description; self.required = required; self.allowedValues = allowedValues
        self.maxLength = maxLength; self.minimum = minimum; self.maximum = maximum; self.maxItems = maxItems
    }
}

public enum ToolKind: String, Codable, Sendable { case read, action }

/// Kategorie wymagające OSOBNEGO zatwierdzenia (nie wystarczy zgoda na cały plan).
public enum SensitiveCategory: String, Codable, Sendable, CaseIterable {
    case destructive, securitySettings, privateData, cloud, mailServer
    public var label: String {
        switch self {
        case .destructive: return String(localized: "operacja nieodwracalna"); case .securitySettings: return String(localized: "zmiana ustawień zabezpieczeń")
        case .privateData: return String(localized: "dostęp do prywatnych danych"); case .cloud: return String(localized: "operacja w chmurze"); case .mailServer: return String(localized: "operacja na serwerze poczty")
        }
    }
}

public enum Permission: String, Codable, Sendable, CaseIterable {
    case none, fullDiskAccess, accessibility, automation, adminPassword, network, gmailOAuth, userSelectedFolder
    public var label: String {
        switch self {
        case .none: return String(localized: "brak"); case .fullDiskAccess: return String(localized: "Pełny dostęp do dysku (opcjonalnie)"); case .accessibility: return String(localized: "Dostępność")
        case .automation: return String(localized: "Automatyzacja"); case .adminPassword: return String(localized: "Hasło administratora (okno systemowe)"); case .network: return String(localized: "Sieć")
        case .gmailOAuth: return String(localized: "Autoryzacja Google OAuth"); case .userSelectedFolder: return String(localized: "Folder wskazany przez użytkownika")
        }
    }
}

/// Pełna specyfikacja narzędzia: opis, schemat, uprawnienia, ograniczenia, ryzyko.
public struct ToolSpec: Codable, Sendable {
    public var name: String
    public var description: String
    public var parameters: [ToolParameter]
    public var kind: ToolKind
    public var risk: RiskLevel
    public var sensitive: [SensitiveCategory]
    public var permissions: [Permission]
    public var limits: String
    public var reversible: Bool
    public init(name: String, description: String, parameters: [ToolParameter] = [], kind: ToolKind, risk: RiskLevel,
                sensitive: [SensitiveCategory] = [], permissions: [Permission] = [.none], limits: String, reversible: Bool) {
        self.name = name; self.description = description; self.parameters = parameters; self.kind = kind; self.risk = risk
        self.sensitive = sensitive; self.permissions = permissions; self.limits = limits; self.reversible = reversible
    }

    /// Schemat JSON (do promptu i do natywnego tool-calling).
    public var jsonSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for p in parameters {
            var o: [String: JSONValue] = ["description": .string(p.description)]
            switch p.type {
            case .string: o["type"] = "string"; o["maxLength"] = .number(Double(p.maxLength))
            case .integer: o["type"] = "integer"
            case .number: o["type"] = "number"
            case .boolean: o["type"] = "boolean"
            case .stringArray: o["type"] = "array"; o["items"] = ["type": "string"]; o["maxItems"] = .number(Double(p.maxItems))
            }
            if let a = p.allowedValues { o["enum"] = .array(a.map { .string($0) }) }
            if let m = p.minimum { o["minimum"] = .number(m) }
            if let m = p.maximum { o["maximum"] = .number(m) }
            props[p.name] = .object(o)
        }
        return ["type": "object", "properties": .object(props), "required": .array(parameters.filter { $0.required }.map { .string($0.name) }),
                "additionalProperties": false]
    }
}

public struct ToolCall: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: [String: JSONValue]
    public init(id: String = UUID().uuidString, name: String, arguments: [String: JSONValue] = [:]) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// Zwalidowane argumenty – dostęp wyłącznie przez typowane akcesory.
public struct ToolArguments: Sendable {
    public let raw: [String: JSONValue]
    public func string(_ k: String) -> String? { raw[k]?.stringValue }
    public func int(_ k: String) -> Int? { raw[k]?.numberValue.map { Int($0) } }
    public func double(_ k: String) -> Double? { raw[k]?.numberValue }
    public func bool(_ k: String) -> Bool? { raw[k]?.boolValue }
    public func strings(_ k: String) -> [String] { raw[k]?.arrayValue?.compactMap { $0.stringValue } ?? [] }
}

public enum ToolValidationError: Error, Equatable, LocalizedError, Sendable {
    case unknownTool(String), unknownArgument(String), missingArgument(String), wrongType(String, expected: ToolParamType)
    case notAllowed(String, String), tooLong(String), outOfRange(String), tooManyItems(String), controlCharacters(String)
    public var errorDescription: String? {
        switch self {
        case .unknownTool(let n): return String(localized: "Nieznane narzędzie: \(n)")
        case .unknownArgument(let a): return String(localized: "Nieznany argument: \(a)")
        case .missingArgument(let a): return String(localized: "Brak wymaganego argumentu: \(a)")
        case .wrongType(let a, let t): return String(localized: "Argument \(a) ma zły typ (oczekiwano \(t.rawValue))")
        case .notAllowed(let a, let v): return String(localized: "Wartość „\(v)” niedozwolona dla \(a)")
        case .tooLong(let a): return String(localized: "Argument \(a) jest za długi")
        case .outOfRange(let a): return String(localized: "Argument \(a) poza zakresem")
        case .tooManyItems(let a): return String(localized: "Za dużo elementów w \(a)")
        case .controlCharacters(let a): return String(localized: "Niedozwolone znaki sterujące w \(a)")
        }
    }
}

public enum ToolValidator {
    public static func validate(_ call: ToolCall, against spec: ToolSpec) -> Result<ToolArguments, ToolValidationError> {
        let known = Set(spec.parameters.map { $0.name })
        for k in call.arguments.keys where !known.contains(k) { return .failure(.unknownArgument(k)) }
        var clean: [String: JSONValue] = [:]
        for p in spec.parameters {
            guard let v = call.arguments[p.name], v != .null else {
                if p.required { return .failure(.missingArgument(p.name)) }
                continue
            }
            switch p.type {
            case .string:
                guard let s = v.stringValue else { return .failure(.wrongType(p.name, expected: p.type)) }
                if let e = checkString(s, p) { return .failure(e) }
            case .integer:
                guard let n = v.numberValue, n.rounded() == n else { return .failure(.wrongType(p.name, expected: p.type)) }
                if let e = checkRange(n, p) { return .failure(e) }
            case .number:
                guard let n = v.numberValue, n.isFinite else { return .failure(.wrongType(p.name, expected: p.type)) }
                if let e = checkRange(n, p) { return .failure(e) }
            case .boolean:
                guard v.boolValue != nil else { return .failure(.wrongType(p.name, expected: p.type)) }
            case .stringArray:
                guard let a = v.arrayValue else { return .failure(.wrongType(p.name, expected: p.type)) }
                if a.count > p.maxItems { return .failure(.tooManyItems(p.name)) }
                for item in a {
                    guard let s = item.stringValue else { return .failure(.wrongType(p.name, expected: p.type)) }
                    if let e = checkString(s, p) { return .failure(e) }
                }
            }
            clean[p.name] = v
        }
        return .success(ToolArguments(raw: clean))
    }

    private static func checkString(_ s: String, _ p: ToolParameter) -> ToolValidationError? {
        if s.count > p.maxLength { return .tooLong(p.name) }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" || $0.value == 0x7F }) { return .controlCharacters(p.name) }
        if let a = p.allowedValues, !a.contains(s) { return .notAllowed(p.name, String(s.prefix(40))) }
        return nil
    }
    private static func checkRange(_ n: Double, _ p: ToolParameter) -> ToolValidationError? {
        if let m = p.minimum, n < m { return .outOfRange(p.name) }
        if let m = p.maximum, n > m { return .outOfRange(p.name) }
        return nil
    }
}

/// Podgląd skutków (symulacja) – pokazywany przed zatwierdzeniem: cel, efekt, ryzyko, odwracalność.
public struct OperationPreview: Codable, Sendable {
    public var title: String
    public var purpose: String
    public var expectedEffect: String
    public var risk: RiskLevel
    public var reversible: Bool
    public var undoDescription: String
    public var affectedItems: [String]
    public var estimatedBytes: UInt64?
    public var warnings: [String]
    public init(title: String, purpose: String, expectedEffect: String, risk: RiskLevel, reversible: Bool, undoDescription: String,
                affectedItems: [String] = [], estimatedBytes: UInt64? = nil, warnings: [String] = []) {
        self.title = title; self.purpose = purpose; self.expectedEffect = expectedEffect; self.risk = risk; self.reversible = reversible
        self.undoDescription = undoDescription; self.affectedItems = affectedItems; self.estimatedBytes = estimatedBytes; self.warnings = warnings
    }
}

public struct ToolResult: Codable, Sendable {
    public var summary: String
    public var data: JSONValue
    public var evidence: [Evidence]
    public var success: Bool
    public init(summary: String, data: JSONValue = .null, evidence: [Evidence] = [], success: Bool = true) {
        self.summary = summary; self.data = data; self.evidence = evidence; self.success = success
    }
}

public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Operacja zmieniająca system, którą narzędzie wykonuje (`ExecutionGuard`). Narzędzia `.read` zwracają `nil`; narzędzie `.action` bez operacji jest traktowane
    /// jak `.unclassified` (wymaga zakresu `.full`, czyli w praktyce jest zablokowane) – test macierzy pilnuje, żeby żadne narzędzie `.action` nie zostało bez przypisania.
    var operation: MutatingOperation? { get }
    /// `true` = narzędzie wywołuje WYŁĄCZNIE użytkownik z interfejsu (np. zaznaczył pliki do Kosza): executor odrzuca wywołania modelu, harmonogramu i reguł,
    /// a model nie widzi go na liście narzędzi (`ToolRegistry.modelVisibleSpecs`).
    var userOnly: Bool { get }
    /// Symulacja – NIE może mieć skutków ubocznych.
    func preview(_ args: ToolArguments) async throws -> OperationPreview
    func run(_ args: ToolArguments) async throws -> ToolResult
}

extension AgentTool {
    public var operation: MutatingOperation? { nil }
    public var userOnly: Bool { false }
    public func preview(_ args: ToolArguments) async throws -> OperationPreview {
        OperationPreview(title: spec.name, purpose: spec.description, expectedEffect: spec.kind == .read ? String(localized: "Tylko odczyt danych diagnostycznych.") : spec.description,
                         risk: spec.risk, reversible: spec.reversible, undoDescription: spec.reversible ? String(localized: "Operację można cofnąć.") : String(localized: "Operacji nie można cofnąć."))
    }
}

public struct ToolRegistry: Sendable {
    public private(set) var tools: [String: any AgentTool] = [:]
    public init(_ tools: [any AgentTool] = []) { for t in tools { register(t) } }
    public mutating func register(_ t: any AgentTool) { tools[t.spec.name] = t }
    public func tool(_ name: String) -> (any AgentTool)? { tools[name] }
    public var specs: [ToolSpec] { tools.values.map { $0.spec }.sorted { $0.name < $1.name } }
    /// Narzędzia widoczne dla modelu AI: bez tych, które wywołuje wyłącznie użytkownik (`userOnly`).
    public var modelVisibleSpecs: [ToolSpec] { tools.values.filter { !$0.userOnly }.map { $0.spec }.sorted { $0.name < $1.name } }
}
