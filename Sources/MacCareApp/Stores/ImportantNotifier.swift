import Foundation
import SwiftUI
import UserNotifications
import MacCareCore

/// Powiadomienia o ważnych sprawach (decyzja właściciela 15.10.2026): mało miejsca, krytyczne ustalenie Ochrony, nowa wersja. Domyślnie wyłączone;
/// zgoda macOS jest proszona dopiero, gdy użytkownik włączy przełącznik. Każdy rodzaj najwyżej raz na dobę (`ImportantNotices`). Tylko lokalnie – bez sieci.
@MainActor
final class ImportantNotifier: ObservableObject {
    static let enabledKey = "notifications.important"
    static let lastSentKey = "notifications.lastSent"
    enum Permission: Equatable { case unknown, granted, denied }
    @Published private(set) var permission: Permission = .unknown

    var defaults: UserDefaults = .standard
    /// Wysłanie (testy podstawiają własne – bez systemu powiadomień).
    var post: (Notice) -> Void = { ImportantNotifier.systemPost($0) }
    /// System powiadomień działa tylko w pakiecie aplikacji (w `swift test` nie ma identyfikatora pakietu – wywołanie by się wyłożyło).
    nonisolated static var systemAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var lastSent: [String: Date] {
        ((defaults.dictionary(forKey: Self.lastSentKey) as? [String: Double]) ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Wywoływane przy włączeniu przełącznika – jedyne miejsce, które prosi macOS o zgodę.
    func requestPermission() async {
        guard Self.systemAvailable else { permission = .denied; return }
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false   // try? świadomie: błąd = brak zgody (pokazywany w Ustawieniach)
        permission = ok ? .granted : .denied
    }

    /// Sprawdza, co jest do powiadomienia, i wysyła (tylko gdy włączone). Zwraca wysłane – dla testów.
    @discardableResult
    func evaluate(freeBytes: Int64?, findings: [Finding], newVersion: String?, now: Date = Date()) -> [Notice] {
        guard enabled else { return [] }
        let due = ImportantNotices.due(freeBytes: freeBytes, findings: findings, newVersion: newVersion, lastSent: lastSent, now: now)
        guard !due.isEmpty else { return [] }
        var stamps = (defaults.dictionary(forKey: Self.lastSentKey) as? [String: Double]) ?? [:]
        for n in due { post(n); stamps[n.kind] = now.timeIntervalSince1970 }
        defaults.set(stamps, forKey: Self.lastSentKey)
        return due
    }

    nonisolated static func systemPost(_ n: Notice) {
        guard systemAvailable else { return }
        let c = UNMutableNotificationContent()
        c.title = n.title; c.body = n.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.kind, content: c, trigger: nil))
    }
}

struct NotificationSettings: View {
    @ObservedObject var notifier: ImportantNotifier
    @AppStorage(ImportantNotifier.enabledKey) private var enabled = false

    var body: some View {
        SurfaceCard(padding: 20, radius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Powiadomienia").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Toggle("Powiadamiaj o ważnych sprawach", isOn: $enabled).toggleStyle(.switch)
                    .onChange(of: enabled) { _, on in if on { Task { await notifier.requestPermission() } } }
                Text("Tylko: mało miejsca na dysku (poniżej 10 GB), krytyczny problem w Ochronie i nowa wersja MacCare (gdy sprawdzanie aktualizacji ją znajdzie). Każdy rodzaj najwyżej raz na dobę; nic nie jest wysyłane poza Twojego Maca.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if enabled && notifier.permission == .denied {
                    Label("macOS nie pozwala MacCare wyświetlać powiadomień – włącz je w Ustawieniach systemowych → Powiadomienia.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
