import SwiftUI
import MacCareCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Historia").font(Theme.Typo.largeTitle).foregroundStyle(Theme.Palette.text)
                        Text("Zmierzone odzyskane miejsce łącznie: \(model.measuredReclaimedTotal >= 0 ? "" : "−")\(ByteFormat.string(UInt64(abs(model.measuredReclaimedTotal)))) (suma pomiarów po operacjach, nie deklaracji)")
                            .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                }
                if let problem = model.historyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SegmentedSwitch(selection: $model.historyTab, options: Array(HistoryTab.allCases), title: { $0.title }, module: .history, width: 560, accessibilityName: String(localized: "Sekcja historii"))
            }
            .padding(Theme.Space.xl)
            Divider()
            Group {
                switch model.historyTab {
                case .scans: scansList
                case .operations: operationsList
                case .measurements: measurementsList
                case .quarantine: quarantineList
                }
            }
        }
        .pageBackground()
        .navigationTitle("Historia")
        .onAppear { model.reloadHistory() }
    }

    // MARK: Pomiary przed/po (F22)
    private var measurementsList: some View {
        List {
            if model.benchmarks.isEmpty {
                EmptyState(symbol: "gauge.with.dots.needle.33percent", title: String(localized: "Brak pomiarów"),
                           detail: String(localized: "Pomiar przed i po wykonuje się przy każdym przeniesieniu do Kosza w trybie Edycja."))
            }
            ForEach(model.benchmarks) { c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Theme.Palette.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.operation).font(Theme.Typo.body.weight(.medium)).foregroundStyle(Theme.Palette.text)
                            Text(String(localized: "przed: \(c.before.takenAt.formatted(date: .abbreviated, time: .shortened)) · po: \(c.after.takenAt.formatted(date: .abbreviated, time: .shortened))"))
                                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Pill(text: c.overall.label, color: Self.verdictColor(c.overall))
                        Button("Zmierz ponownie teraz") { Task { await model.remeasure(c.id) } }.buttonStyle(.soft)
                            .help(String(localized: "Nowy pomiar „po” – np. po opróżnieniu Kosza, bo dopiero wtedy wraca miejsce na dysku"))
                    }
                    ForEach(c.metrics.filter { $0.verdict != .insufficientData }, id: \.metric) { m in
                        Text("\(m.metric.label): \(m.metric.format(m.beforeMean)) → \(m.metric.format(m.afterMean)) · \(Self.verdictText(c, m))")
                            .font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary).padding(.leading, 34)
                    }
                    if !c.conditionWarnings.isEmpty {
                        Text(String(localized: "Zastrzeżenia: ") + c.conditionWarnings.joined(separator: "; ")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning).padding(.leading, 34)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
    }

    static let backgroundLabel = String(localized: "tło – nie wlicza się do oceny")
    static func verdictText(_ c: BenchmarkComparison, _ m: MetricComparison) -> String { c.isDecisive(m.metric) ? m.verdict.label : backgroundLabel }

    static func verdictColor(_ v: EffectVerdict) -> Color {
        switch v { case .improved: return Theme.Palette.ok; case .worsened: return Theme.Palette.warning; case .noMeasurableEffect, .insufficientData: return Theme.Palette.textSecondary }
    }

    // MARK: Skany
    private var scansList: some View {
        List {
            if model.scans.isEmpty { EmptyState(symbol: "magnifyingglass", title: String(localized: "Brak skanów"), detail: String(localized: "Uruchom Smart Scan w Panelu lub skan w Czyszczeniu.")) }
            ForEach(model.scans) { s in
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: s.kind == "smart" ? "wand.and.stars" : "sparkles").foregroundStyle(Theme.Palette.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.scanTitle(s.kind)).font(Theme.Typo.body.weight(.medium)).foregroundStyle(Theme.Palette.text)
                        Text(s.at.formatted(date: .abbreviated, time: .standard)).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    if let h = s.health { Pill(text: String(localized: "ocena \(h)"), color: scoreColor(h)) }
                    Pill(text: String(localized: "ustaleń: \(s.findings)"), color: Theme.Palette.textSecondary)
                    Pill(text: String(localized: "do odzyskania \(ByteFormat.string(s.reclaimable))"), color: Theme.Palette.info)
                }
                .padding(.vertical, 3)
            }
        }
        .scrollContentBackground(.hidden)
    }

    static func scanTitle(_ kind: String) -> String {
        switch kind { case "smart": return "Smart Scan"; case "cleanup": return String(localized: "Skan czyszczenia"); case "cleanup.partial": return String(localized: "Skan czyszczenia (kategoria)"); default: return kind }
    }

    // MARK: Dziennik operacji (audyt)
    private var operationsList: some View {
        List {
            if model.operations.isEmpty { EmptyState(symbol: "list.bullet.rectangle", title: String(localized: "Dziennik jest pusty"), detail: String(localized: "Każda próba operacji – także odrzucona lub anulowana – zostawia tu ślad.")) }
            ForEach(model.operations) { o in
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Pill(text: Self.outcomeLabel(o.outcome), color: Self.outcomeColor(o.outcome)).frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.toolTitle(o.tool)).font(Theme.Typo.body.weight(.medium)).foregroundStyle(Theme.Palette.text)
                        Text(o.message).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(o.at.formatted(date: .abbreviated, time: .standard)).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                        Text("\(o.origin.rawValue) · \(o.mode.label)").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .scrollContentBackground(.hidden)
    }

    static func toolTitle(_ t: String) -> String {
        switch t {
        case "quarantine_cleanup_items": return String(localized: "Przeniesienie do kwarantanny / Kosza")
        case "trash_cleanup_items": return String(localized: "Porządki – przeniesienie do Kosza")
        case "uninstall_app_to_trash": return String(localized: "Odinstalowanie aplikacji do Kosza")
        case "trash_app_leftovers": return String(localized: "Pozostałości po aplikacjach do Kosza")
        case "empty_trash": return String(localized: "Opróżnienie Kosza")
        case "restore_from_quarantine": return String(localized: "Przywrócenie z kwarantanny")
        case "purge_quarantine": return String(localized: "Opróżnienie kwarantanny")
        case "quit_app": return String(localized: "Zamknięcie aplikacji")
        case "disable_launch_agent": return String(localized: "Wyłączenie autostartu")
        case "flush_dns_cache": return String(localized: "Czyszczenie pamięci DNS")
        case "reindex_spotlight": return String(localized: "Przebudowa indeksu Spotlight")
        case "set_execution_mode": return String(localized: "Zmiana trybu wykonania (Tylko odczyt ↔ Edycja)")
        case "trash_selected": return String(localized: "Przeniesienie zaznaczonych plików do Kosza")
        default: return t
        }
    }
    static func outcomeLabel(_ o: AuditRecord.Outcome) -> String {
        switch o {
        case .executed: return String(localized: "wykonano"); case .failed: return String(localized: "błąd"); case .rejectedValidation: return String(localized: "odrzucono (walidacja)"); case .forbidden: return String(localized: "zabronione")
        case .pendingApproval: return String(localized: "czeka na zgodę"); case .approved: return String(localized: "zatwierdzono"); case .declined: return String(localized: "anulowano")
        }
    }
    static func outcomeColor(_ o: AuditRecord.Outcome) -> Color {
        switch o {
        case .executed, .approved: return Theme.Palette.ok; case .failed, .forbidden, .rejectedValidation: return Theme.Palette.critical
        case .pendingApproval: return Theme.Palette.warning; case .declined: return Theme.Palette.textSecondary
        }
    }

    // MARK: Kwarantanna
    private var quarantineList: some View {
        VStack(spacing: 0) {
            let info = HStack(spacing: Theme.Space.m) {
                Text("\(Plural.elements(model.quarantineEntries.count)) · \(ByteFormat.string(model.quarantine.totalSize))").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text("Automatyczne usunięcie po 7 dniach").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            let actions = HStack(spacing: 10) {
                Button(model.readOnly ? String(localized: "Podgląd przywrócenia") : String(localized: "Przywróć zaznaczone")) { Task { await model.proposeRestore(ids: Array(chosen)) } }.disabled(chosen.isEmpty)
                Button(model.readOnly ? String(localized: "Podgląd usunięcia zaznaczonych") : String(localized: "Usuń zaznaczone trwale…"), role: .destructive) { Task { await model.proposePurge(ids: chosen) } }.disabled(chosen.isEmpty)
                Button(model.readOnly ? String(localized: "Podgląd opróżnienia kwarantanny") : String(localized: "Opróżnij całą kwarantannę…"), role: .destructive) { Task { await model.proposePurge(ids: nil) } }.disabled(model.quarantineEntries.isEmpty)
            }
            .buttonStyle(.soft).fixedSize()                                    // etykiety w jednej linii; w wąskim oknie akcje przechodzą pod informację
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) { info; Spacer(minLength: 12); actions }
                VStack(alignment: .leading, spacing: 10) { info; actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.m)
            Divider()
            List {
                if model.quarantineEntries.isEmpty { EmptyState(symbol: "tray", title: String(localized: "Kwarantanna jest pusta"), detail: String(localized: "Elementy przeniesione przez Czyszczenie pojawią się tutaj i będzie można je przywrócić.")) }
                ForEach(model.quarantineEntries) { e in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Toggle("", isOn: Binding(get: { chosen.contains(e.id) }, set: { if $0 { chosen.insert(e.id) } else { chosen.remove(e.id) } }))
                            .labelsHidden().toggleStyle(.largeCheckbox)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((e.originalPath as NSString).lastPathComponent).font(Theme.Typo.body.weight(.medium)).foregroundStyle(Theme.Palette.text)
                            Text(tildePath(e.originalPath)).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                            let left = max(0, 7 - Int(Date().timeIntervalSince(e.quarantinedAt) / 86400))
                            Text("przeniesiono \(e.quarantinedAt.formatted(date: .abbreviated, time: .shortened)) · pozostało \(left) dn. do automatycznego usunięcia")
                                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Text(ByteFormat.string(e.size)).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text)
                        Button(model.readOnly ? String(localized: "Podgląd") : String(localized: "Przywróć")) { Task { await model.proposeRestore(ids: [e.id]) } }.buttonStyle(.soft)
                    }
                    .padding(.vertical, 3)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
