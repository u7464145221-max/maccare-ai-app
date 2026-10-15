import Foundation
import MacCareCore

public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

public struct LLMOptions: Sendable {
    public var temperature: Double = 0.2
    public var maxOutputTokens: Int = 700
    /// Wymuszenie odpowiedzi w JSON (jeśli dostawca to wspiera).
    public var jsonMode: Bool = true
    public init(temperature: Double = 0.2, maxOutputTokens: Int = 700, jsonMode: Bool = true) {
        self.temperature = temperature; self.maxOutputTokens = maxOutputTokens; self.jsonMode = jsonMode
    }
}

public enum ProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
    case needsDownload(String)
    public var isAvailable: Bool { self == .available }
    public var message: String {
        switch self { case .available: return String(localized: "Dostępny"); case .unavailable(let m): return m; case .needsDownload(let m): return m }
    }
}

public enum LLMError: Error, LocalizedError, Sendable {
    case unavailable(String), badResponse(String), cancelled, insufficientMemory(String), contextTooLong
    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): return String(localized: "Model niedostępny: \(m)")
        case .badResponse(let m): return String(localized: "Nieprawidłowa odpowiedź modelu: \(m)")
        case .cancelled: return String(localized: "Wnioskowanie przerwane")
        case .insufficientMemory(let m): return String(localized: "Za mało pamięci: \(m)")
        case .contextTooLong: return String(localized: "Kontekst przekracza okno modelu")
        }
    }
}

/// Warstwa abstrakcji – wymiana modelu bez przebudowy aplikacji.
public protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// true = inferencja w całości na urządzeniu (bez sieci).
    var isOnDevice: Bool { get }
    /// Przybliżone okno kontekstu w tokenach (do budżetowania danych diagnostycznych).
    var contextWindowTokens: Int { get }
    func availability() async -> ProviderAvailability
    /// Przerwanie: anulowanie Task, w którym wywołano `complete`.
    func complete(_ messages: [LLMMessage], options: LLMOptions) async throws -> String
}

/// Kontrola zasobów przed inferencją (komputery z małą ilością RAM).
public struct ResourceGuard: Sendable {
    public var physicalMemory: UInt64
    public var pressure: MemoryPressureLevel
    /// P2-8 (AUD-LLM-2): zajętość swapu i dostępna pamięć (nil = nieznane). Wyczerpany swap przy „normalnym” ciśnieniu też oznacza, że model pogorszy działanie Maca.
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var availableMemory: UInt64?
    public init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, pressure: MemoryPressureLevel = .normal,
                swapUsed: UInt64 = 0, swapTotal: UInt64 = 0, availableMemory: UInt64? = nil) {
        self.physicalMemory = physicalMemory; self.pressure = pressure
        self.swapUsed = swapUsed; self.swapTotal = swapTotal; self.availableMemory = availableMemory
    }
    /// Strażnik z bieżącego pomiaru pamięci (dostępna = całość − używana przez aplikacje, jądro i kompresję; pamięć podręczna plików liczy się jako dostępna).
    public init(memory m: MemoryStats) {
        self.init(physicalMemory: m.total, pressure: m.pressure, swapUsed: m.swapUsed, swapTotal: m.swapTotal,
                  availableMemory: m.total > m.used ? m.total - m.used : 0)
    }
    /// Czy można uruchomić model o danym zapotrzebowaniu na pamięć (wagi + KV cache).
    public func canRun(modelBytes: UInt64) -> ProviderAvailability {
        if pressure == .critical { return .unavailable(String(localized: "Krytyczne ciśnienie pamięci – wstrzymuję lokalny model, by nie pogorszyć stanu systemu.")) }
        // Sam stosunek swapu nie wystarcza: macOS dokłada pliki wymiany w miarę potrzeby i rzadko je zwalnia (zmierzone: swap 97% przy 41% wolnej pamięci).
        // Odmowa, gdy system już intensywnie korzysta ze swapu I model nie zmieści się w dostępnej pamięci (albo jej nie znamy).
        if swapTotal > 0, Double(swapUsed) / Double(swapTotal) > 0.5, (availableMemory.map { modelBytes > $0 } ?? true) {
            return .unavailable(String(localized: "Swap jest zajęty w \(Int(Double(swapUsed) / Double(swapTotal) * 100))% (\(ByteFormat.string(swapUsed)) z \(ByteFormat.string(swapTotal))) – uruchomienie modelu pogorszyłoby działanie Maca. Zamknij część aplikacji i spróbuj ponownie."))
        }
        if let avail = availableMemory, Double(avail) < Double(physicalMemory) * 0.1 {
            return .unavailable(String(localized: "Dostępnej pamięci jest tylko \(ByteFormat.string(avail)) – za mało, by bezpiecznie uruchomić lokalny model."))
        }
        let budget = Double(physicalMemory) * (pressure == .warning ? 0.35 : 0.6)
        if Double(modelBytes) > budget { return .unavailable(String(localized: "Model wymaga ok. \(ByteFormat.string(modelBytes)), a bezpieczny budżet to \(ByteFormat.string(UInt64(budget))). Wybierz mniejszy model.")) }
        return .available
    }
    /// Rekomendowany rozmiar modelu (parametry) dla Ollama/MLX.
    public var recommendedModelHint: String {
        let gb = Double(physicalMemory) / 1_073_741_824
        if gb <= 8.5 { return String(localized: "do 3B parametrów (np. qwen2.5:3b, llama3.2:3b)") }
        if gb <= 16.5 { return String(localized: "do 8B parametrów (np. qwen2.5:7b, llama3.1:8b)") }
        if gb <= 36.5 { return String(localized: "do 14B parametrów (np. qwen2.5:14b)") }
        return String(localized: "do 32B parametrów (np. qwen2.5:32b)")
    }
}

/// Dostawca testowy/skryptowy – deterministyczne odpowiedzi (testy jakości asystenta).
public final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    public let id = "scripted"
    public let displayName = "Skryptowany (testy)"
    public let isOnDevice = true
    public var contextWindowTokens = 4096
    private var replies: [String]
    private let lock = NSLock()
    public private(set) var received: [[LLMMessage]] = []
    public init(replies: [String]) { self.replies = replies }
    public func availability() async -> ProviderAvailability { .available }
    public func complete(_ messages: [LLMMessage], options: LLMOptions) async throws -> String {
        try next(messages)
    }
    private func next(_ messages: [LLMMessage]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        received.append(messages)
        guard !replies.isEmpty else { throw LLMError.badResponse("brak skryptowanej odpowiedzi") }
        return replies.removeFirst()
    }
}
