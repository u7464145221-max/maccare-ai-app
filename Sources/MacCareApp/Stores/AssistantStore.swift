import Foundation
import MacCareCore
import MacCareAI

/// Wybrany lokalny model albo powód, dla którego asystent nie może działać.
enum AssistantProviderPick {
    case ready(any LLMProvider, modelBytes: UInt64?)
    case unavailable(String)
}

/// Asystent AI (P2-9): rozmowa z LOKALNYM modelem (Ollama na 127.0.0.1 albo Apple Foundation Models), który zbiera dane wyłącznie narzędziami odczytu.
/// Operacje proponowane przez model są tylko podglądem (tryb odczytu) albo czekają na zatwierdzenie – model nie ma narzędzi zmieniających tryb ani `userOnly`.
/// Ma własnego wykonawcę narzędzi (ten sam rejestr i dziennik audytu co aplikacja), więc nie miesza się z zatwierdzeniami użytkownika.
@MainActor
final class AssistantStore: ObservableObject {
    enum Status: Equatable {
        case unknown, checking
        case ready(String)
        case unavailable(String)
    }

    struct Entry: Identifiable {
        let id = UUID()
        let question: String
        let askedAt: Date
        var answer: AssistantAnswer?
        var error: String?
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var busy = false

    private let executor: ToolExecutor
    private var orchestrator: AssistantOrchestrator?
    private var modelBytes: UInt64?
    private var task: Task<Void, Never>?
    /// Bieżący pomiar pamięci (strażnik zasobów przed każdym pytaniem).
    var memory: () -> MemoryStats? = { nil }
    /// Wybór dostawcy: (pomiar pamięci, model wybrany w Ustawieniach albo nil = automatycznie). Testy podstawiają `ScriptedProvider`.
    var providerFactory: (MemoryStats?, String?) async -> AssistantProviderPick = { m, p in await AssistantStore.localProvider(memory: m, preferred: p) }

    /// Model wybrany w Ustawieniach (nil = automatycznie). Zmiana unieważnia bieżący wybór – następne pytanie sprawdzi model od nowa.
    @Published var preferredModel: String? {
        didSet {
            guard preferredModel != oldValue else { return }
            onPreferenceChange(preferredModel)
            orchestrator = nil; modelBytes = nil; status = .unknown
        }
    }
    var onPreferenceChange: (String?) -> Void = { _ in }
    /// Zainstalowane modele Ollamy (lista do Ustawień; tylko odczyt `/api/tags`).
    @Published private(set) var installedModels: [OllamaProvider.ModelInfo] = []

    func loadInstalledModels() async {
        installedModels = ((try? await OllamaProvider().listModelInfos()) ?? []).filter { !$0.name.lowercased().contains("embed") }
    }

    /// Czy model zmieści się teraz w pamięci (opis do Ustawień).
    func fitsNow(_ m: OllamaProvider.ModelInfo) -> Bool {
        let g = memory().map(ResourceGuard.init(memory:)) ?? ResourceGuard()
        return g.canRun(modelBytes: m.sizeBytes + m.sizeBytes / 4).isAvailable
    }

    static let suggestions = [String(localized: "Dlaczego mój Mac może zwalniać?"), String(localized: "Co zajmuje najwięcej miejsca na dysku?"), String(localized: "Czy w autostarcie jest coś niepokojącego?"), String(localized: "Jak wygląda stan baterii i temperatury?")]

    init(executor: ToolExecutor) { self.executor = executor }

    var isReady: Bool { if case .ready = status { return true }; return false }

    /// Sprawdza dostępność lokalnego modelu (bez pobierania czegokolwiek).
    func refreshStatus() async {
        guard !busy else { return }
        await loadProvider()
    }

    private func loadProvider() async {
        status = .checking
        switch await providerFactory(memory(), preferredModel) {
        case .ready(let p, let bytes):
            orchestrator = AssistantOrchestrator(provider: p, executor: executor)
            modelBytes = bytes
            status = .ready(p.displayName)
        case .unavailable(let why):
            orchestrator = nil; modelBytes = nil
            status = .unavailable(why)
        }
    }

    func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        entries.append(Entry(question: q, askedAt: Date()))
        let index = entries.count - 1
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            if self.orchestrator == nil { await self.loadProvider() }
            guard let o = self.orchestrator else {
                self.finish(index, answer: nil, error: { if case .unavailable(let m) = self.status { return m }; return String(localized: "Lokalny model jest niedostępny.") }())
                return
            }
            // strażnik zasobów tuż przed inferencją (swap, dostępna pamięć, ciśnienie)
            if let bytes = self.modelBytes, let m = self.memory(), case .unavailable(let why) = ResourceGuard(memory: m).canRun(modelBytes: bytes + bytes / 4) {
                self.finish(index, answer: nil, error: why)
                return
            }
            let a = await o.ask(q, mode: .assistant)
            self.finish(index, answer: Task.isCancelled ? nil : a, error: Task.isCancelled ? String(localized: "Przerwano.") : nil)
        }
    }

    private func finish(_ i: Int, answer: AssistantAnswer?, error: String?) {
        if entries.indices.contains(i) { entries[i].answer = answer; entries[i].error = error }
        busy = false; task = nil
    }

    func cancel() { task?.cancel() }

    func clear() {
        guard !busy else { return }
        entries = []
        Task { await orchestrator?.reset() }
    }

    /// Domyślny wybór: zainstalowany model Ollamy mieszczący się w pamięci (P3-8), a gdy Ollama nie działa – model systemowy Apple (jeśli dostępny).
    nonisolated static func localProvider(memory: MemoryStats?, preferred: String? = nil) async -> AssistantProviderPick {
        let g = memory.map(ResourceGuard.init(memory:)) ?? ResourceGuard()
        let base = OllamaProvider()
        if let infos = try? await base.listModelInfos() {
            // model wybrany w Ustawieniach – tylko jeśli zainstalowany i mieści się teraz w pamięci
            if let name = preferred, let m = infos.first(where: { $0.name == name }) {
                if case .unavailable(let why) = g.canRun(modelBytes: m.sizeBytes + m.sizeBytes / 4) {
                    return .unavailable(String(localized: "Wybrany model \(m.name) (\(ByteFormat.string(m.sizeBytes))) nie mieści się teraz w pamięci. \(why) Możesz wybrać „Automatycznie” w Ustawieniach."))
                }
                return .ready(OllamaProvider(model: m.name, contextWindowTokens: 8192), modelBytes: m.sizeBytes)
            }
            if infos.isEmpty { return .unavailable(String(localized: "Ollama działa, ale nie ma pobranych modeli. MacCare niczego nie pobiera sam – pobierz model świadomie, np. `ollama pull qwen2.5:7b`.")) }
            if let pick = OllamaProvider.choose(from: infos, guard: g) {
                return .ready(OllamaProvider(model: pick.name, contextWindowTokens: 8192), modelBytes: pick.sizeBytes)
            }
            // żaden model Ollamy się teraz nie mieści – mniejszy model systemowy Apple, jeśli jest włączony i zna polski
            if let apple = await appleProvider() { return .ready(apple, modelBytes: nil) }
            let names = infos.filter { !$0.name.lowercased().contains("embed") }.map { "\($0.name) (\(ByteFormat.string($0.sizeBytes)))" }.prefix(4).joined(separator: ", ")
            let smallest = infos.map(\.sizeBytes).filter { $0 > 0 }.min() ?? 0
            var why = String(localized: "Zainstalowane modele (\(names)) nie mieszczą się teraz bezpiecznie w pamięci.")
            if case .unavailable(let reason) = g.canRun(modelBytes: smallest + smallest / 4) { why += " " + reason }
            return .unavailable(why + String(localized: " Możesz też pobrać mniejszy model: \(g.recommendedModelHint) – MacCare niczego nie pobiera sam."))
        }
        if let apple = await appleProvider() { return .ready(apple, modelBytes: nil) }
        return .unavailable(String(localized: "Lokalny model nie działa: Ollama nie odpowiada pod 127.0.0.1:11434. Uruchom aplikację Ollama (dane nie opuszczają Maca)."))
    }

    /// Model systemowy Apple – tylko gdy Apple Intelligence jest włączone i model obsługuje polski (asystent odpowiada po polsku).
    nonisolated static func appleProvider() async -> (any LLMProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let apple = FoundationModelsProvider()
            if await apple.availability().isAvailable, FoundationModelsProvider.supportsInterfaceLanguage { return apple }
        }
        #endif
        return nil
    }
}
