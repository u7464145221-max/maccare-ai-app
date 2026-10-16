import Foundation
import SwiftUI
import MacCareCore

/// Sprawdzanie aktualizacji w publicznym repozytorium GitHub (decyzja właściciela 15.10.2026). Tylko na żądanie albo raz w tygodniu po włączeniu
/// (domyślnie wyłączone). Jedno zapytanie GET pod `UpdateCheck.endpoint`, sesja jednorazowa – bez ciasteczek, pamięci podręcznej i danych o Macu.
/// Nic nie jest pobierane ani instalowane: wynik to informacja i link do strony wydania (otwiera go użytkownik).
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate(String), available(UpdateCheck.Release), failed(String) }
    @Published private(set) var state: State = .idle
    static let weeklyKey = "updates.weekly"
    static let lastCheckKey = "updates.lastCheck"

    /// Pobranie odpowiedzi (testy podstawiają własne – bez sieci).
    var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await UpdateChecker.session.data(for: $0) }
    var currentVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    var defaults: UserDefaults = .standard

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never; c.httpShouldSetCookies = false; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    /// Zapytanie: wyłącznie GET, bez treści, bez identyfikatorów Maca (GitHub wymaga tylko nagłówka User-Agent).
    static func request() -> URLRequest {
        var r = URLRequest(url: UpdateCheck.endpoint)
        r.httpMethod = "GET"
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("MacCare-AI", forHTTPHeaderField: "User-Agent")
        return r
    }

    var weeklyEnabled: Bool { defaults.bool(forKey: Self.weeklyKey) }

    func check() async {
        state = .checking
        do {
            let (data, resp) = try await fetch(Self.request())
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let rel = UpdateCheck.parse(data) else {
                state = .failed(String(localized: "Nie udało się odczytać informacji o wydaniu.")); return
            }
            let mine = UpdateCheck.version(currentVersion) ?? [0]
            state = UpdateCheck.isNewer(rel.version, than: mine) ? .available(rel) : .upToDate(currentVersion)
        } catch {
            state = .failed(String(localized: "Brak połączenia z GitHubem – spróbuj później."))
        }
    }

    /// Tryb cotygodniowy (tylko gdy użytkownik go włączył).
    func checkIfDue(now: Date = Date()) async {
        guard state != .checking else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Double
        guard UpdateCheck.isDue(enabled: weeklyEnabled, lastCheck: last.map { Date(timeIntervalSince1970: $0) }, now: now) else { return }
        await check()
    }
}

/// Karta w Ustawieniach.
struct UpdateSettings: View {
    @ObservedObject var updates: UpdateChecker
    @AppStorage(UpdateChecker.weeklyKey) private var weekly = false

    var body: some View {
        SurfaceCard(padding: 20, radius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aktualizacje").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                HStack(spacing: 12) {
                    Button("Sprawdź aktualizacje") { Task { await updates.check() } }.buttonStyle(.soft).disabled(updates.state == .checking)
                    status
                }
                Toggle("Sprawdzaj raz w tygodniu", isOn: $weekly).toggleStyle(.switch)
                Text("MacCare łączy się wtedy tylko ze stroną wydań na GitHubie (\(UpdateCheck.owner)/\(UpdateCheck.repo)) i niczego nie wysyła o Twoim Macu. Nowej wersji nie pobiera ani nie instaluje sam – pokazuje ją i otwiera stronę wydania.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch updates.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate(let v): Text(String(localized: "Masz najnowszą wersję (\(v)).")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.ok)
        case .available(let r):
            HStack(spacing: 8) {
                Text(String(localized: "Dostępna wersja \(r.tag).")).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
                Button("Otwórz stronę wydania") { NSWorkspace.shared.open(r.page) }.buttonStyle(.soft)
            }
        case .failed(let m): Text(m).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
