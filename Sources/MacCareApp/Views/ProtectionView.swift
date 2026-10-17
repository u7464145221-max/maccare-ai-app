import SwiftUI
import MacCareCore

/// Ochrona: stan zabezpieczeń systemu, audyt autostartu, podpisy programów, porty nasłuchujące, raporty awarii.
/// Tylko odczyt i dowody – MacCare niczego nie wyłącza ani nie włącza.
struct ProtectionView: View {
    @EnvironmentObject private var live: LiveMetrics                                // dane na żywo – przeliczanie tylko tego widoku
    @EnvironmentObject var model: AppModel
    @State private var tab = Tab.overview
    enum Tab: String, CaseIterable { case overview = "Przegląd", startup = "Autostart", ports = "Porty", crashes = "Awarie" }

    var body: some View {
        switch model.phase(.protection) {
        case .start:
            ModuleStart(module: .protection, scanTitle: String(localized: "Skanuj")) { Task { await model.scanProtection() } }
        case .scanning:
            ModuleStart(module: .protection, scanTitle: String(localized: "Skanuj"), scanning: true, stage: model.moduleStage[.protection]) {}
        case .result:
            result
        }
    }

    private var snap: SystemSnapshot? { model.snapshot }
    private var items: [StartupItem] { (snap?.startupItems ?? []).filter { !$0.isApple } }
    // Audyt 2 (3.4): brak danych ≠ „0”/„brak” – rozróżnienie w kartach, listach i nagłówku.
    private var startupKnown: Bool { snap?.startupItems != nil }
    private var portsKnown: Bool { snap?.security?.portsRead == true }
    private var crashesKnown: Bool { snap?.crashes != nil }
    private var somethingUnknown: Bool { !startupKnown || !portsKnown || !crashesKnown }
    static let unknownValue = "—"
    private var issueCount: Int { model.issueCount(model.protectionFindings) }
    private var simple: Bool { model.viewMode == .simple }

    private var result: some View {
        ScrollView {
            VStack(spacing: 18) {
                ResultHeader(module: .protection, title: issueCount == 0 ? (somethingUnknown ? String(localized: "Nic niepokojącego w odczytanych danych – części nie udało się odczytać") : String(localized: "Nic niepokojącego nie znaleziono")) : Plural.counted(issueCount, one: "sprawa do sprawdzenia", few: "sprawy do sprawdzenia", many: "spraw do sprawdzenia"),
                             subtitle: simple ? String(localized: "Sprawdziliśmy najważniejsze zabezpieczenia Twojego Maca. MacCare niczego nie zmienia.")
                                              : String(localized: "Pokazujemy fakty i dowody. MacCare niczego nie wyłącza ani nie usuwa.")) { model.restart(.protection) }
                if !simple { SegmentedSwitch(selection: $tab, options: Tab.allCases, title: { $0.title }, module: .protection, width: 460, accessibilityName: String(localized: "Sekcja ochrony")) }
                switch simple ? Tab.overview : tab {
                case .overview: overview
                case .startup: startup
                case .ports: ports
                case .crashes: crashes
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 20)
        }
    }

    // MARK: Przegląd
    private var overview: some View {
        VStack(spacing: 16) {
            SurfaceCard(radius: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Stan zabezpieczeń systemu").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                    if let p = snap?.security, simple {
                        row(String(localized: "Ochrona systemu"), p.sip, ev: nil)
                        row(String(localized: "Kontrola pobranych aplikacji"), p.gatekeeper, ev: nil)
                        row(String(localized: "Szyfrowanie dysku"), p.fileVault, ev: nil)
                        row(String(localized: "Zapora sieciowa"), p.firewall, ev: nil)
                        row(String(localized: "Automatyczne aktualizacje"), p.autoUpdateCheck, ev: nil)
                    } else if let p = snap?.security {
                        row(String(localized: "Ochrona integralności systemu (SIP)"), p.sip, ev: "sec.sip")
                        row(String(localized: "Gatekeeper"), p.gatekeeper, ev: "sec.gatekeeper")
                        row(String(localized: "FileVault (szyfrowanie dysku)"), p.fileVault, ev: "sec.filevault")
                        row(String(localized: "Zapora aplikacji"), p.firewall, ev: "sec.firewall")
                        row(String(localized: "Tryb ukryty zapory"), p.firewallStealth, ev: nil, optional: true)
                        row(String(localized: "Automatyczne sprawdzanie aktualizacji"), p.autoUpdateCheck, ev: nil)
                        HStack { Text("XProtect (sygnatury)").foregroundStyle(Theme.Palette.textSecondary); Spacer(); Text(p.xprotectVersion.map { String(localized: "wersja \($0)") } ?? String(localized: "brak danych")).foregroundStyle(Theme.Palette.text) }
                        HStack { Text("XProtect Remediator").foregroundStyle(Theme.Palette.textSecondary); Spacer(); Text(p.xprotectRemediatorVersion.map { String(localized: "wersja \($0)") } ?? String(localized: "brak danych")).foregroundStyle(Theme.Palette.text) }
                        HStack { Text("Pełny dostęp do dysku dla MacCare").foregroundStyle(Theme.Palette.textSecondary); Spacer()
                            Text(p.fullDiskAccessGranted.map { $0 ? String(localized: "przyznany") : String(localized: "brak (opcjonalny)") } ?? String(localized: "nie wiadomo")).foregroundStyle(Theme.Palette.text) }
                    } else { Text("Brak danych – uruchom skan.").foregroundStyle(Theme.Palette.textSecondary) }
                }.font(Theme.Typo.body)
            }
            if !simple { HStack(alignment: .top, spacing: 16) {
                summaryCard("power", String(localized: "Autostart"), startupKnown ? "\(items.count)" : Self.unknownValue, Plural.form(items.count, one: "element spoza Apple", few: "elementy spoza Apple", many: "elementów spoza Apple"),
                            String(localized: "osierocone: \(items.filter { $0.programMissing }.count) · lokalne narzędzia bez podpisu: \(items.filter { $0.hasUntrustedSignature && !$0.programMissing && $0.isFromLocalTools(home: model.home) }.count)")) { tab = .startup }
                summaryCard("network", String(localized: "Otwarte porty"), portsKnown ? "\(snap?.security?.listeningExternalPorts.count ?? 0)" : Self.unknownValue, portsKnown ? String(localized: "usług nasłuchuje z sieci") : String(localized: "nie udało się odczytać"),
                            String(localized: "dolna granica – bez uprawnień widać tylko procesy użytkownika")) { tab = .ports }
                summaryCard("exclamationmark.bubble", String(localized: "Awarie (14 dni)"), crashesKnown ? "\(snap?.crashes?.reduce(0) { $0 + $1.count } ?? 0)" : Self.unknownValue, crashesKnown ? String(localized: "zgłoszeń") : String(localized: "nie udało się odczytać"),
                            String(localized: "\(snap?.crashes?.count ?? 0) różnych programów")) { tab = .crashes }
            } }
            findingsList
        }
    }

    private func row(_ title: String, _ state: ToggleState, ev: String?, optional: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.Palette.textSecondary)
            if let ev, !simple { EvidenceChip(id: ev) }
            Spacer()
            let (text, color): (String, Color) = {
                switch state {
                case .enabled: return (String(localized: "włączone"), Theme.Palette.ok)
                case .disabled: return (String(localized: "wyłączone"), optional ? Theme.Palette.textSecondary : Theme.Palette.warning)   // opcjonalne (tryb ukryty zapory) – bez ostrzeżenia
                case .unknown: return (String(localized: "nie wiadomo"), Theme.Palette.textTertiary)
                }
            }()
            Pill(text: text, color: color)
        }
    }

    private func summaryCard(_ symbol: String, _ title: String, _ big: String, _ caption: String, _ note: String, action: @escaping () -> Void) -> some View {
        SurfaceCard(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text(big).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(Theme.Palette.text)
                Text(caption).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                Text(note).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Przejrzyj", action: action).buttonStyle(.soft) }
            }
        }
    }

    private var findingsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.protectionFindings.isEmpty { Text(simple ? String(localized: "Co warto sprawdzić") : String(localized: "Ustalenia")).font(Theme.Typo.title).foregroundStyle(Theme.Palette.text).frame(maxWidth: .infinity, alignment: .leading) }
            RecommendationList(findings: model.protectionFindings, limit: 3, emptyText: String(localized: "Nic niepokojącego nie znaleziono."))
        }
    }

    // MARK: Autostart
    private var startup: some View {
        SurfaceCard(padding: 0, radius: 24) {
            VStack(spacing: 0) {
                if items.isEmpty { Text(startupKnown ? String(localized: "Brak elementów autostartu spoza Apple.") : String(localized: "Listy autostartu jeszcze nie odczytano albo odczyt się nie udał.")).padding(20).foregroundStyle(Theme.Palette.textSecondary) }
                ForEach(items.sorted { ($0.programMissing ? 0 : 1, $0.label) < ($1.programMissing ? 0 : 1, $1.label) }) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: i.programMissing ? "questionmark.folder" : "power").foregroundStyle(i.programMissing ? Theme.Palette.warning : AppModule.protection.foreground).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(i.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Palette.text)
                            Text(i.program ?? "—").font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 4) {
                                Pill(text: i.scope.label, color: Theme.Palette.textSecondary)
                                Pill(text: i.signature.label, color: i.signature.isTrusted ? Theme.Palette.ok : (i.programMissing ? Theme.Palette.warning : Theme.Palette.textSecondary))
                                if let t = i.signerName { Pill(text: t, color: Theme.Palette.textSecondary) }
                                if i.keepAlive { Pill(text: "KeepAlive", color: Theme.Palette.info) }
                                if let l = i.isLoaded { Pill(text: l ? String(localized: "załadowany") : String(localized: "niezaładowany"), color: l ? Theme.Palette.ok : Theme.Palette.textSecondary) }
                            }
                        }
                        Spacer()
                        if i.scope == .userAgent {
                            Button(model.readOnly ? String(localized: "Podgląd wyłączenia") : String(localized: "Wyłącz…")) { Task { await model.propose(ToolCall(name: "disable_launch_agent", arguments: ["label": .string(i.label)])) } }
                                .buttonStyle(.soft).help(model.readOnly ? model.previewHint : "")
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    Divider().opacity(0.3)
                }
            }
        }
    }

    // MARK: Porty
    private var ports: some View {
        SurfaceCard(radius: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nasłuchujące porty dostępne z sieci").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                Text("Dolna granica: bez uprawnień administratora widać wyłącznie procesy bieżącego użytkownika. Połączenia lokalne (127.0.0.1) pomijamy.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                let p = snap?.security?.listeningExternalPorts ?? []
                if p.isEmpty { if portsKnown { Label("Brak usług użytkownika dostępnych z sieci.", systemImage: "checkmark.seal").foregroundStyle(Theme.Palette.textSecondary) } else { Label("Nie udało się odczytać listy portów – to nie znaczy, że żaden nie jest otwarty.", systemImage: "questionmark.circle").foregroundStyle(Theme.Palette.warning) } }
                ForEach(p, id: \.self) { Text($0).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.text).textSelection(.enabled) }
            }
        }
    }

    // MARK: Awarie
    private var crashes: some View {
        SurfaceCard(radius: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Raporty awarii z ostatnich 14 dni").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                let c = snap?.crashes ?? []
                if c.isEmpty { if crashesKnown { Label("Brak raportów.", systemImage: "checkmark.seal").foregroundStyle(Theme.Palette.textSecondary) } else { Label("Nie udało się odczytać raportów awarii – to nie znaczy, że ich nie ma.", systemImage: "questionmark.circle").foregroundStyle(Theme.Palette.warning) } }
                ForEach(c, id: \.process) { g in
                    HStack {
                        Image(systemName: "exclamationmark.bubble").foregroundStyle(Theme.Palette.warning)
                        VStack(alignment: .leading) { Text(g.process).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Palette.text)
                            Text("\(g.count)× · \(g.kinds.joined(separator: ", ")) · ostatni \(g.lastDate.formatted(date: .abbreviated, time: .shortened))").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
                        Spacer(); EvidenceChip(id: "crash.\(g.process)")
                    }
                }
            }
        }
    }
}
