import Foundation
import MacCareCore

/// Twierdzenie w odpowiedzi asystenta – zawsze z dowodami i poziomem pewności.
public struct AssistantClaim: Codable, Sendable, Equatable {
    public var text: String
    public var evidence: [String]
    public var certainty: Certainty
    /// Ustawiane przez walidator, gdy model podał nieistniejące dowody lub zawyżył pewność.
    public var groundingNote: String?
}

public struct ProposedOperation: Codable, Sendable {
    public var tool: String
    public var arguments: [String: JSONValue]
    public var reason: String
}

public struct AssistantAnswer: Sendable {
    public var summary: String
    public var claims: [AssistantClaim]
    public var missingData: [String]
    public var proposed: [ProposedOperation]
    public var pendingApprovals: [PendingApproval]
    /// Tryb tylko do odczytu: symulacje zaproponowanych operacji (nic nie jest zakolejkowane ani wykonane).
    public var previewOnly: [OperationPreview] = []
    public var rejectedProposals: [String]
    public var steps: [String]                 // przebieg: wywołane narzędzia i ich wynik (skrót)
    public var evidenceUsed: [Evidence]
    public var providerName: String
    /// true, gdy model nie odpowiedział poprawnie i odpowiedź zbudowano z reguł.
    public var fallback: Bool
}

/// Protokół wymiany z modelem (działa z każdym dostawcą, także bez natywnego tool-calling).
enum AgentProtocol {
    /// Język odpowiedzi modelu = język interfejsu (`AppLanguage`). Obie wersje mają TE SAME zasady (test `SystemPromptLanguageTests` pilnuje zgodności).
    /// Prompt nie trafia do Localizable.strings (wielowierszowy) – wersje są tu jawnie, żeby zasady bezpieczeństwa nie zależały od pliku tłumaczeń.
    static func systemPrompt(tools: [ToolSpec], mode: AgentMode, english: Bool = AppLanguage.isEnglish) -> String {
        let toolList = tools.map { t in
            let params = t.parameters.map { "\($0.name): \($0.type.rawValue)\($0.required ? "" : "?")\($0.allowedValues.map { " ∈ {\($0.joined(separator: ","))}" } ?? "")" }.joined(separator: ", ")
            let kind = english ? (t.kind == .read ? "read" : "operation, risk: \(t.risk.label)") : (t.kind == .read ? "odczyt" : "operacja, ryzyko: \(t.risk.label)")
            return "- \(t.name)(\(params)) [\(kind)]: \(t.description)"
        }.joined(separator: "\n")
        if english {
            return """
            You are the MacCare AI diagnostic assistant running locally on a Mac. You answer in English, concisely.
            RULES (absolute):
            1. You base conclusions ONLY on tool results. Every claim lists evidence identifiers from the results in square brackets, e.g. "mem.pressure".
            2. You distinguish: "confirmed" (follows directly from a measurement), "probable" (correlation), "hypothesis" (a guess). Never present guesses as facts.
            3. When data is missing – say so in missing_data and do NOT guess. Missing data is a valid answer.
            4. You have no shell access. You may use only the tools on the list. You only propose operations – the user runs them after approving.
            5. Never propose deleting system files, disabling SIP/Gatekeeper or quitting system processes.
            6. Freeing RAM by itself is NOT a speed-up – do not promise effects you cannot measure.
            Working mode: \(mode.label)\(mode == .diagnostic ? " – do NOT propose any operations." : "").

            TOOLS:
            \(toolList)

            FORMAT: every reply is ONE JSON object, with no text around it:
            a) tool call: {"type":"tool_call","tool":"<name>","arguments":{...}}
            b) final answer: {"type":"final","summary":"<2–4 sentences>","claims":[{"text":"...","evidence":["id"],"certainty":"confirmed|probable|hypothesis"}],"missing_data":["..."],"proposed_actions":[{"tool":"<operation name>","arguments":{...},"reason":"..."}]}
            Collect data with tools first, then answer. At most 5 tool calls. Copy numbers in claims exactly from the results (with units).
            """
        }
        return """
        Jesteś asystentem diagnostycznym MacCare AI działającym lokalnie na Macu. Odpowiadasz po polsku, zwięźle.
        ZASADY (bezwzględne):
        1. Opierasz wnioski WYŁĄCZNIE na wynikach narzędzi. Każde twierdzenie podaje identyfikatory dowodów w nawiasach kwadratowych z wyników, np. "mem.pressure".
        2. Rozróżniasz: "confirmed" (wynika wprost z pomiaru), "probable" (korelacja), "hypothesis" (przypuszczenie). Nie podawaj przypuszczeń jako faktów.
        3. Gdy brakuje danych – napisz to w missing_data i NIE zgaduj. Brak danych to poprawna odpowiedź.
        4. Nie masz dostępu do powłoki. Możesz używać tylko narzędzi z listy. Operacje tylko proponujesz – wykona je użytkownik po zatwierdzeniu.
        5. Nie proponuj usuwania plików systemowych, wyłączania SIP/Gatekeepera ani zamykania procesów systemowych.
        6. Zwolnienie RAM samo w sobie NIE jest przyspieszeniem – nie obiecuj efektów, których nie zmierzysz.
        Tryb pracy: \(mode.label)\(mode == .diagnostic ? " – NIE proponuj żadnych operacji." : "").

        NARZĘDZIA:
        \(toolList)

        FORMAT: każda Twoja odpowiedź to JEDEN obiekt JSON, bez tekstu wokół:
        a) wywołanie narzędzia: {"type":"tool_call","tool":"<nazwa>","arguments":{...}}
        b) odpowiedź końcowa: {"type":"final","summary":"<2–4 zdania>","claims":[{"text":"...","evidence":["id"],"certainty":"confirmed|probable|hypothesis"}],"missing_data":["..."],"proposed_actions":[{"tool":"<nazwa operacji>","arguments":{...},"reason":"..."}]}
        Najpierw zbierz dane narzędziami, potem odpowiedz. Maksymalnie 5 wywołań narzędzi. Liczby w twierdzeniach przepisuj dokładnie z wyników (z jednostką).
        """
    }

    enum Step { case toolCall(ToolCall), final(JSONValue) }

    /// Wyciąga pierwszy kompletny obiekt JSON z odpowiedzi (modele bywają „gadatliwe” lub dodają ```json).
    static func parse(_ text: String) -> Step? {
        guard let obj = firstJSONObject(in: text), let v = try? JSONValue.parse(obj) else { return nil }   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
        switch v["type"]?.stringValue {
        case "tool_call":
            guard let name = v["tool"]?.stringValue else { return nil }
            return .toolCall(ToolCall(name: name, arguments: v["arguments"]?.objectValue ?? [:]))
        case "final": return .final(v)
        default:
            if v["summary"] != nil { return .final(v) }
            if let name = v["tool"]?.stringValue { return .toolCall(ToolCall(name: name, arguments: v["arguments"]?.objectValue ?? [:])) }
            return nil
        }
    }

    static func firstJSONObject(in s: String) -> String? {
        let chars = Array(s)
        var depth = 0, start: Int?, inStr = false, esc = false
        for (i, c) in chars.enumerated() {
            if inStr { if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }; continue }
            if c == "\"" { inStr = true }
            else if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0, let st = start { return String(chars[st...i]) }; if depth < 0 { depth = 0 } }
        }
        return nil
    }
}

/// Walidator ugruntowania: weryfikuje twierdzenia modelu względem rzeczywiście zebranych dowodów.
public enum GroundingValidator {
    /// - Parameter evidence: pomiary zebrane w tej turze – do sprawdzenia LICZB w twierdzeniach (P2-8 / AUD-LLM-4), nie tylko istnienia identyfikatorów.
    public static func validate(_ claims: [AssistantClaim], known: Set<String>, evidence: [Evidence] = []) -> [AssistantClaim] {
        claims.map { c in
            var x = c
            let valid = c.evidence.filter { id in known.contains(id) || known.contains { $0.hasPrefix(id + ".") } }
            let invalid = c.evidence.filter { !valid.contains($0) }
            x.evidence = valid
            if valid.isEmpty {
                if c.certainty != .aiHypothesis { x.certainty = .aiHypothesis }
                x.groundingNote = c.evidence.isEmpty ? String(localized: "Brak wskazanych pomiarów – traktuj jako przypuszczenie.") : String(localized: "Wskazane dowody nie istnieją (\(invalid.joined(separator: ", "))) – przypuszczenie.")
                return x
            } else if !invalid.isEmpty {
                x.groundingNote = String(localized: "Pominięto nieistniejące dowody: \(invalid.joined(separator: ", ")).")
            }
            // Liczby z jednostką w twierdzeniu („6 GB”, „85%”) muszą zgadzać się z wartościami wskazanych pomiarów (tolerancja 10%).
            let stated = Quantity.all(in: c.text)
            guard !stated.isEmpty, x.certainty != .aiHypothesis else { return x }
            let cited = evidence.filter { e in valid.contains { e.id == $0 || e.id.hasPrefix($0 + ".") } }
            let measured = cited.flatMap { e -> [Quantity] in
                var q = Quantity.all(in: e.value)
                if let n = e.numeric, let u = e.unit, let unit = Quantity.Unit(u) { q.append(Quantity(value: n, unit: unit)) }
                return q
            }
            if measured.isEmpty {
                if x.certainty == .confirmed { x.certainty = .probable }
                x.groundingNote = [x.groundingNote, String(localized: "Liczb w twierdzeniu nie da się porównać z pomiarem – pewność obniżona.")].compactMap { $0 }.joined(separator: " ")
            } else if let bad = stated.first(where: { s in !measured.contains { $0.matches(s) } }) {
                x.certainty = .aiHypothesis
                x.groundingNote = [x.groundingNote, String(localized: "Wartość „\(bad.text)” nie zgadza się z pomiarem (\(cited.map { "\($0.id) = \($0.value)" }.joined(separator: "; "))) – przypuszczenie.")].compactMap { $0 }.joined(separator: " ")
            }
            return x
        }
    }
}

/// Wielkość z jednostką wyciągnięta z tekstu (twierdzenie modelu albo wartość pomiaru) – do porównania liczb.
struct Quantity: Equatable {
    enum Unit: Equatable {
        case bytes, percent, celsius, seconds
        init?(_ raw: String) {
            switch raw.lowercased() {
            case "b", "kb", "mb", "gb", "tb", "kib", "mib", "gib", "tib", "bajt", "bajty", "bajtów": self = .bytes
            case "%", "procent": self = .percent
            case "°c", "°", "c": self = .celsius
            case "s", "ms", "min", "h": self = .seconds
            default: return nil
            }
        }
    }
    var value: Double
    var unit: Unit
    var text: String = ""

    static func scale(_ u: String) -> Double {
        switch u.lowercased() {
        case "kb", "kib": return 1e3; case "mb", "mib": return 1e6; case "gb", "gib": return 1e9; case "tb", "tib": return 1e12
        case "ms": return 0.001; case "min": return 60; case "h": return 3600
        default: return 1
        }
    }

    static func all(in s: String) -> [Quantity] {
        guard let re = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB|TiB|GiB|MiB|KiB|kB|B|%|°C|°|ms|min|s|h)(?![A-Za-zĄĆĘŁŃÓŚŹŻąćęłńóśźż])"#) else { return [] }   // try? świadomie: stały wzorzec – błąd niemożliwy
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let rn = Range(m.range(at: 1), in: s), let ru = Range(m.range(at: 2), in: s), let r0 = Range(m.range, in: s),
                  let n = Double(s[rn].replacingOccurrences(of: ",", with: ".")), let unit = Unit(String(s[ru])) else { return nil }
            return Quantity(value: n * scale(String(s[ru])), unit: unit, text: String(s[r0]))
        }
    }

    func matches(_ other: Quantity) -> Bool {
        guard unit == other.unit else { return false }
        let tol = Swift.max(abs(value) * 0.1, unit == .percent || unit == .celsius ? 1 : 0)
        return abs(value - other.value) <= tol
    }
    static func == (a: Quantity, b: Quantity) -> Bool { a.value == b.value && a.unit == b.unit }
}

/// Orkiestrator: model ↔ executor narzędzi. Narzędzia odczytu wykonują się od razu,
/// operacje trafiają do executora i (zależnie od trybu) czekają na zatwierdzenie.
public actor AssistantOrchestrator {
    public let provider: any LLMProvider
    public let executor: ToolExecutor
    public var maxToolCalls = 5
    /// P2-8 (AUD-LLM-5): twardy limit odpowiedzi modelu w jednej turze – po nim odpowiedź zastępcza z reguł (model nie może kręcić się bez końca).
    public var maxModelTurns = 8
    private var history: [LLMMessage] = []

    public init(provider: any LLMProvider, executor: ToolExecutor) { self.provider = provider; self.executor = executor }

    public func reset() { history = [] }

    /// Budżet znaków na wynik pojedynczego narzędzia, zależny od okna kontekstu (≈3,5 znaku/token dla PL).
    var perResultCharBudget: Int { max(600, Int(Double(provider.contextWindowTokens) * 3.5 * 0.18)) }

    public func ask(_ question: String, mode: AgentMode) async -> AssistantAnswer {
        await executor.setMode(mode)
        await executor.beginTurn()
        let specs = executor.registry.modelVisibleSpecs.filter { mode != .diagnostic || $0.kind == .read }
        var msgs = [LLMMessage(.system, AgentProtocol.systemPrompt(tools: specs, mode: mode))]
        msgs += history.suffix(4)
        msgs.append(LLMMessage(.user, question))
        var steps: [String] = []
        var evidence: [Evidence] = []
        var knownIDs = Set<String>()
        var calls = 0
        var badReplies = 0

        var turns = 0
        while true {
            if Task.isCancelled { return await fallbackAnswer(question, steps + ["Przerwano."], evidence) }
            turns += 1
            if turns > maxModelTurns { return await fallbackAnswer(question, steps + [String(localized: "Przekroczono limit \(maxModelTurns) kroków modelu – przerwano analizę.")], evidence) }
            let reply: String
            do { reply = try await provider.complete(trimmed(msgs), options: LLMOptions()) }
            catch { steps.append("Model: \(error.localizedDescription)"); return await fallbackAnswer(question, steps, evidence) }

            guard let step = AgentProtocol.parse(reply) else {
                badReplies += 1
                steps.append(String(localized: "Model zwrócił odpowiedź w złym formacie."))
                if badReplies >= 2 { return await fallbackAnswer(question, steps, evidence) }
                msgs.append(LLMMessage(.assistant, String(reply.prefix(400))))
                msgs.append(LLMMessage(.user, String(localized: "Odpowiedz wyłącznie jednym obiektem JSON w wymaganym formacie.")))
                continue
            }
            switch step {
            case .toolCall(let call):
                calls += 1
                guard calls <= maxToolCalls else {
                    msgs.append(LLMMessage(.user, String(localized: "Limit narzędzi wyczerpany. Udziel odpowiedzi końcowej (type=final) na podstawie zebranych danych.")))
                    continue
                }
                let spec = executor.registry.tool(call.name)?.spec
                if let spec, spec.kind == .action {
                    // Operacje NIE są wykonywane w pętli rozumowania – model ma je zaproponować w odpowiedzi końcowej.
                    steps.append(String(localized: "Model próbował wykonać operację \(call.name) – zamieniono na propozycję."))
                    msgs.append(LLMMessage(.assistant, reply))
                    msgs.append(LLMMessage(.tool, String(localized: "Operacji nie wykonuje się w trakcie analizy. Umieść ją w proposed_actions odpowiedzi końcowej.")))
                    continue
                }
                let outcome = await executor.handle(call, origin: .llm)
                if case .completed(let r) = outcome {
                    evidence += r.evidence
                    // P2-8 (AUD-LLM-3): dowodami są WYŁĄCZNIE pomiary zwrócone strukturalnie przez narzędzie. Tekst wyniku (nazwy plików, procesów)
                    // bywa kontrolowany z zewnątrz – „[disk.low]” w nazwie pliku nie może stać się dowodem.
                    knownIDs.formUnion(r.evidence.map { $0.id })
                }
                let text = String(outcome.textForModel.prefix(perResultCharBudget))
                steps.append("\(call.name)(\(JSONValue.object(call.arguments).jsonString)) → \(text.prefix(160))")
                msgs.append(LLMMessage(.assistant, reply))
                msgs.append(LLMMessage(.tool, "Wynik \(call.name):\n" + text))

            case .final(let v):
                let rawClaims: [AssistantClaim] = (v["claims"]?.arrayValue ?? []).compactMap { c in
                    guard let t = c["text"]?.stringValue, !t.isEmpty else { return nil }
                    let cert: Certainty
                    switch c["certainty"]?.stringValue { case "confirmed": cert = .confirmed; case "probable": cert = .probable; default: cert = .aiHypothesis }
                    return AssistantClaim(text: t, evidence: c["evidence"]?.arrayValue?.compactMap { $0.stringValue } ?? [], certainty: cert, groundingNote: nil)
                }
                let claims = GroundingValidator.validate(rawClaims, known: knownIDs, evidence: evidence)
                var proposed: [ProposedOperation] = []
                var pending: [PendingApproval] = []
                var previews: [OperationPreview] = []
                var rejected: [String] = []
                for p in v["proposed_actions"]?.arrayValue ?? [] {
                    guard let tool = p["tool"]?.stringValue else { continue }
                    let op = ProposedOperation(tool: tool, arguments: p["arguments"]?.objectValue ?? [:], reason: p["reason"]?.stringValue ?? "")
                    if mode == .diagnostic { rejected.append("\(tool): tryb diagnostyki"); continue }
                    let out = await executor.handle(ToolCall(name: tool, arguments: op.arguments), origin: .llm)
                    switch out {
                    case .needsApproval(let pa): pending.append(pa); proposed.append(op)
                    case .previewOnly(let pv, _): previews.append(pv); proposed.append(op)
                    case .rejected(let m), .failed(let m): rejected.append("\(tool): \(m)")
                    case .completed(let r): proposed.append(op); steps.append(String(localized: "Wykonano automatycznie (zatwierdzona czynność): \(r.summary)"))
                    }
                }
                let summary = v["summary"]?.stringValue ?? ""
                history.append(LLMMessage(.user, question))
                history.append(LLMMessage(.assistant, String(summary.prefix(600))))
                return AssistantAnswer(summary: summary.isEmpty ? String(localized: "Model nie podał podsumowania.") : summary, claims: claims,
                                       missingData: v["missing_data"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                                       proposed: proposed, pendingApprovals: pending, previewOnly: previews, rejectedProposals: rejected, steps: steps,
                                       evidenceUsed: evidence, providerName: provider.displayName, fallback: false)
            }
        }
    }

    /// Przycina najstarsze wyniki narzędzi, aby zmieścić się w oknie kontekstu.
    func trimmed(_ msgs: [LLMMessage]) -> [LLMMessage] {
        let budget = Int(Double(provider.contextWindowTokens) * 3.5 * 0.8)
        var m = msgs
        var total = m.reduce(0) { $0 + $1.content.count }
        var i = 1
        while total > budget && i < m.count - 1 {
            if m[i].role == .tool && m[i].content.count > 200 {
                total -= m[i].content.count - 200
                m[i].content = String(m[i].content.prefix(200)) + "…[skrócono]"
            }
            i += 1
        }
        return m
    }

    /// Gdy model zawiedzie – odpowiedź deterministyczna z reguł (jawnie oznaczona).
    private func fallbackAnswer(_ q: String, _ steps: [String], _ ev: [Evidence]) async -> AssistantAnswer {
        let out = await executor.handle(ToolCall(name: "get_findings"), origin: .rule)
        var text = String(localized: "Model językowy nie udzielił poprawnej odpowiedzi. Poniżej wyniki deterministycznego silnika reguł.")
        if case .completed(let r) = out { text += "\n" + r.summary }
        return AssistantAnswer(summary: text, claims: [], missingData: [], proposed: [], pendingApprovals: [], rejectedProposals: [], steps: steps,
                               evidenceUsed: ev, providerName: provider.displayName, fallback: true)
    }
}
