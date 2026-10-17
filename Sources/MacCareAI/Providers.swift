import Foundation
import MacCareCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Ollama (opcjonalny lokalny dostawca, wymaga zainstalowanej usługi)

public struct OllamaProvider: LLMProvider {
    public let id = "ollama"
    public var displayName: String { "Ollama · \(model)" }
    public let isOnDevice = true
    public var contextWindowTokens: Int
    public var baseURL: URL
    public var model: String
    let session: URLSession

    /// Domyślnie dozwolony wyłącznie adres lokalny – dane diagnostyczne nie opuszczają Maca.
    /// Sesja tylko do lokalnego serwera (skill `maccare-local-llm`): bez systemowego proxy/PAC (zapytania do 127.0.0.1 nie mogą trafić do serwera proxy)
    /// i bez trwałej pamięci podręcznej, ciasteczek ani poświadczeń na dysku.
    public static let loopbackSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        // Audyt 16.10 (2.3): bez przekierowań – odpowiedź 30x z „lokalnego” portu nie może przenieść zapytania (z treścią) na inny adres.
        return URLSession(configuration: c, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    /// Odrzuca każde przekierowanie HTTP (odpowiedź 30x trafia do wywołującego jako zwykła odpowiedź, nie jest śledzona).
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    /// Audyt 16.10 (2.3): Ollama potrafi udostępniać pod lokalnym adresem modele działające w chmurze (`…-cloud`, pola `remote_host`/`remote_model`) –
    /// zapytanie do nich opuszcza Maca. Inwariant „AI tylko lokalnie”: takie modele są pomijane wszędzie i odrzucane przy rozmowie.
    public static func isRemoteModelName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix("-cloud") || n.hasSuffix(":cloud") || n.contains("-cloud:") || n.contains(":cloud-")
    }

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String = "qwen2.5:7b", contextWindowTokens: Int = 8192, session: URLSession = OllamaProvider.loopbackSession) {
        self.baseURL = baseURL; self.model = model; self.contextWindowTokens = contextWindowTokens; self.session = session
    }

    public static func isLoopback(_ url: URL) -> Bool { ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "") }

    public func availability() async -> ProviderAvailability {
        guard Self.isLoopback(baseURL) else { return .unavailable(String(localized: "Adres Ollamy nie jest lokalny – zablokowano, aby dane nie opuszczały komputera.")) }
        do {
            let models = try await listModels()
            if models.isEmpty { return .needsDownload(String(localized: "Ollama działa, ale nie ma pobranych modeli. Pobierz model świadomie: ollama pull \(model)")) }
            if !models.contains(model) && !models.contains(model + ":latest") { return .needsDownload(String(localized: "Brak modelu \(model). Dostępne: \(models.prefix(5).joined(separator: ", "))")) }
            return .available
        } catch { return .unavailable(String(localized: "Ollama nie odpowiada pod \(baseURL.absoluteString)")) }
    }

    /// Zainstalowany model z rozmiarem wag (z `GET /api/tags`).
    public struct ModelInfo: Sendable, Equatable {
        public var name: String
        public var sizeBytes: UInt64
        public init(name: String, sizeBytes: UInt64) { self.name = name; self.sizeBytes = sizeBytes }
    }

    public func listModelInfos() async throws -> [ModelInfo] {
        guard Self.isLoopback(baseURL) else { throw LLMError.unavailable(String(localized: "adres nielokalny")) }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags")); req.timeoutInterval = 3
        let (data, _) = try await session.data(for: req)
        return Self.parseModelInfos(data)
    }

    public static func parseModelInfos(_ data: Data) -> [ModelInfo] {
        guard let v = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return [] }   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
        return v["models"]?.arrayValue?.compactMap { m in
            guard let name = m["name"]?.stringValue, !isRemoteModelName(name),
                  (m["remote_host"]?.stringValue ?? "").isEmpty, (m["remote_model"]?.stringValue ?? "").isEmpty else { return nil }   // model w chmurze – pomijany
            return ModelInfo(name: name, sizeBytes: UInt64(max(0, m["size"]?.numberValue ?? 0)))
        } ?? []
    }

    /// P3-8 (AUD-LLM-6): wybór spośród ZAINSTALOWANYCH modeli – bez pobierania. Pomija modele osadzeń; wymaga, by model (wagi + ok. 25% na kontekst)
    /// mieścił się w budżecie strażnika zasobów. Kolejność: rodziny najlepiej trzymające format JSON i język polski, potem większy model.
    public static let preferredFamilies = ["qwen2.5", "qwen3", "bielik", "llama3", "mistral", "gemma"]
    public static func choose(from models: [ModelInfo], guard g: ResourceGuard) -> ModelInfo? {
        let usable = models.filter { m in
            let n = m.name.lowercased()
            return !n.contains("embed") && !n.contains("vision") && m.sizeBytes > 0 && g.canRun(modelBytes: m.sizeBytes + m.sizeBytes / 4).isAvailable
        }
        func rank(_ m: ModelInfo) -> Int { preferredFamilies.firstIndex { m.name.lowercased().contains($0) } ?? preferredFamilies.count }
        return usable.min { a, b in rank(a) != rank(b) ? rank(a) < rank(b) : a.sizeBytes > b.sizeBytes }
    }

    public func listModels() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags")); req.timeoutInterval = 3
        let (data, _) = try await session.data(for: req)
        return Self.parseModelInfos(data).map(\.name)                                     // tylko modele lokalne (bez chmurowych)
    }

    public func complete(_ messages: [LLMMessage], options: LLMOptions) async throws -> String {
        guard Self.isLoopback(baseURL) else { throw LLMError.unavailable(String(localized: "adres nielokalny")) }
        guard !Self.isRemoteModelName(model) else { throw LLMError.unavailable(String(localized: "model działa w chmurze – MacCare używa wyłącznie modeli lokalnych")) }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"; req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: JSONValue = ["model": .string(model), "stream": false,
                               "messages": .array(messages.map { ["role": .string($0.role == .tool ? "user" : $0.role.rawValue), "content": .string($0.content)] }),
                               "options": ["temperature": .number(options.temperature), "num_predict": .number(Double(options.maxOutputTokens)), "num_ctx": .number(Double(contextWindowTokens))],
                               "keep_alive": "5m"]
        if options.jsonMode, case .object(var o) = body { o["format"] = "json"; body = .object(o) }
        req.httpBody = Data(body.jsonString.utf8)
        let (data, resp) = try await session.data(for: req)
        try Task.checkCancellation()
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.badResponse(String(decoding: data.prefix(300), as: UTF8.self)) }
        return try Self.parseChatResponse(data)
    }

    public static func parseChatResponse(_ data: Data) throws -> String {
        let v = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard let s = v["message"]?["content"]?.stringValue else { throw LLMError.badResponse("brak message.content") }
        return s
    }
}

// MARK: - Apple Foundation Models (macOS 26+, Apple Intelligence włączone)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
public struct FoundationModelsProvider: LLMProvider {
    public let id = "apple.foundation"
    public let displayName = String(localized: "Apple Foundation Models (na urządzeniu)")
    public let isOnDevice = true
    /// Model systemowy ma okno ok. 4096 tokenów – dane diagnostyczne muszą być zwięzłe.
    public let contextWindowTokens = 4096
    public init() {}
    /// Czy model systemowy obsługuje polski (zmierzone 14.10.2026 na macOS 26.5.2: nie).
    /// Model systemowy obsługuje język interfejsu (odpowiedzi mają być w tym samym języku co aplikacja).
    public static var supportsInterfaceLanguage: Bool { SystemLanguageModel.default.supportsLocale(Locale(identifier: AppLanguage.isEnglish ? "en_US" : "pl_PL")) }

    public func availability() async -> ProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(String(localized: "To urządzenie nie obsługuje Apple Intelligence."))
            case .appleIntelligenceNotEnabled: return .unavailable(String(localized: "Włącz Apple Intelligence w Ustawieniach systemowych."))
            case .modelNotReady: return .needsDownload("Model systemowy jest jeszcze pobierany przez macOS.")
            @unknown default: return .unavailable(String(localized: "Model systemowy niedostępny."))
            }
        }
    }

    public func complete(_ messages: [LLMMessage], options: LLMOptions) async throws -> String {
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let convo = messages.filter { $0.role != .system }.map { m -> String in
            switch m.role { case .user: return String(localized: "UŻYTKOWNIK:") + "\n" + m.content; case .assistant: return String(localized: "ASYSTENT:") + "\n" + m.content; case .tool: return String(localized: "WYNIK NARZĘDZIA:") + "\n" + m.content; case .system: return "" }
        }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: convo, options: GenerationOptions(temperature: options.temperature, maximumResponseTokens: options.maxOutputTokens))
        return response.content
    }
}
#endif

// MARK: - MLX Swift (planowany natywny dostawca dla większych modeli)

/// MLX Swift (github.com/ml-explore/mlx-swift-examples, biblioteka MLXLLM) wymaga dodatkowej zależności
/// i ok. 2–20 GB wag modelu. Zgodnie z zasadą „bez zbędnych zależności” jest włączany w ETAPIE 3b
/// jako osobny target. Do tego czasu dostawca raportuje rzetelnie: niedostępny.
public struct MLXProviderPlaceholder: LLMProvider {
    public let id = "mlx"
    public let displayName = "MLX (Apple Silicon)"
    public let isOnDevice = true
    public let contextWindowTokens = 8192
    public init() {}
    public func availability() async -> ProviderAvailability { .unavailable(String(localized: "Dostawca MLX nie jest jeszcze włączony w tej wersji (zaplanowany – patrz docs/PLAN.md).")) }
    public func complete(_ messages: [LLMMessage], options: LLMOptions) async throws -> String { throw LLMError.unavailable(String(localized: "MLX nie jest włączony")) }
}

/// Wybór dostawcy: preferencja natywnej inferencji (Foundation Models), potem Ollama.
public enum ProviderCatalog {
    public static func all(ollamaModel: String = "qwen2.5:7b") -> [any LLMProvider] {
        var list: [any LLMProvider] = []
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { list.append(FoundationModelsProvider()) }
        #endif
        list.append(OllamaProvider(model: ollamaModel))
        list.append(MLXProviderPlaceholder())
        return list
    }

    public static func firstAvailable(_ providers: [any LLMProvider]) async -> (any LLMProvider)? {
        for p in providers where await p.availability().isAvailable { return p }
        return nil
    }
}
