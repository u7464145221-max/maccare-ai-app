import SwiftUI
import MacCareCore

/// Dwa tryby widoku (T6d): ten sam stan danych, inna prezentacja.
enum ViewMode: String, CaseIterable, Identifiable {
    case simple, pro
    var id: String { rawValue }
    var label: String { self == .simple ? String(localized: "Prosty") : String(localized: "Profesjonalny") }

    static let storageKey = "view.mode"
    /// Pierwsze uruchomienie (brak wartości) albo wartość nieznana ⇒ Prosty.
    static func stored(_ raw: String?) -> ViewMode { raw.flatMap(ViewMode.init(rawValue:)) ?? .simple }

    /// Moduły widoczne w pasku bocznym. Asystent jest zawsze (przypięty na dole).
    /// Tylko moduły z działającym widokiem (`isBuilt`) – P2-15: żadnych pustych ekranów „w budowie” w nawigacji.
    var mainModules: [AppModule] { (self == .simple ? [.smartScan, .cleanup, .protection, .performance] : AppModule.main).filter(\.isBuilt) }
    var secondaryModules: [AppModule] { (self == .simple ? [] : AppModule.secondary).filter(\.isBuilt) }
    func allows(_ m: AppModule) -> Bool { m.isBuilt && (mainModules.contains(m) || secondaryModules.contains(m) || m == .assistant) }
}

private struct ViewModeKey: EnvironmentKey { static let defaultValue = ViewMode.pro }
extension EnvironmentValues {
    /// Domyślnie `.pro`, żeby komponenty użyte poza korzeniem aplikacji nie chowały niczego po cichu.
    var viewMode: ViewMode { get { self[ViewModeKey.self] } set { self[ViewModeKey.self] = newValue } }
}

/// Prezentacja „prostym językiem”: bez identyfikatorów dowodów, ścieżek, PID-ów i statusów podpisu.
enum SimplePresentation {
    enum Status: Equatable {
        case ok, attention, urgent
        var word: String { switch self { case .ok: return String(localized: "Wszystko OK"); case .attention: return String(localized: "Wymaga uwagi"); case .urgent: return String(localized: "Pilne") } }
        var symbol: String { switch self { case .ok: return "checkmark.circle.fill"; case .attention: return "exclamationmark.circle.fill"; case .urgent: return "exclamationmark.triangle.fill" } }
    }

    /// Jedno słowo o stanie Maca. nil = jeszcze brak danych (nie udajemy, że „OK”).
    static func status(assessment: HealthAssessment?, findings: [Finding]) -> Status? {
        guard let a = assessment, let overall = a.overall else { return nil }
        let visible = findings.filter { $0.certainty != .aiHypothesis }
        if visible.contains(where: { $0.severity == .critical }) || overall < 60 { return .urgent }
        if visible.contains(where: { $0.severity == .warning }) || overall < 85 { return .attention }
        return .ok
    }

    struct Recommendation: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        let severity: Severity
        /// Fakty „Dlaczego?” – zwykłe zdania (etykieta: wartość), bez identyfikatorów.
        let why: [String]
        /// Akcje dozwolone w trybie Prostym (ryzyko ≤ niskie).
        let actions: [SuggestedAction]
        /// Jest akcja, ale wymaga trybu Profesjonalnego (ryzyko średnie/wysokie) – nawet jako podgląd.
        let needsPro: Bool
    }

    /// Najważniejsze rekomendacje (domyślnie 3), od najpoważniejszej.
    static func recommendations(findings: [Finding], evidence: [String: Evidence], riskOf: (String) -> RiskLevel?,
                                reclaimable: UInt64? = nil, limit: Int = 3) -> [Recommendation] {
        let ranked = findings.filter { $0.certainty != .aiHypothesis }
            .sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
        // Kilka ustaleń tej samej reguły (np. wiele elementów autostartu) to dla użytkownika JEDNA sprawa – łączymy je z licznikiem.
        var order: [String] = []
        var groups: [String: [Finding]] = [:]
        for f in ranked {
            let key = text(for: f, reclaimable: reclaimable).title
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }
        return order.prefix(limit).map { key in
            let fs = groups[key]!, f = fs[0]
            let (title, body0) = text(for: f, reclaimable: reclaimable)
            let body = fs.count > 1 ? body0 + String(localized: " Dotyczy \(fs.count) elementów.") : body0
            let all = fs.flatMap { $0.actions }
            let allowed = f.actions.filter { a in riskOf(a.tool).map { $0 <= .low } ?? false }
            let why = fs.flatMap { $0.evidenceIDs }.compactMap { evidence[$0] }.prefix(4).map { plain("\($0.label): \($0.value)") }.filter { !$0.isEmpty }
            return Recommendation(id: f.id, title: title, body: body, severity: fs.map { $0.severity }.max() ?? f.severity, why: Array(why), actions: allowed,
                                  needsPro: !all.isEmpty && f.actions.filter { a in riskOf(a.tool).map { $0 <= .low } ?? false }.count < f.actions.count)
        }
    }

    /// Nazwa „po ludzku”: identyfikator pakietu (com.apple.Virtualization.VirtualMachine) → „Virtual Machine”; zwykłe nazwy bez zmian.
    static func friendlyName(_ name: String) -> String {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 3, !name.contains(" "), name.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else { return name }
        var seg = parts[parts.count - 1]
        if ["app", "helper", "agent", "daemon", "service", "xpc"].contains(seg.lowercased()) { seg = parts[parts.count - 2] }
        var out = ""
        var prev: Character?
        for ch in seg {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch); prev = ch
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func text(for f: Finding, reclaimable: UInt64? = nil) -> (title: String, body: String) {
        let subject = f.id.count > f.ruleID.count + 1 ? String(f.id.dropFirst(f.ruleID.count + 1)) : ""
        let app = plain(friendlyName(subject))
        switch f.ruleID {
        case "disk.low":
            let extra = reclaimable.flatMap { $0 > 0 ? String(localized: " Możesz odzyskać ok. \(ByteFormat.string($0)).") : nil } ?? ""
            return (String(localized: "Mało miejsca na dysku"), String(localized: "Dysk jest prawie pełny.\(extra) Warto zwolnić trochę miejsca."))
        case "disk.snapshots":
            return (String(localized: "Część miejsca zajmują kopie zapasowe systemu"), String(localized: "Mac trzyma lokalne kopie (Time Machine). Zwolnią się same, gdy zabraknie miejsca."))
        case "mem.pressure":
            return (String(localized: "Brakuje pamięci operacyjnej"), String(localized: "Mac jest obciążony pamięcią i zwalnia. Zamknięcie nieużywanych aplikacji powinno pomóc."))
        case "mem.swap":
            return (String(localized: "Mac często korzysta z dysku jako pamięci"), String(localized: "To spowalnia pracę. Pomoże zamknięcie dużych aplikacji albo restart."))
        case "cpu.process":
            return (app.isEmpty ? String(localized: "Jedna aplikacja mocno obciąża procesor") : String(localized: "\(app) mocno obciąża procesor"), String(localized: "Mac może się grzać i zwalniać. Jeśli aplikacja nie jest teraz potrzebna, możesz ją zamknąć."))
        case "cpu.system":
            return (String(localized: "Procesor jest mocno obciążony"), String(localized: "Mac pracuje na wysokich obrotach. Poczekaj chwilę – to często chwilowe."))
        case "mem.idle_app":
            return (app.isEmpty ? String(localized: "Nieużywana aplikacja zajmuje dużo pamięci") : String(localized: "\(app) zajmuje dużo pamięci, choć nic nie robi"), String(localized: "Zamknięcie jej odciąży Maca."))
        case "thermal":
            return (String(localized: "Mac jest mocno rozgrzany"), String(localized: "System spowalnia pracę, żeby się schłodzić. Daj mu odpocząć i zadbaj o wentylację."))
        case "battery.health":
            return (String(localized: "Bateria się zużywa"), String(localized: "Pojemność baterii jest już niższa niż na początku. Rozważ wizytę w serwisie, jeśli działa za krótko."))
        case "security.posture":
            return (String(localized: "Warto poprawić zabezpieczenia"), plain(f.title) + String(localized: ". To ustawienie systemu – możesz je włączyć samodzielnie w Ustawieniach."))
        case "startup.items":
            return (String(localized: "Programy uruchamiają się razem z Macem"), String(localized: "Część z nich może być pozostałością po usuniętych aplikacjach. Szczegóły są w trybie Profesjonalnym."))
        case "stability.crashes":
            return (app.isEmpty ? String(localized: "Aplikacja często się zawiesza") : String(localized: "\(app) często się zawiesza"), String(localized: "Pomoże aktualizacja albo ponowna instalacja aplikacji."))
        case "proc.zombies":
            return (String(localized: "Zawieszone procesy w tle"), String(localized: "Zwykle znikają po restarcie Maca."))
        case "sys.uptime":
            return (String(localized: "Mac nie był restartowany od dawna"), String(localized: "Restart odświeża system i zwykle poprawia szybkość."))
        default:
            let t = plain(f.title), b = plain(f.detail)
            return (t.isEmpty ? String(localized: "Coś wymaga uwagi") : t, firstSentence(b))
        }
    }

    private static func firstSentence(_ s: String) -> String {
        guard let r = s.range(of: ". ") else { return s }
        return String(s[..<r.lowerBound]) + "."
    }

    // MARK: Oczyszczanie tekstu z żargonu

    private static let patterns: [NSRegularExpression] = [
        // ścieżki: „/Users/…”, „~/Library/…” (nie „I/O”, „3/4” – musi zaczynać się poza słowem)
        #"(?<![\w])~?/[^\s,;)"'”»]+"#,
        // identyfikatory dowodów i pakietów: „mem.pressure”, „proc.cpu.Opera”, „com.microsoft.Updater”
        #"\b[a-z][a-z0-9_]*(?:\.[A-Za-z0-9_\-]+)+\b"#,
        // PID-y
        #"\(?\b[Pp][Ii][Dd][: ]*\d+\)?"#,
        #"\(\d{3,7}\)"#,
        // Team ID (10 znaków wielkie litery/cyfry)
        #"\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Usuwa ścieżki, identyfikatory dowodów/pakietów, PID-y i Team ID; porządkuje interpunkcję.
    static func plain(_ s: String) -> String {
        var out = s
        for re in patterns { out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "") }
        for (a, b) in [("()", ""), ("( )", ""), (" ,", ","), (" .", "."), ("  ", " "), (": .", "."), (": ,", ",")] {
            while out.contains(a) { out = out.replacingOccurrences(of: a, with: b) }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–—-"))
    }
}
