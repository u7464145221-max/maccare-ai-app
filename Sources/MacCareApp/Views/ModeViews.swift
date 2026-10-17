import SwiftUI
import MacCareCore
import MacCareSystem

// MARK: - Przełącznik trybu

/// Przełącznik Prosty / Profesjonalny (pasek u góry i Ustawienia). Zmiana jest natychmiastowa, bez restartu.
struct ViewModeSwitch: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SegmentedSwitch(selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) }), options: Array(ViewMode.allCases), title: { $0.label },
                        module: model.module, width: 280, accessibilityName: String(localized: "Tryb widoku"))
            .help("Prosty: najważniejsze rzeczy bez żargonu. Profesjonalny: pełne dane, dowody i szczegóły techniczne.")
    }
}

/// Podpowiedź po zablokowaniu ryzykownej operacji w trybie Prostym.
struct ProModeHintBar: View {
    @EnvironmentObject var model: AppModel
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.Palette.info)
            Text(text).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.text)
            Button("Przejdź do trybu Profesjonalnego") { model.setViewMode(.pro); model.proModeHint = nil }.buttonStyle(.soft)
            Spacer()
            Button { model.proModeHint = nil } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Theme.Palette.textSecondary).help("Zamknij").accessibilityLabel("Zamknij podpowiedź")
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, 6)
        .background(Theme.Palette.surfaceAlt)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
    }
}

// MARK: - Prosty: ekran startowy i rekomendacje

extension SimplePresentation.Status {
    var color: Color { switch self { case .ok: return Theme.Palette.ok; case .attention: return Theme.Palette.warning; case .urgent: return Theme.Palette.critical } }
    var sentence: String {
        switch self { case .ok: return String(localized: "Twój Mac działa dobrze."); case .attention: return String(localized: "Kilka rzeczy warto sprawdzić."); case .urgent: return String(localized: "Coś wymaga pilnej uwagi.") }
    }
}

struct SimpleHome: View {
    @EnvironmentObject private var live: LiveMetrics                                // dane na żywo – przeliczanie tylko tego widoku
    @EnvironmentObject var model: AppModel

    var body: some View {
        let status = SimplePresentation.status(assessment: model.assessment, findings: model.findings)
        let all = model.simpleRecommendations(model.findings, limit: 10_000).count          // audyt 2 (3.8): te same scalone karty, które widać wyżej
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    hero(status)
                    RecommendationList(findings: model.findings, limit: 3, emptyText: String(localized: "Nic nie wymaga uwagi."))
                    if all > 3 {
                        Text(all - 3 == 1 ? String(localized: "Jest jeszcze 1 mniej ważna sprawa. Zobaczysz ją po skanie albo w trybie Profesjonalnym.")
                                          : String(localized: "Jest jeszcze \(Plural.counted(all - 3, one: "mniej ważna sprawa", few: "mniej ważne sprawy", many: "mniej ważnych spraw")). Zobaczysz je po skanie albo w trybie Profesjonalnym."))
                            .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: 760).padding(.horizontal, 36).padding(.top, 28).frame(maxWidth: .infinity)
            }
            VStack(spacing: 8) {
                ScanButton(title: String(localized: "Skanuj"), module: .smartScan) { Task { await model.smartScan() } }
                Text("Smart Scan niczego nie zmienia – tylko sprawdza.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }.padding(.vertical, 18)
        }
    }

    private func hero(_ status: SimplePresentation.Status?) -> some View {
        let color = status?.color ?? Theme.Palette.textSecondary
        return SurfaceCard(padding: 26, radius: 24) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().fill(color.opacity(0.16))
                    Image(systemName: status?.symbol ?? "hourglass").font(.system(size: 46, weight: .semibold)).foregroundStyle(color)
                }.frame(width: 96, height: 96).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status?.word ?? String(localized: "Zbieram pomiary…")).font(.system(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    Text(status?.sentence ?? String(localized: "Za chwilę powiem, jak się czuje Twój Mac.")).font(.system(size: 15)).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lista rekomendacji: Prosty – prostym językiem (max `limit`, „Dlaczego?”, bez identyfikatorów); Profesjonalny – pełne karty z dowodami.
struct RecommendationList: View {
    @EnvironmentObject var model: AppModel
    let findings: [Finding]
    var limit = 3
    var emptyText = String(localized: "Nic nie wymaga uwagi.")

    var body: some View {
        if model.viewMode == .simple {
            let recs = model.simpleRecommendations(findings, limit: limit)
            if recs.isEmpty { SurfaceCard { Label(emptyText, systemImage: "checkmark.seal.fill").foregroundStyle(Theme.Palette.textSecondary) } }
            ForEach(recs) { SimpleRecommendationCard(rec: $0) }
        } else {
            if findings.isEmpty { SurfaceCard { Label("Nic nie wymaga uwagi. Brak wniosku nie oznacza braku problemu – sprawdzane są tylko znane reguły.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.Palette.textSecondary) } }
            ForEach(findings.sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }) { RecommendationCard(finding: $0) }
        }
    }
}

struct SimpleRecommendationCard: View {
    @EnvironmentObject var model: AppModel
    let rec: SimplePresentation.Recommendation
    @State private var showWhy = false

    var body: some View {
        SurfaceCard(padding: 16, radius: 20) {
            HStack(alignment: .top, spacing: 14) {
                ZStack { Circle().fill(rec.severity.color.opacity(0.16)); Image(systemName: rec.severity.symbol).foregroundStyle(rec.severity.color) }
                    .frame(width: 42, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(rec.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Palette.text).fixedSize(horizontal: false, vertical: true)
                    Text(rec.body).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if !rec.why.isEmpty {
                        DisclosureGroup(isExpanded: $showWhy) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(rec.why, id: \.self) { Text("•  \($0)").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true) }
                            }.padding(.top, 4)
                        } label: { Text("Dlaczego?").font(Theme.Typo.body.weight(.semibold)).foregroundStyle(Theme.Palette.text) }
                    }
                    HStack(spacing: 10) {
                        ForEach(rec.actions, id: \.label) { a in
                            Button(a.label) { Task { await model.propose(ToolCall(name: a.tool, arguments: a.arguments)) } }.buttonStyle(.prominent(.protection))
                        }
                        if rec.needsPro { Button("Przejdź do trybu Profesjonalnego") { model.setViewMode(.pro) }.buttonStyle(.link).foregroundStyle(Theme.Palette.info).actionTarget() }
                    }
                }
            }
        }
    }
}

// MARK: - Profesjonalny: metodologia oceny

struct MethodologyCard: View {
    let assessment: HealthAssessment?
    var body: some View {
        SurfaceCard(padding: 16, radius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Metodologia oceny v\(HealthAssessment.methodologyVersion)").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                if let a = assessment {
                    Text("Pokrycie danymi: \(Int(a.coverage * 100))% · brak danych nie podnosi oceny.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                    ForEach(a.components) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(c.title).font(Theme.Typo.body.weight(.semibold)).foregroundStyle(Theme.Palette.text)
                                Text("waga \(Int(c.weight * 100))%").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                                Spacer()
                                Text(c.score.map(String.init) ?? String(localized: "brak danych")).font(Theme.Typo.metricSmall).foregroundStyle(c.score.map(scoreColor) ?? Theme.Palette.textSecondary)
                            }
                            ForEach(c.deductions, id: \.self) { d in
                                HStack(spacing: 6) {
                                    Text("−\(d.points) pkt").font(Theme.Typo.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.Palette.critical)
                                    Text(d.reason).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                                    EvidenceChip(id: d.evidenceID)
                                }
                            }
                            if let n = c.note { Text(n).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
                        }
                    }
                } else { Text("Brak danych – uruchom skan.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary) }
            }
        }
    }
}

// MARK: - Profesjonalny: szczegółowe czujniki (powermetrics, opcjonalnie, za zgodą)

struct DetailedSensorsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SurfaceCard(padding: 16, radius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Szczegółowe czujniki", systemImage: "waveform.path.ecg").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                switch model.sensors {
                case .idle: intro
                case .running: HStack { ProgressView().controlSize(.small); Text("Czekam na odczyt (okno hasła systemu)…").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary) }
                case .done(let s): readings(s)
                case .cancelled: note(String(localized: "Anulowano – nic nie zostało odczytane."), button: String(localized: "Spróbuj ponownie"))
                case .failed(let m): note(String(localized: "Odczyt się nie powiódł: \(m)"), button: String(localized: "Spróbuj ponownie"))
                case .unparsed: note(String(localized: "Odczyt się powiódł, ale nie rozpoznaliśmy formatu wyjścia – zamiast zgadywać, nic nie pokazujemy."), button: String(localized: "Spróbuj ponownie"))
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Opcjonalne. Jednorazowa próbka mocy CPU/GPU/ANE, częstotliwości i presji termicznej. Tylko odczyt – wymaga hasła administratora.")
                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Szczegółowe czujniki (wymaga hasła administratora)") { model.requestDetailedSensors() }.buttonStyle(.soft)
        }
    }

    private func note(_ text: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button(button) { model.requestDetailedSensors() }.buttonStyle(.soft)
        }
    }

    private func readings(_ s: PowerMetricsSample) -> some View {
        func watts(_ mw: Double?) -> String { mw.map { String(format: "%.2f W", $0 / 1000) } ?? "—" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                metric("CPU", watts(s.cpuPowerMW)); metric("GPU", watts(s.gpuPowerMW)); metric("ANE", watts(s.anePowerMW)); metric(String(localized: "Razem"), watts(s.combinedPowerMW))
            }
            if let t = s.thermalPressure { row(String(localized: "Presja termiczna"), t) }
            ForEach(s.clusters, id: \.name) { row($0.name, String(format: "%.2f GHz", $0.frequencyMHz / 1000)) }
            if let g = s.gpuFrequencyMHz { row(String(localized: "GPU – częstotliwość"), String(format: "%.0f MHz", g)) }
            Text("Temperatury poszczególnych rdzeni są niedostępne bez prywatnych interfejsów systemu – nie zgadujemy. Próbka z \(s.measuredAt.formatted(date: .omitted, time: .standard)).")
                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Odśwież") { model.requestDetailedSensors() }.buttonStyle(.soft)
        }
    }

    private func metric(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            Text(v).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text)
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary); Spacer(); Text(v).font(Theme.Typo.body.monospacedDigit()).foregroundStyle(Theme.Palette.text) }
    }
}

/// Arkusz zgody przed oknem hasła: co dokładnie zostanie uruchomione, że to tylko odczyt, dokąd trafia hasło.
struct SensorConsentSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Szczegółowe czujniki", systemImage: "waveform.path.ecg").font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
            Text("Za chwilę system poprosi o hasło administratora, żeby wykonać jednorazowy odczyt.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.text)
            VStack(alignment: .leading, spacing: 4) {
                Text("Co zostanie uruchomione").font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                Text(PowerMetricsSampler.commandLine).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: 8))
            }
            bullet("lock.open.fill", String(localized: "To wyłącznie odczyt: próbka trwa ok. 1 sekundy i niczego nie zmienia w systemie."))
            bullet("key.fill", String(localized: "Hasło wpisujesz w systemowym oknie macOS – nie trafia do MacCare i nigdzie nie jest zapisywane."))
            bullet("arrow.uturn.backward.circle.fill", String(localized: "Uprawnienie nie jest zapamiętywane i nie powstają żadne usługi pomocnicze – przy następnym odczycie zapytam znowu."))
            bullet("thermometer.medium.slash", String(localized: "Nie używamy prywatnych interfejsów (SMC/IOHID), więc temperatur poszczególnych rdzeni nie będzie."))
            HStack { Spacer()
                Button("Anuluj") { model.cancelDetailedSensorsConsent() }.keyboardShortcut(.cancelAction).buttonStyle(.soft)
                Button("Uruchom odczyt") { Task { await model.confirmDetailedSensors() } }.keyboardShortcut(.defaultAction).buttonStyle(.prominent(.performance, large: true))
            }
        }
        .padding(Theme.Space.xl).frame(width: 540)
        .background(Theme.Palette.background)
    }
    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(Theme.Palette.info)
            Text(text).font(Theme.Typo.body).foregroundStyle(Theme.Palette.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Ustawienia (na razie: tryb widoku; reszta – T10)

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ustawienia").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(Theme.Palette.text)
                SurfaceCard(padding: 20, radius: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tryb widoku").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                        ViewModeSwitch()
                        Text("Prosty – stan Maca jednym słowem, trzy najważniejsze rekomendacje bez żargonu, bez identyfikatorów, ścieżek i numerów procesów. Operacje o średnim i wysokim ryzyku są niedostępne.")
                            .font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Text("Profesjonalny – pełna metodologia oceny z dowodami, lista procesów z PID, autostart z podpisami, porty, raporty awarii, dziennik operacji i szczegółowe czujniki.")
                            .font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                SurfaceCard(padding: 20, radius: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tryb wykonania").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                        ExecutionModeSwitch(width: 260)
                        Text("Tylko odczyt – MacCare analizuje i pokazuje podgląd, niczego nie zmienia w systemie. Tak zaczyna się KAŻDE uruchomienie; wybór „Edycja” nie jest zapamiętywany.")
                            .font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Text("Edycja – odblokowuje wyłącznie przenoszenie do Kosza: pliki zaznaczone w „Moje pliki”, pozycje zaznaczone w Porządkach, odinstalowanie wybranej aplikacji i zaznaczone pozostałości po aplikacjach, zawsze po potwierdzeniu. Czyszczenie przez kwarantannę, trwałe usuwanie, opróżnianie Kosza, agenci autostartu i polecenia administratora czekają na poprawki bezpieczeństwa kwarantanny. Asystent AI nigdy nie przełącza trybu.")
                            .font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.4)
                        Text("Automatyczny powrót do odczytu po bezczynności").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                        SegmentedSwitch(selection: Binding(get: { model.editAutoReturnMinutes }, set: { model.setEditAutoReturnMinutes($0) }),
                                        options: AppModel.autoReturnChoices, title: { "\($0) min" }, module: .settings, width: 300, accessibilityName: String(localized: "Czas bezczynności do powrotu do odczytu"))
                    }
                }
                AssistantModelSettings(store: model.assistant)
                MenuBarSettings()
                UpdateSettings(updates: model.updates)
                NotificationSettings(notifier: model.notifier)                                  // audyt 2 (3.13): usunięta nieaktualna karta „powiadomienia w kolejnej wersji”
            }
            .frame(maxWidth: 720, alignment: .leading).padding(36).frame(maxWidth: .infinity)
        }
    }
}
