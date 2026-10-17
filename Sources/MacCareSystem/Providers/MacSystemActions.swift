#if os(macOS)
import AppKit
import Darwin
import MacCareCore

/// Operacje systemowe. Każda sama weryfikuje cel (nazwa aplikacji, label, ścieżka plist) – niezależnie od warstwy wyżej.
public struct MacSystemActions: SystemActions {
    let quarantine: QuarantineStore
    let launchAgentsDirectory: String
    let uid: uid_t

    public init(quarantine: QuarantineStore, home: String = NSHomeDirectory(), launchAgentsDirectory: String? = nil, uid: uid_t = getuid()) {
        self.quarantine = quarantine
        self.launchAgentsDirectory = launchAgentsDirectory ?? home + "/Library/LaunchAgents"
        self.uid = uid
    }

    // MARK: Aplikacje
    public func runningApps() async -> [String] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.localizedName }
        }
    }

    public func quitApp(named name: String, force: Bool) async throws -> String {
        try ExecutionGuard.require(.quitApp)
        guard !name.isEmpty, name.count <= 128, !name.contains("\0") else { throw ActionError(String(localized: "Nieprawidłowa nazwa aplikacji")) }
        guard !ProcessGuard.protectedNames.contains(name) else { throw ActionError(String(localized: "Proces chroniony: \(name)")) }
        let me = getpid()
        let outcome: Result<Int, ActionError> = await MainActor.run {
            // Tylko zwykłe aplikacje (z oknem/Docka) o dokładnie tej nazwie.
            let matches = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.localizedName == name }
            guard !matches.isEmpty else { return .failure(ActionError(String(localized: "Aplikacja „\(name)” nie jest uruchomiona (lub nie jest zwykłą aplikacją)."))) }
            if matches.contains(where: { $0.processIdentifier == me }) { return .failure(ActionError(String(localized: "MacCare nie zamyka samego siebie."))) }
            if matches.contains(where: { $0.bundleURL?.path.hasPrefix("/System/") == true }) { return .failure(ActionError(String(localized: "Aplikacja systemowa: \(name)"))) }
            for a in matches { if force { _ = a.forceTerminate() } else { _ = a.terminate() } }
            return .success(matches.count)
        }
        switch outcome {
        case .failure(let e): throw e
        case .success(let n):
            return force ? String(localized: "Wymuszono zamknięcie „\(name)” (\(n) proc.).") : String(localized: "Poproszono „\(name)” o zamknięcie (\(n) proc.). Aplikacja może zapytać o zapis.")
        }
    }

    // MARK: Autostart użytkownika
    public func disableUserLaunchAgent(label: String) async throws -> String {
        try ExecutionGuard.require(.disableLaunchAgent)
        guard StartupCollector.isValidLabel(label) else { throw ActionError(String(localized: "Nieprawidłowa etykieta agenta")) }
        guard !label.hasPrefix("com.apple.") else { throw ActionError(String(localized: "Elementów Apple nie wyłączam")) }
        guard let plistPath = findPlist(label: label) else {
            throw ActionError(String(localized: "Nie znaleziono agenta „\(label)” w \(launchAgentsDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."))
        }
        // Zatrzymaj, jeśli załadowany. Agent niezaładowany – tylko plist do kwarantanny.
        let loaded = await StartupCollector.loadedState(label: label, scope: .userAgent, uid: uid)
        if loaded == true {
            let r = await CommandRunner.run("/bin/launchctl", ["bootout", "gui/\(uid)", plistPath], timeout: 15)
            if r.status != 0 { throw ActionError(String(localized: "Nie udało się zatrzymać agenta „\(label)” (launchctl, kod \(r.status)). Plist nie został ruszony.")) }
        }
        let size = FileStat.of(plistPath)?.allocatedSize ?? 0
        let entry = try quarantine.quarantine(path: plistPath, size: size, ruleID: "launchagent.disable", batchID: UUID().uuidString, within: launchAgentsDirectory)
        return String(localized: "Agent „\(label)” \(loaded == true ? "zatrzymany, a jego plist" : "(nie był załadowany); plist") przeniesiony do kwarantanny (id \(entry.id)). Przywrócisz go w Historii.")
    }

    /// Plist musi leżeć bezpośrednio w katalogu agentów użytkownika, być zwykłym plikiem (nie dowiązaniem) i mieć zgodny Label.
    func findPlist(label: String) -> String? {
        let dirCanonical = PathTools.canonical(launchAgentsDirectory)
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: launchAgentsDirectory)) ?? []).filter({ $0.hasSuffix(".plist") }).sorted() {   // try? świadomie: nieczytelny katalog ⇒ brak wpisów (tylko odczyt)
            let path = launchAgentsDirectory + "/" + f
            guard let st = FileStat.of(path), st.isRegular, !st.isSymlink,
                  PathTools.canonical((path as NSString).deletingLastPathComponent) == dirCanonical,
                  let data = FileManager.default.contents(atPath: path),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
                  (obj["Label"] as? String) == label else { continue }
            return path
        }
        return nil
    }

    // MARK: Operacje z hasłem administratora
    public func reindexSpotlight(volume: String) async throws -> String {
        try ExecutionGuard.require(.adminCommand)
        guard volume == "/" else { throw ActionError(String(localized: "Przebudowa indeksu jest dostępna tylko dla dysku startowego (/).")) }
        switch await AdminCommand.reindexSpotlightRoot.run() {
        case .ok: return String(localized: "Zainicjowano przebudowę indeksu Spotlight. Indeksowanie potrwa i chwilowo zwiększy obciążenie.")
        case .cancelled: throw ActionError(String(localized: "Anulowano w oknie autoryzacji – nic nie zmieniono."))
        case .failed(let m): throw ActionError(String(localized: "Nie udało się: \(m)"))
        }
    }

    public func flushDNSCache() async throws -> String {
        try ExecutionGuard.require(.adminCommand)
        switch await AdminCommand.flushDNS.run() {
        case .ok: return String(localized: "Wyczyszczono pamięć podręczną DNS.")
        case .cancelled: throw ActionError(String(localized: "Anulowano w oknie autoryzacji – nic nie zmieniono."))
        case .failed(let m): throw ActionError(String(localized: "Nie udało się: \(m)"))
        }
    }

    // MARK: DNS (tylko odczyt, bez ruchu sieciowego)
    // Audyt 16.10 (3.1): wcześniej narzędzie mierzyło czas rozwiązania apple.com/google.com/cloudflare.com (`getaddrinfo` → zapytania do serwerów DNS),
    // czego nie obejmuje zasada „sieć tylko do 127.0.0.1 + aktualizacje”. Do decyzji właściciela pokazujemy wyłącznie lokalną konfigurację.

    /// Adresy serwerów z `scutil --dns` (unikalne, w kolejności).
    static func parseResolvers(_ out: String) -> (servers: [String], searchDomains: [String], resolverCount: Int) {
        var servers: [String] = [], search: [String] = [], count = 0
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") { count += 1 }
            else if line.hasPrefix("nameserver["), let r = line.range(of: ": ") {
                let v = String(line[r.upperBound...]); if !servers.contains(v) { servers.append(v) }
            } else if line.hasPrefix("search domain["), let r = line.range(of: ": ") {
                let v = String(line[r.upperBound...]); if !search.contains(v) { search.append(v) }
            }
        }
        return (servers, search, count)
    }

    public func dnsDiagnostics() async -> String {
        let r = await CommandRunner.run("/usr/sbin/scutil", ["--dns"], timeout: 5)
        let p = Self.parseResolvers(r.output)
        var lines = [String(localized: "Serwery DNS (scutil --dns): \(p.servers.isEmpty ? "brak danych" : p.servers.joined(separator: ", ")); konfiguracji resolverów: \(p.resolverCount).")]
        if !p.searchDomains.isEmpty { lines.append(String(localized: "Domeny wyszukiwania: \(p.searchDomains.prefix(5).joined(separator: ", "))")) }
        lines.append(String(localized: "Test rozwiązywania nazw jest wyłączony – wymagałby zapytań do serwerów DNS w internecie."))
        return lines.joined(separator: "\n")
    }

    // MARK: Ustawienia systemowe
    /// Adresy paneli. Aplikacja tylko je otwiera – niczego nie zmienia.
    static let settingsURLs: [String: String] = [
        "sip": "x-apple.systempreferences:com.apple.preference.security",          // SIP zmienia się wyłącznie z trybu Recovery; pokazujemy Prywatność i ochronę
        "gatekeeper": "x-apple.systempreferences:com.apple.preference.security",
        "filevault": "x-apple.systempreferences:com.apple.preference.security?FDE",
        "firewall": "x-apple.systempreferences:com.apple.preference.security?Firewall",
        "fda": "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "login_items": "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        "updates": "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ]

    public func openSettings(pane: String) async {
        guard let s = Self.settingsURLs[pane], let url = URL(string: s) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
#endif
