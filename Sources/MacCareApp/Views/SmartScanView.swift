import SwiftUI
import MacCareCore

/// Smart Scan: ekran główny. Start = „Stan Maca” (bohater + rekomendacje z reguł), skanowanie = animowany przycisk, wynik = kafle 3 + 2.
struct SmartScanView: View {
    @EnvironmentObject private var live: LiveMetrics                                // dane na żywo – przeliczanie tylko tego widoku
    @EnvironmentObject var model: AppModel
    @State private var showAll = false

    var body: some View {
        Group {
            switch model.phase(.smartScan) {
            case .start: if model.viewMode == .simple { SimpleHome() } else { home }
            case .scanning: scanning
            case .result: result
            }
        }
        .task { if model.snapshot == nil { await model.refreshLive(); await model.refreshFindings() } }
    }

    // MARK: Start – stan Maca
    private var home: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                ScrollView { VStack(spacing: 16) { hero; MethodologyCard(assessment: model.assessment) }.padding(.bottom, 8) }
                    .scrollIndicators(.hidden).frame(maxWidth: 420)
                recommendations
            }
            .padding(.horizontal, 36).padding(.top, 28).frame(maxHeight: .infinity)
            VStack(spacing: 8) {
                ScanButton(title: String(localized: "Skanuj"), module: .smartScan) { Task { await model.smartScan() } }
                Text("Smart Scan niczego nie zmienia – tylko sprawdza.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }.padding(.bottom, 26)
        }
    }

    private var hero: some View {
        SurfaceCard(padding: 28, radius: 30) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(model.stateColor.opacity(0.25)).blur(radius: 26).frame(width: 220, height: 220)
                    Circle().stroke(model.stateColor.opacity(0.25), lineWidth: 10).frame(width: 190, height: 190)
                    Circle().trim(from: 0, to: Double(model.assessment?.overall ?? 0) / 100)
                        .stroke(model.stateColor, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 190, height: 190)
                        .shadow(color: model.stateColor.opacity(0.7), radius: 10)
                    VStack(spacing: 2) {
                        Image(systemName: "laptopcomputer").font(.system(size: 62, weight: .light)).symbolRenderingMode(.palette).foregroundStyle(Theme.Palette.text, model.stateColor)
                        Text(model.assessment?.overall.map { "\($0)/100" } ?? "—").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Text(model.snapshot?.modelIdentifier ?? String(localized: "Twój Mac")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
                Text("Stan Maca: \(model.stateLabel)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(model.stateColor).multilineTextAlignment(.center)
                HStack(alignment: .top, spacing: 8) {
                    Text(stateSentence).font(.system(size: 14)).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    InfoButton().environmentObject(model)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Mała pierwsza litera bez psucia skrótów („SIP wyłączony”, „Swap > 50% RAM” zostają; „Dysk prawie pełny” → „dysk prawie pełny”).
    static func lowerFirst(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1, chars[0].isUppercase, !chars[1].isUppercase else { return s }
        return String(chars[0]).lowercased() + String(chars.dropFirst())
    }

    private var stateSentence: String {
        guard let a = model.assessment else { return String(localized: "Zbieram pierwsze pomiary…") }
        guard a.overall != nil else { return String(localized: "Za mało danych, żeby ocenić stan (pokrycie \(Int(a.coverage * 100))%).") }
        let deductions = a.components.flatMap { $0.deductions }.sorted { $0.points > $1.points }
        guard let top = deductions.first else {
            // audyt 2 (3.6): ocena bez potrąceń, a są ostrzeżenia (np. czekająca aktualizacja systemu) – nie mówimy „wszystko dobrze”
            let warnings = model.issueCount(model.findings.filter { $0.severity >= .warning })
            return warnings == 0 ? String(localized: "Wszystkie sprawdzane obszary wyglądają dobrze.")
                                 : String(localized: "Ocena bez potrąceń, ale \(Plural.counted(warnings, one: "sprawa wymaga", few: "sprawy wymagają", many: "spraw wymaga")) uwagi – szczegóły poniżej.")
        }
        return String(localized: "Największy wpływ na ocenę: \(Self.lowerFirst(top.reason)) (−\(top.points) pkt). Kliknij „i”, by zobaczyć dowody.")
    }

    private var recommendations: some View {
        let list = model.findings.filter { $0.certainty != .aiHypothesis }.sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
        let shown = showAll ? list : Array(list.prefix(5))
        return ScrollView {
            VStack(spacing: 12) {
                RecommendationList(findings: shown, limit: 5)
                if list.count > 5 {
                    Button(showAll ? String(localized: "Pokaż mniej") : String(localized: "Pokaż wszystkie (\(list.count))")) { withAnimation(.spring()) { showAll.toggle() } }.buttonStyle(.plain).actionTarget().foregroundStyle(Theme.Palette.textSecondary).padding(.top, 4)
                }
            }
            .padding(.vertical, 4).padding(.trailing, 4)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }

    // MARK: Skanowanie
    private var scanning: some View {
        ModuleStart(module: .smartScan, scanTitle: String(localized: "Skanuj"), scanning: true, stage: model.scanStage, onCancel: { model.cancelScan() }) {}
    }

    // MARK: Wynik – kafle 3 + 2
    /// Treść (nagłówek + kafle) przewija się, gdy okno jest za niskie; główna akcja stoi w pasku przypiętym do dołu, więc zawsze jest w całości widoczna.
    private var result: some View {
        ScrollView { resultContent }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MainActionBar {
                    ScanButton(title: String(localized: "Przejrzyj"), module: .smartScan, help: String(localized: "Otwiera Porządki z wynikami skanu – nic nie jest jeszcze usuwane.")) { model.open(.cleanup) }   // P3-2 (AUD-UI-4): przycisk tylko otwiera Porządki
                }
            }
    }

    private var resultContent: some View {
        VStack(spacing: 18) {
            ResultHeader(module: .smartScan, title: model.scanResult?.isComplete == false ? String(localized: "Skan przerwany – wynik niepełny") : String(localized: "Gotowe. Oto co znaleźliśmy:"),
                         subtitle: model.scanResult?.isComplete == false ? String(localized: "Część lokalizacji nie została sprawdzona. Skan tylko sprawdza – niczego nie zmienia na Macu.") : String(localized: "Skan tylko sprawdza – niczego nie zmienia na Macu.")) { model.restart(.smartScan) }
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    ResultTile(module: .cleanup, number: ByteFormat.string(model.viewMode == .simple ? model.visibleCandidates.reduce(0) { $0 + $1.reclaimableSize } : (model.scanResult?.totalReclaimable ?? 0)),
                               caption: String(localized: "do odzyskania"), note: model.viewMode == .pro ? (cleanupNote ?? Self.reclaimTiming) : Self.reclaimTiming) { model.open(.cleanup) }
                    ResultTile(module: .protection, number: "\(model.issueCount(model.protectionFindings))", caption: Plural.form(model.issueCount(model.protectionFindings), one: "sprawa do sprawdzenia", few: "sprawy do sprawdzenia", many: "spraw do sprawdzenia")) { model.open(.protection) }
                    ResultTile(module: .performance, number: "\(model.issueCount(model.performanceFindings))", caption: Plural.form(model.issueCount(model.performanceFindings), one: "zadanie", few: "zadania", many: "zadań"),
                               note: model.viewMode == .pro ? model.assessment?.overall.map { String(localized: "Ocena stanu: \($0)/100") } : nil) { model.open(.performance) }
                }
                if model.viewMode == .pro { GridRow {
                    ResultTile(module: .files, number: model.snapshot?.bootVolume.map { ByteFormat.string($0.total - $0.availableImportant) } ?? "—", caption: String(localized: "zajęte na dysku"),
                               note: String(localized: "Mapa dysku i największe pliki – zobacz, co zajmuje miejsce")) { model.open(.files) }
                    if let u = model.snapshot?.updates {
                        // P2-10: oczekujące aktualizacje Apple (stan z ostatniego sprawdzenia przez macOS)
                        ResultTile(module: .protection, number: "\(u.pending.count)",
                                   caption: u.pending.isEmpty ? String(localized: "aktualizacji – system aktualny") : Plural.form(u.pending.count, one: "aktualizacja Apple czeka", few: "aktualizacje Apple czekają", many: "aktualizacji Apple czeka"),
                                   note: u.pending.isEmpty ? nil : u.pending.map(\.title).joined(separator: ", ")) { model.open(.protection) }
                    } else { Color.clear.frame(height: 0) }
                    Color.clear.frame(height: 0)
                } }
            }
            .padding(.horizontal, 36)
        }
        .padding(.top, 20).padding(.bottom, 20).padding(.horizontal, 20)
    }

    /// P3-2 (AUD-UI-3): kiedy miejsce faktycznie wraca – nie od razu po przeniesieniu.
    static let reclaimTiming = String(localized: "Miejsce wraca po opróżnieniu Kosza lub kwarantanny (ta czyści się sama po 7 dniach).")

    private var cleanupNote: String? {
        guard let r = model.scanResult else { return nil }
        let alloc = r.candidates.reduce(0) { $0 + $1.allocatedSize }
        guard alloc > r.totalReclaimable * 2 else { return nil }
        return String(localized: "z \(ByteFormat.string(alloc)) zajętych – resztę trzymają migawki lub klony")
    }
}

struct InfoButton: View {
    @EnvironmentObject var model: AppModel
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(Theme.Palette.textSecondary).frame(width: 32, height: 32).contentShape(Rectangle()) }.accessibilityLabel("Więcej informacji")
            .buttonStyle(.plain).help("Z czego wynika ocena")
            .popover(isPresented: $shown, arrowEdge: .bottom) { AssessmentPopover().environmentObject(model).environmentObject(model.live) }
    }
}

struct AssessmentPopover: View {
    @EnvironmentObject private var live: LiveMetrics                                // dane na żywo – przeliczanie tylko tego widoku
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Z czego wynika ocena").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                Text("Metodologia v\(HealthAssessment.methodologyVersion): każdy komponent liczony wyłącznie z pomiarów, brak danych nie podnosi oceny.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                if let a = model.assessment {
                    ForEach(a.components) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(c.title).font(Theme.Typo.headline); Text("waga \(Int(c.weight * 100))%").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary); Spacer()
                                Text(c.score.map(String.init) ?? String(localized: "brak danych")).font(Theme.Typo.metricSmall).foregroundStyle(c.score.map(scoreColor) ?? Theme.Palette.textTertiary) }
                            if let n = c.note { Text(n).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
                            ForEach(c.deductions, id: \.self) { d in
                                HStack(spacing: 8) { Text("−\(d.points) pkt").font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.critical); Text(d.reason).font(Theme.Typo.caption); EvidenceChip(id: d.evidenceID) }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 420, height: 420)
    }
}

/// Karta rekomendacji: ikona w kolorowym kółku, tytuł, opis, dowody i przycisk akcji w prawym dolnym rogu.
struct RecommendationCard: View {
    @EnvironmentObject var model: AppModel
    let finding: Finding

    var body: some View {
        let sev = finding.severity
        SurfaceCard(padding: 16, radius: 22) {
            HStack(alignment: .top, spacing: 14) {
                ZStack { Circle().fill(sev.color.opacity(0.25)); Image(systemName: sev.symbol).foregroundStyle(sev.color) }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(finding.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Palette.text).fixedSize(horizontal: false, vertical: true)
                        CertaintyBadge(certainty: finding.certainty)
                    }
                    Text(finding.detail).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    FlowRow { ForEach(finding.evidenceIDs, id: \.self) { EvidenceChip(id: $0) } }
                    if let a = finding.actions.first {
                        HStack { Spacer()
                            Button(model.readOnly && ["quit_app", "disable_launch_agent"].contains(a.tool) ? String(localized: "Podgląd") : a.label) {
                                Task { await model.propose(ToolCall(name: a.tool, arguments: a.arguments)) }
                            }.buttonStyle(.prominent(.protection))
                        }
                    }
                }
            }
        }
    }
}
