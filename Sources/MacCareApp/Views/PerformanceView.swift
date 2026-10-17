import SwiftUI
import MacCareCore

/// Wydajność: najwięksi konsumenci (procesy użytkownika + licznik niemierzalnych), pamięć, swap, bateria, temperatura.
struct PerformanceView: View {
    @EnvironmentObject private var live: LiveMetrics                                // dane na żywo – przeliczanie tylko tego widoku
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase(.performance) {
        case .start: ModuleStart(module: .performance, scanTitle: String(localized: "Skanuj")) { Task { await model.scanPerformance() } }
        case .scanning: ModuleStart(module: .performance, scanTitle: String(localized: "Skanuj"), scanning: true, stage: model.moduleStage[.performance]) {}
        case .result: result
        }
    }

    private var snap: SystemSnapshot? { model.snapshot }
    private var simple: Bool { model.viewMode == .simple }
    private var groups: [ProcGroupRow] {
        (snap?.appGroups() ?? []).filter { $0.allCurrentUser }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8).map { ProcGroupRow(group: $0) }
    }

    private var result: some View {
        let n = model.issueCount(model.performanceFindings)
        return ScrollView {
            VStack(spacing: 18) {
                ResultHeader(module: .performance, title: n == 0 ? (model.snapshot?.cpu == nil || model.snapshot?.memory == nil ? String(localized: "Zbieram pomiary wydajności…") : String(localized: "Wydajność wygląda dobrze")) : String(localized: "\(Plural.counted(n, one: "zadanie", few: "zadania", many: "zadań")) do rozważenia"),
                             subtitle: simple ? String(localized: "Oto, co najbardziej obciąża Twojego Maca.")
                                              : model.assessment?.overall.map { String(localized: "Ocena stanu: \($0)/100 – z jawną metodologią i dowodami.") }) { model.restart(.performance) }
                HStack(alignment: .top, spacing: 16) {
                    tile(String(localized: "Procesor"), "cpu", snap?.cpu.map { "\(Int($0.totalPercent))%" } ?? "—",
                         simple ? String(localized: "obciążenie procesora") : (snap?.cpu.map { String(localized: "\($0.coreCount) rdzeni") + ($0.loadAverage.first.map { String(format: " · load %.1f", $0) } ?? "") } ?? String(localized: "pomiar…")), spark: model.cpuLive, upper: 100)
                    tile(String(localized: "Pamięć"), "memorychip", snap?.memory.map { "\(Int(Double($0.used) / Double(max($0.total, 1)) * 100))%" } ?? "—",
                         snap?.memory.map { simple ? String(localized: "\(ByteFormat.string($0.used)) z \(ByteFormat.string($0.total)) w użyciu") : String(localized: "\(ByteFormat.string($0.used)) z \(ByteFormat.string($0.total)) · ciśnienie \($0.pressure.label)") } ?? "", spark: model.memLive, upper: 100)
                    if !simple {
                        tile(String(localized: "Swap"), "arrow.left.arrow.right", snap?.memory.map { ByteFormat.string($0.swapUsed) } ?? "—",
                             snap?.memory.map { String(localized: "z \(ByteFormat.string($0.swapTotal)) · skompresowane \(ByteFormat.string($0.compressed))") } ?? "", spark: nil, upper: nil)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    consumers.frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        batteryCard
                        thermalCard
                        ssdCard
                        if !simple { DetailedSensorsCard() }
                    }.frame(width: 330)
                }
                RecommendationList(findings: model.performanceFindings, limit: 3)
            }
            .padding(.horizontal, 36).padding(.vertical, 20)
        }
    }

    private func tile(_ title: String, _ symbol: String, _ big: String, _ caption: String, spark: [Double]?, upper: Double?) -> some View {
        SurfaceCard(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text(big).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(Theme.Palette.text).contentTransition(.numericText())
                Text(caption).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2, reservesSpace: true)
                if let spark, spark.count > 1 { Sparkline(values: spark, color: AppModule.performance.foreground, upper: upper).frame(height: 36) } else { Spacer().frame(height: 36) }
            }
        }
    }

    private var consumers: some View {
        SurfaceCard(radius: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(simple ? String(localized: "Co najbardziej obciąża Maca") : String(localized: "Najwięksi konsumenci")).font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
                if !simple {
                    Text(String(localized: "Procesy użytkownika") + ((snap?.unmeasuredProcessCount ?? 0) > 0 ? String(localized: " · niemierzalnych procesów systemowych: \(snap!.unmeasuredProcessCount!) (bez uprawnień nie widać ich zużycia)") : ""))
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                if groups.isEmpty { Text("Brak danych.").foregroundStyle(Theme.Palette.textSecondary) }
                ForEach(groups) { r in
                    HStack(spacing: 10) {
                        Image(nsImage: model.icon(for: r.group)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(simple ? SimplePresentation.friendlyName(r.group.name) : r.group.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Palette.text).lineLimit(1)
                            Text(simple ? String(localized: "pamięć: \(ByteFormat.string(r.group.memory))") : String(localized: "\(r.group.pids.count) proc. · \(ByteFormat.string(r.group.memory))")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", r.group.cpuPercent)).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text)
                        if !simple { EvidenceChip(id: "proc.cpu.\(r.group.name)") }
                        if !simple, ProcessGuard.canPropose(r.group, ctx: RuleContext()) {
                            Button(model.readOnly ? String(localized: "Podgląd") : String(localized: "Zakończ")) { Task { await model.propose(ToolCall(name: "quit_app", arguments: ["name": .string(r.group.name)])) } }
                                .buttonStyle(.soft).help(model.readOnly ? model.previewHint : "")
                        }
                    }
                }
            }
        }
    }

    private var batteryCard: some View {
        SurfaceCard(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Bateria", systemImage: "battery.75").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                if let b = snap?.battery {
                    Text("\(b.percent)%").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Theme.Palette.text)
                    Text(b.isCharging ? String(localized: "ładowanie") : (b.onAC ? String(localized: "zasilacz") : String(localized: "na baterii"))).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    if simple {
                        let h = b.healthPercent
                        Pill(text: String(localized: "kondycja baterii: ") + (h.map { $0 >= 80 ? String(localized: "dobra") : ($0 >= 60 ? String(localized: "średnia") : String(localized: "słaba")) } ?? String(localized: "nie wiadomo")),
                             color: h.map { $0 >= 80 ? Theme.Palette.ok : ($0 >= 60 ? Theme.Palette.warning : Theme.Palette.critical) } ?? Theme.Palette.textSecondary)
                    } else {
                        // audyt 2 (3.5): kolor wg kondycji (jak w trybie Prostym), brak licznika cykli = „—”, nie „0 cykli”
                        HStack { Pill(text: String(localized: "kondycja \(b.healthPercent.map { "\(Int($0))%" } ?? "—")"),
                                      color: b.healthPercent.map { $0 >= 80 ? Theme.Palette.ok : ($0 >= 60 ? Theme.Palette.warning : Theme.Palette.critical) } ?? Theme.Palette.textSecondary)
                            Pill(text: b.cycleCount.map { String(localized: "\($0) cykli") } ?? String(localized: "cykle: —"), color: Theme.Palette.textSecondary)
                            if let t = b.temperatureC { Pill(text: String(format: "%.0f °C", t), color: Theme.Palette.textSecondary) } }
                        if let c = b.condition { Text("Stan wg systemu: \(c)").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
                        FlowRow { EvidenceChip(id: "bat.health"); EvidenceChip(id: "bat.condition") }
                    }
                } else { Text("Ten Mac nie ma baterii lub system nie udostępnia danych.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
            }
        }
    }

    /// 18.10 (decyzja właściciela): kondycja dysku SSD z dziennika SMART – tylko odczyt.
    private var ssdCard: some View {
        SurfaceCard(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Dysk SSD", systemImage: "internaldrive").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                if let d = snap?.ssd {
                    let bad = d.criticalWarning != 0 || d.availableSpare < d.availableSpareThreshold
                    Text(simple ? Self.plainSSD(d) : String(localized: "zużycie \(d.percentUsed)%")).font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(bad ? Theme.Palette.critical : (d.percentUsed >= 80 || d.mediaErrors > 0 ? Theme.Palette.warning : Theme.Palette.text))
                    if simple {
                        Text(bad ? String(localized: "Dysk zgłasza problem – zrób kopię zapasową.") : String(localized: "Dysk działa prawidłowo."))
                            .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        Text(String(localized: "zapisano \(ByteFormat.string(d.dataWrittenBytes)) · \(d.powerOnHours) h pracy · błędy nośnika: \(d.mediaErrors)"))
                            .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        FlowRow { EvidenceChip(id: "ssd.used"); EvidenceChip(id: "ssd.spare"); EvidenceChip(id: "ssd.errors") }
                    }
                } else {
                    Text("Brak danych SMART – dysk ich nie udostępnia albo odczyt się nie udał.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    static func plainSSD(_ d: SSDHealth) -> String {
        if d.criticalWarning != 0 || d.availableSpare < d.availableSpareThreshold { return String(localized: "wymaga uwagi") }
        if d.percentUsed >= 80 || d.mediaErrors > 0 { return String(localized: "do obserwacji") }
        return String(localized: "dobra kondycja")
    }

    private var thermalCard: some View {
        SurfaceCard(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Temperatura", systemImage: "thermometer.medium").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Text(simple ? Self.plainThermal(snap?.thermal) : (snap?.thermal?.label ?? "—").capitalized).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(Theme.Palette.text)
                if !simple {
                    Text("Stan termiczny systemu. Czujników SMC nie odczytujemy (wymagają prywatnych interfejsów), więc nie pokazujemy temperatur CPU/GPU.")
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    EvidenceChip(id: "thermal.state")
                }
            }
        }
    }
}

extension PerformanceView {
    static func plainThermal(_ t: ThermalLevel?) -> String {
        switch t { case .nominal?: return String(localized: "W normie"); case .fair?: return String(localized: "Lekko podwyższona"); case .serious?: return String(localized: "Wysoka – Mac zwalnia"); case .critical?: return String(localized: "Krytyczna"); case nil: return String(localized: "Nie wiadomo") }
    }
}

struct ProcGroupRow: Identifiable { let group: ProcessGroup; var id: String { group.id } }
