import SwiftUI
import MacCareCore

/// Porządki: start → skanowanie → wynik (siatka „bento” kategorii) → widok szczegółów (lista kategorii + lista elementów).
struct CleanupView: View {
    @EnvironmentObject private var disk: LiveDiskFacts                              // audyt 2 (4.5): tylko liczba migawek, nie pomiary co 2 s
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase(.cleanup) {
            case .start:
                ModuleStart(module: .cleanup, scanTitle: String(localized: "Skanuj")) { Task { await model.scanCleanup() } }
            case .scanning:
                ModuleStart(module: .cleanup, scanTitle: String(localized: "Skanuj"), scanning: true, stage: String(localized: "Sprawdzam znane lokalizacje z listy dozwolonych…"), onCancel: { model.cancelScan() }) {}
            case .result:
                if model.cleanupDetail { CleanupDetail(focus: $model.cleanupFocus, back: { Motion.perform(.spring(response: 0.45, dampingFraction: 0.85)) { model.cleanupDetail = false } }) }
                else { result }
            }
        }
        .onChange(of: model.module) { _, _ in model.cleanupDetail = false }
    }

    private var grouped: [(CleanupCategory, [CleanupCandidate])] {
        Dictionary(grouping: model.visibleCandidates, by: { $0.category })
            .map { ($0.key, $0.value) }
            .sorted { $0.1.reduce(0) { $0 + $1.reclaimableSize } > $1.1.reduce(0) { $0 + $1.reclaimableSize } }
    }

    private func total(_ items: [CleanupCandidate]) -> UInt64 { items.reduce(0) { $0 + $1.reclaimableSize } }
    private func alloc(_ items: [CleanupCandidate]) -> UInt64 { items.reduce(0) { $0 + $1.allocatedSize } }

    private var result: some View {
        let g = grouped
        let snapshots = disk.localSnapshotCount ?? 0                                   // tylko do dopisku „migawek: N” (> 0)
        let simple = model.viewMode == .simple
        return ScrollView {
            VStack(spacing: 18) {
                ResultHeader(module: .cleanup, title: String(localized: "Na Twoim Macu jest \(ByteFormat.string(simple ? model.visibleCandidates.reduce(0) { $0 + $1.reclaimableSize } : (model.scanResult?.totalReclaimable ?? 0))) danych do odzyskania"),
                             subtitle: simple ? String(localized: "Poniżej zobaczysz, co zajmuje miejsce i co można bezpiecznie usunąć. Nic nie zniknie bez Twojej zgody.")
                                              : String(localized: "Zajęte łącznie: \(ByteFormat.string(model.candidates.reduce(0) { $0 + $1.allocatedSize })) – „odzyskiwalne” to część, która realnie wróci po usunięciu (bez bloków trzymanych przez klony i migawki)."),
                             actionTitle: String(localized: "Przejrzyj wszystko")) { openDetail(nil) } onRestart: { model.restart(.cleanup) }
                if g.isEmpty {
                    SurfaceCard { Label("Nie znaleziono nic do usunięcia w znanych lokalizacjach.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.Palette.textSecondary) }
                } else {
                    bento(g, snapshots: snapshots)
                }
                if simple && model.hiddenByModeCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash").foregroundStyle(Theme.Palette.textSecondary)
                        Text(model.hiddenByModeCount == 1 ? String(localized: "1 pozycja wymaga oceny eksperckiej i jest ukryta w trybie Prostym.")
                                                         : String(localized: "\(Plural.counted(model.hiddenByModeCount, one: "pozycja wymaga", few: "pozycje wymagają", many: "pozycji wymaga")) oceny eksperckiej i są ukryte w trybie Prostym.")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                        Button("Przejdź do trybu Profesjonalnego") { model.setViewMode(.pro) }.buttonStyle(.link).foregroundStyle(Theme.Palette.info).actionTarget()
                    }
                }
                if let r = model.scanResult, !r.isComplete {
                    Label("Skan przerwany – wynik niepełny (sprawdzono \(Plural.counted(r.scannedRules, one: "regułę", few: "reguły", many: "reguł"))). „Zacznij od nowa” i „Skanuj” sprawdzą wszystko.", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.warning)
                }
                if let r = model.scanResult, !r.unreadableLocations.isEmpty {
                    Text("Brak dostępu do \(r.unreadableLocations.count) lokalizacji (uprawnienia) – pominięto, nie ukryto.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning)
                }
                if let rep = model.lastReport { ReportCard(report: rep) }
            }
            .padding(.horizontal, 36).padding(.top, 20).padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {                            // główna akcja zawsze widoczna (treść przewija się pod paskiem)
            MainActionBar {
                ScanButton(title: model.cleanupPreviewOnly ? String(localized: "Podgląd") : String(localized: "Wyczyść"), module: .cleanup,
                           disabled: model.selectedCandidates.isEmpty,
                           help: model.cleanupPreviewOnly ? model.previewHint : "") { Task { await model.proposeCleanup() } }
            }
        }
    }

    @ViewBuilder
    private func bento(_ g: [(CleanupCategory, [CleanupCandidate])], snapshots: Int) -> some View {
        let rest = Array(g.dropFirst(1))
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                card(g[0], large: true, snapshots: snapshots).gridCellColumns(2)
                if rest.count > 0 { card(rest[0], large: false, snapshots: snapshots) } else { Color.clear }
            }
            ForEach(Array(stride(from: 1, to: rest.count, by: 3)), id: \.self) { i in
                GridRow {
                    ForEach(0..<3, id: \.self) { j in
                        if i + j < rest.count { card(rest[i + j], large: false, snapshots: snapshots) } else { Color.clear }
                    }
                }
            }
        }
    }

    private func card(_ entry: (CleanupCategory, [CleanupCandidate]), large: Bool, snapshots: Int) -> some View {
        let (cat, items) = entry
        let rec = total(items), al = alloc(items)
        let safe = items.filter { $0.safeToRemove }
        var detail = model.viewMode == .simple ? Plural.elements(items.count) : String(localized: "\(Plural.elements(items.count)) · bezpiecznych: \(safe.count)")
        if model.viewMode == .pro, al > rec * 2, al > 100_000_000 { let snaps = snapshots > 0 ? String(localized: ", migawek: \(snapshots)") : ""; detail += String(localized: " · zajęte \(ByteFormat.string(al)) (resztę trzymają migawki lub klony\(snaps))") }
        return BentoCard(symbol: cat.symbol, module: .cleanup, big: ByteFormat.string(rec), title: cat.label, detail: detail, large: large,
                         // audyt 2 (3.11): opróżnianie Kosza jest poza zakresem Edycji – karta Kosza zawsze „Podgląd” z wyjaśnieniem
                         primaryTitle: (model.cleanupPreviewOnly || cat == .trash) ? String(localized: "Podgląd") : String(localized: "Wyczyść"),
                         primaryHelp: cat == .trash ? String(localized: "Opróżnianie Kosza MacCare tylko pokazuje – opróżnisz go w Finderze (Kosz → Opróżnij).") : (model.cleanupPreviewOnly ? model.previewHint : ""),
                         primaryDisabled: safe.isEmpty && cat != .trash) {
            openDetail(cat)
        } onPrimary: {
            Task { await previewCategory(cat) }
        }
    }

    private func openDetail(_ cat: CleanupCategory?) {
        model.cleanupFocus = cat
        Motion.perform(.spring(response: 0.45, dampingFraction: 0.85)) { model.cleanupDetail = true }
    }

    /// Zaznacza bezpieczne elementy tej kategorii i pokazuje arkusz (podgląd/zatwierdzenie).
    private func previewCategory(_ cat: CleanupCategory) async {
        if cat == .trash { await model.proposeEmptyTrash(); return }
        model.selection = Set(model.candidates.filter { $0.category == cat && $0.safeToRemove }.map { $0.path })
        await model.proposeCleanup()
    }
}

/// Szczegóły: jedna karta, dwie kolumny – lewa lista kategorii (checkbox + suma), prawa lista elementów (ikona, nazwa, rozmiar, checkbox).
struct CleanupDetail: View {
    @EnvironmentObject var model: AppModel
    @Binding var focus: CleanupCategory?
    let back: () -> Void
    @State private var query = ""
    @State private var sort = Sort.size
    enum Sort: String, CaseIterable { case size = "Rozmiar", name = "Nazwa", date = "Data" }

    private var categories: [(CleanupCategory, [CleanupCandidate])] {
        Dictionary(grouping: model.visibleCandidates, by: { $0.category }).map { ($0.key, $0.value) }
            .sorted { $0.1.reduce(0) { $0 + $1.reclaimableSize } > $1.1.reduce(0) { $0 + $1.reclaimableSize } }
    }

    private var items: [CleanupCandidate] {
        var list = model.visibleCandidates.filter { focus == nil || $0.category == focus }
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.owner.localizedCaseInsensitiveContains(query) } }
        switch sort {
        case .size: return list.sorted { $0.reclaimableSize > $1.reclaimableSize }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date: return list.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button(action: back) { Label("Wstecz", systemImage: "chevron.left") }.buttonStyle(.soft)
                Spacer()
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textTertiary); TextField("Szukaj", text: $query).textFieldStyle(.plain) }
                    .padding(.horizontal, 12).frame(width: 240, height: Theme.Metrics.actionHeight + 4).background(Capsule().fill(Theme.Palette.surfaceAlt)).overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 1))
                Text("Sortuj").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                SegmentedSwitch(selection: $sort, options: Array(Sort.allCases), title: { $0.title }, module: .cleanup, width: 270, accessibilityName: String(localized: "Sortuj"))
            }
            SurfaceCard(padding: 0, radius: 24) {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 2) {
                            categoryRow(nil, String(localized: "Wszystko"), "tray.full", model.visibleCandidates)
                            ForEach(categories, id: \.0) { cat, list in categoryRow(cat, cat.label, cat.symbol, list) }
                        }.padding(10)
                    }
                    .frame(width: 340)
                    Rectangle().fill(Theme.Palette.hairline).frame(width: 1)
                    List(items) { c in CleanupItemRow(candidate: c) }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zaznaczono \(model.selectedCandidates.count) · odzyskasz ok. \(ByteFormat.string(model.selectedReclaimable))").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                    Text(model.cleanupPreviewOnly ? model.previewHint : String(localized: "Zaznaczone pozycje trafią do Kosza – miejsce wróci po jego opróżnieniu w Finderze."))
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                ScanButton(title: model.cleanupPreviewOnly ? String(localized: "Podgląd") : String(localized: "Wyczyść"), module: .cleanup, disabled: model.selectedCandidates.isEmpty) { Task { await model.proposeCleanup() } }
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 8)
    }

    private func categoryRow(_ cat: CleanupCategory?, _ title: String, _ symbol: String, _ list: [CleanupCandidate]) -> some View {
        let selectable = list.filter { !$0.ownerRunning && $0.removal != .permanent }
        let allOn = !selectable.isEmpty && selectable.allSatisfy { model.selection.contains($0.path) }
        return HStack(spacing: 10) {
            Button { setAll(selectable, !allOn) } label: { Image(systemName: allOn ? "checkmark.square.fill" : "square").font(.system(size: Theme.Metrics.checkboxSize)).foregroundStyle(AppModule.cleanup.foreground).frame(width: Theme.Metrics.checkboxHitArea, height: Theme.Metrics.checkboxHitArea).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(allOn ? String(localized: "Odznacz wszystkie") : String(localized: "Zaznacz wszystkie"))
            Image(systemName: symbol).frame(width: 20).foregroundStyle(AppModule.cleanup.foreground)
            Text(title).font(Theme.Typo.body).foregroundStyle(Theme.Palette.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(ByteFormat.string(list.reduce(0) { $0 + $1.reclaimableSize })).font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(focus == cat ? Theme.Palette.surfaceAlt : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { focus = cat }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(focus == cat ? [.isButton, .isSelected] : .isButton)          // audyt 3: wybór kategorii także przez VoiceOver i klawiaturę
        .accessibilityAction(named: Text("Pokaż elementy kategorii")) { focus = cat }
    }

    private func setAll(_ list: [CleanupCandidate], _ on: Bool) {
        if on { model.selection.formUnion(list.map { $0.path }) } else { model.selection.subtract(list.map { $0.path }) }
    }
}

struct CleanupItemRow: View {
    @EnvironmentObject private var disk: LiveDiskFacts                              // audyt 2 (4.5): tylko liczba migawek, nie pomiary co 2 s
    @EnvironmentObject var model: AppModel
    let candidate: CleanupCandidate
    /// Audyt 3: ogólni „właściciele” z katalogu reguł są tłumaczeni; nazwy aplikacji – bez zmian (identyfikator porównywany w kodzie zostaje polski).
    static func ownerLabel(_ owner: String) -> String {
        switch owner { case "różne": return String(localized: "różne"); case "użytkownik": return String(localized: "użytkownik"); default: return owner }
    }

    var body: some View {
        let c = candidate
        let simple = model.viewMode == .simple
        let shownName = simple ? SimplePresentation.friendlyName(c.name) : c.name
        HStack(alignment: .center, spacing: 12) {
            if c.removal == .permanent { Image(systemName: "lock.fill").frame(width: 18).foregroundStyle(Theme.Palette.textTertiary) }
            else {
                Toggle("", isOn: Binding(get: { model.selection.contains(c.path) }, set: { _ in model.toggle(c) })).labelsHidden().toggleStyle(.largeCheckbox).disabled(c.ownerRunning).opacity(c.ownerRunning ? 0.5 : 1)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.path)).resizable().frame(width: 30, height: 30).opacity(c.ownerRunning ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(shownName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Palette.text).lineLimit(1)
                    if !simple || (c.owner != "różne" && c.owner != shownName) { Text(Self.ownerLabel(c.owner)).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
                }
                Text(simple ? SimplePresentation.plain(c.description) : c.description).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                HStack(spacing: 4) {
                    if !simple { RiskBadge(risk: c.risk) }
                    if c.ownerRunning { Pill(text: String(localized: "aplikacja uruchomiona"), color: Theme.Palette.critical, symbol: "bolt.fill") }
                    else if c.safeToRemove { Pill(text: String(localized: "bezpieczne"), color: Theme.Palette.ok, symbol: "checkmark.circle.fill") }
                    else if !simple { Pill(text: String(localized: "do przejrzenia"), color: Theme.Palette.warning, symbol: "eye") }
                    if !simple { Pill(text: c.removal == .permanent ? String(localized: "trwale") : String(localized: "Kosz"), color: c.removal == .permanent ? Theme.Palette.critical : Theme.Palette.info) }   // audyt 3: dziś każda droga poza „trwale” to Kosz (kwarantanna wyłączona)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(c.reclaimableSize)).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text)
                if !simple && c.allocatedSize > c.reclaimableSize * 2 && c.allocatedSize > 1_000_000 {
                    Label("zajęte \(ByteFormat.string(c.allocatedSize))", systemImage: "info.circle").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.info)
                        .help("Odzyskiwalne: \(ByteFormat.string(c.reclaimableSize)) z \(ByteFormat.string(c.allocatedSize)). Resztę trzymają klony APFS, twarde dowiązania lub lokalne migawki Time Machine (obecnie: \(disk.localSnapshotCount.map { String($0) } ?? String(localized: "nie wiadomo"))); wróci po ich wygaśnięciu (zwykle do 24 godz.).")
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu { Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.path)]) }
                       if !simple { Text(tildePath(c.path)) } }
        .help(simple ? "" : tildePath(c.path))
    }
}

struct ReportCard: View {
    let report: OperationReport
    var body: some View {
        SurfaceCard(padding: 14, radius: 18) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                // P1-6: trzy stany – sukces, częściowo (ostrzeżenie, nie sukces), porażka
                Image(systemName: report.success ? "checkmark.circle.fill" : (report.partial ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")).font(.system(size: 20))
                    .foregroundStyle(report.success ? Theme.Palette.ok : (report.partial ? Theme.Palette.warning : Theme.Palette.critical))
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.title).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                    Text(report.message).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                    if let est = report.estimatedBytes { Text("Szacunek przed operacją: \(ByteFormat.string(est))").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
                    if let d = report.measuredDelta {
                        Text("Zmierzona zmiana wolnego miejsca: \(d >= 0 ? "+" : "−")\(ByteFormat.string(UInt64(abs(d))))").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text)
                    }
                    if let n = report.note { Text(n).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
}
