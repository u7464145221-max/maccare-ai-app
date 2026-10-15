import Foundation

public enum AgentMode: String, Codable, Sendable, CaseIterable {
    /// Wyłącznie analiza – żadnych akcji.
    case diagnostic
    /// Analiza i przygotowanie operacji do zatwierdzenia przez użytkownika.
    case assistant
    /// Wykonywanie wcześniej zatwierdzonych czynności niskiego ryzyka.
    case autoMaintenance
    public var label: String {
        switch self { case .diagnostic: return String(localized: "Diagnostyka"); case .assistant: return String(localized: "Asystent"); case .autoMaintenance: return String(localized: "Automatyczna konserwacja") }
    }
}

/// Kto zainicjował wywołanie – wpływa na decyzję (LLM nigdy nie dostaje więcej niż użytkownik).
public enum CallOrigin: String, Codable, Sendable { case user, llm, schedule, rule }

public enum PolicyDecision: Equatable, Sendable {
    case execute
    case requireApproval(String)
    case requireSeparateApproval([SensitiveCategory])
    case forbidden(String)
}

public struct ApprovalPolicy: Sendable {
    /// Narzędzia, które użytkownik zatwierdził do trybu automatycznego (tylko ryzyko ≤ niskie).
    public var autoApprovedTools: Set<String>
    public init(autoApprovedTools: Set<String> = []) { self.autoApprovedTools = autoApprovedTools }

    public func decide(_ spec: ToolSpec, mode: AgentMode, origin: CallOrigin) -> PolicyDecision {
        if spec.kind == .read && spec.sensitive.isEmpty { return .execute }
        if spec.kind == .read {   // odczyt danych prywatnych (np. poczta) – zawsze osobna zgoda
            return mode == .diagnostic && origin == .llm ? .forbidden(String(localized: "Tryb diagnostyki nie pozwala modelowi na dostęp do prywatnych danych"))
                                                         : .requireSeparateApproval(spec.sensitive)
        }
        switch mode {
        case .diagnostic:
            return .forbidden("Tryb diagnostyki – tylko analiza, bez wykonywania operacji")
        case .assistant:
            return spec.sensitive.isEmpty ? .requireApproval("Operacja wymaga zatwierdzenia") : .requireSeparateApproval(spec.sensitive)
        case .autoMaintenance:
            if !spec.sensitive.isEmpty { return .requireSeparateApproval(spec.sensitive) }
            if spec.risk <= .low && spec.reversible && autoApprovedTools.contains(spec.name) && origin != .llm { return .execute }
            if spec.risk <= .low && spec.reversible && autoApprovedTools.contains(spec.name) && origin == .llm {
                return .requireApproval(String(localized: "Model zaproponował operację – w trybie automatycznym wykonuję tylko zaplanowane czynności"))
            }
            return .requireApproval(String(localized: "Operacja spoza listy zatwierdzonych czynności automatycznych"))
        }
    }
}

/// Wpis dziennika audytu – każda próba wywołania narzędzia, niezależnie od wyniku.
public struct AuditRecord: Codable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case executed, failed, rejectedValidation, forbidden, pendingApproval, approved, declined }
    public var id: String
    public var callID: String
    public var tool: String
    public var argumentsJSON: String
    public var origin: CallOrigin
    public var mode: AgentMode
    public var outcome: Outcome
    public var message: String
    public var at: Date
    public init(id: String = UUID().uuidString, callID: String, tool: String, argumentsJSON: String, origin: CallOrigin, mode: AgentMode,
                outcome: Outcome, message: String, at: Date = Date()) {
        self.id = id; self.callID = callID; self.tool = tool; self.argumentsJSON = argumentsJSON; self.origin = origin
        self.mode = mode; self.outcome = outcome; self.message = message; self.at = at
    }
}

public protocol AuditSink: Sendable { func record(_ r: AuditRecord) }
public final class MemoryAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [AuditRecord] = []
    public init() {}
    public func record(_ r: AuditRecord) { lock.lock(); _records.append(r); lock.unlock() }
    public var records: [AuditRecord] { lock.lock(); defer { lock.unlock() }; return _records }
}

public struct PendingApproval: Sendable, Identifiable {
    public var id: String { call.id }
    public var call: ToolCall
    public var spec: ToolSpec
    public var preview: OperationPreview
    public var origin: CallOrigin
    public var separateCategories: [SensitiveCategory]
    public var createdAt: Date
}

public enum ExecutionOutcome: Sendable {
    case completed(ToolResult)
    case needsApproval(PendingApproval)
    case rejected(String)
    case failed(String)
    /// Tryb tylko do odczytu: operacja NIE została wykonana ani zakolejkowana; zwrócono jedynie symulację („co by się stało”).
    case previewOnly(OperationPreview, reason: String)
    public var isCompleted: Bool { if case .completed = self { return true }; return false }
    public var textForModel: String {
        switch self {
        case .completed(let r): return r.summary + (r.data == .null ? "" : "\nDANE: " + r.data.jsonString)
        case .needsApproval(let p): return String(localized: "Operacja „\(p.preview.title)” czeka na zatwierdzenie użytkownika. Nie zakładaj, że została wykonana.")
        case .rejected(let m): return "ODRZUCONO: \(m)"
        case .failed(let m): return String(localized: "BŁĄD: \(m)")
        case .previewOnly(let pv, let reason): return String(localized: "ODRZUCONO (\(reason)): „\(pv.title)” nie zostało wykonane – tylko podgląd. Nie zakładaj, że zostało wykonane.")
        }
    }
}

/// Kontrolowany executor: jedyne miejsce, w którym wywołania narzędzi zamieniają się w działania.
/// Walidacja → polityka → (symulacja + zatwierdzenie) → wykonanie → audyt.
public actor ToolExecutor {
    public nonisolated let registry: ToolRegistry
    public var policy: ApprovalPolicy
    public var mode: AgentMode
    private let audit: AuditSink
    private let clock: Clock
    private var pending: [String: PendingApproval] = [:]
    /// Limit wywołań modelu na jedną turę rozmowy (ochrona przed pętlą).
    public var maxLLMCallsPerTurn = 8
    private var llmCallsThisTurn = 0

    public init(registry: ToolRegistry, policy: ApprovalPolicy = .init(), mode: AgentMode = .assistant, audit: AuditSink, clock: Clock = SystemClock()) {
        self.registry = registry; self.policy = policy; self.mode = mode; self.audit = audit; self.clock = clock
    }

    public func setMode(_ m: AgentMode) { mode = m }
    public func setPolicy(_ p: ApprovalPolicy) { policy = p }
    public func beginTurn() { llmCallsThisTurn = 0 }
    public var pendingApprovals: [PendingApproval] { pending.values.sorted { $0.createdAt < $1.createdAt } }

    public func handle(_ call: ToolCall, origin: CallOrigin) async -> ExecutionOutcome {
        if origin == .llm {
            llmCallsThisTurn += 1
            if llmCallsThisTurn > maxLLMCallsPerTurn {
                log(call, origin, .forbidden, String(localized: "Przekroczono limit wywołań narzędzi w turze"))
                return .rejected(String(localized: "Przekroczono limit \(maxLLMCallsPerTurn) wywołań narzędzi w jednej odpowiedzi"))
            }
        }
        guard let tool = registry.tool(call.name) else {
            log(call, origin, .rejectedValidation, String(localized: "Nieznane narzędzie"))
            return .rejected(ToolValidationError.unknownTool(call.name).localizedDescription)
        }
        let args: ToolArguments
        switch ToolValidator.validate(call, against: tool.spec) {
        case .failure(let e): log(call, origin, .rejectedValidation, e.localizedDescription); return .rejected(e.localizedDescription)
        case .success(let a): args = a
        }
        // Narzędzia wskazywane ręcznie przez użytkownika (np. pliki zaznaczone do Kosza): model, harmonogram i reguły nie mogą ich wywołać.
        if tool.userOnly && origin != .user {
            log(call, origin, .forbidden, String(localized: "Narzędzie dostępne wyłącznie dla użytkownika z interfejsu: \(call.name)"))
            return .rejected(String(localized: "To narzędzie wywołuje wyłącznie użytkownik z interfejsu – zaznaczanie plików do Kosza nie jest dostępne dla asystenta ani automatów"))
        }
        // Tryb wykonania: każda operacja (`.action`) – niezależnie od trybu agenta, pochodzenia i polityki – wymaga, by `ExecutionGuard` dopuszczał JEJ operację
        // (odczyt: żadnej; Edycja w zakresie `.trashSelectedOnly`: tylko Kosz dla zaznaczonych). Inaczej kończy się podglądem z powodem odmowy.
        if tool.spec.kind == .action {
            let op = tool.operation ?? .unclassified
            if !ExecutionGuard.allows(op) {
                let why = ExecutionGuard.refusalMessage(for: op)
                log(call, origin, .forbidden, "\(why): \(call.name)")
                do { return .previewOnly(try await tool.preview(args), reason: why) }
                catch { return .rejected(why) }
            }
        }
        switch policy.decide(tool.spec, mode: mode, origin: origin) {
        case .forbidden(let why):
            log(call, origin, .forbidden, why); return .rejected(why)
        case .execute:
            return await execute(tool, call, args, origin)
        case .requireApproval, .requireSeparateApproval:
            let cats: [SensitiveCategory]
            if case .requireSeparateApproval(let c) = policy.decide(tool.spec, mode: mode, origin: origin) { cats = c } else { cats = [] }
            do {
                let pv = try await tool.preview(args)
                let p = PendingApproval(call: call, spec: tool.spec, preview: pv, origin: origin, separateCategories: cats, createdAt: clock.now)
                pending[call.id] = p
                log(call, origin, .pendingApproval, pv.title)
                return .needsApproval(p)
            } catch {
                log(call, origin, .failed, String(localized: "Symulacja nie powiodła się: \(error.localizedDescription)"))
                return .failed(String(localized: "Symulacja nie powiodła się: \(error.localizedDescription)"))
            }
        }
    }

    /// Zatwierdzenie przez użytkownika. Dla kategorii wrażliwych UI musi przekazać potwierdzenie każdej z nich.
    public func approve(_ id: String, confirmedCategories: Set<SensitiveCategory> = []) async -> ExecutionOutcome {
        if ExecutionGuard.isReadOnly {
            if let p = pending[id] { log(p.call, .user, .forbidden, "\(ExecutionGuard.message) (zatwierdzenie odrzucone)") }
            return .rejected(ExecutionGuard.message)
        }
        // Edycja mogła zostać zawężona/wygasnąć między podglądem a zatwierdzeniem – operacja musi być dopuszczona TERAZ.
        if let p = pending[id], let tool = registry.tool(p.call.name), tool.spec.kind == .action, !ExecutionGuard.allows(tool.operation ?? .unclassified) {
            let why = ExecutionGuard.refusalMessage(for: tool.operation ?? .unclassified)
            log(p.call, .user, .forbidden, "\(why) (zatwierdzenie odrzucone)")
            return .rejected(why)
        }
        guard let p = pending[id] else { return .rejected(String(localized: "Brak oczekującej operacji o tym identyfikatorze")) }
        guard Set(p.separateCategories).isSubset(of: confirmedCategories) else {
            return .rejected("Wymagane osobne potwierdzenie: " + p.separateCategories.map { $0.label }.joined(separator: ", "))
        }
        pending[id] = nil
        guard let tool = registry.tool(p.call.name), case .success(let args) = ToolValidator.validate(p.call, against: tool.spec) else {
            return .rejected(String(localized: "Operacja nie jest już dostępna"))
        }
        if mode == .diagnostic { log(p.call, p.origin, .forbidden, String(localized: "Tryb zmieniono na diagnostykę")); return .rejected(String(localized: "Tryb diagnostyki – operacje wyłączone")) }
        log(p.call, .user, .approved, p.preview.title)
        return await execute(tool, p.call, args, p.origin)
    }

    public func decline(_ id: String) {
        if let p = pending.removeValue(forKey: id) { log(p.call, .user, .declined, p.preview.title) }
    }

    private func execute(_ tool: any AgentTool, _ call: ToolCall, _ args: ToolArguments, _ origin: CallOrigin) async -> ExecutionOutcome {
        do {
            let r = try await tool.run(args)
            log(call, origin, r.success ? .executed : .failed, r.summary)
            return .completed(r)
        } catch {
            log(call, origin, .failed, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    private func log(_ c: ToolCall, _ o: CallOrigin, _ out: AuditRecord.Outcome, _ msg: String) {
        audit.record(AuditRecord(id: UUID().uuidString, callID: c.id, tool: c.name, argumentsJSON: JSONValue.object(c.arguments).jsonString,
                                 origin: o, mode: mode, outcome: out, message: msg, at: clock.now))
    }
}
