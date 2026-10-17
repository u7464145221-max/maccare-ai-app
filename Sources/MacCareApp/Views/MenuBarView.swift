import SwiftUI
import MacCareCore

/// Pasek menu (P2-10 etap 2): stan Maca w skrócie i skróty. Tylko odczyt – nic tu nie zmienia systemu.
struct MenuBarView: View {
    @EnvironmentObject private var live: LiveMetrics                                // dane na żywo – przeliczanie tylko tego widoku
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.stateColor).frame(width: 10, height: 10)
                Text("MacCare AI").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                Spacer()
                Text(model.stateLabel).font(Theme.Typo.caption.weight(.semibold)).foregroundStyle(model.stateColor)
            }
            Divider()
            // 17.10 (decyzja właściciela „4 tak”): mini-wykresy ostatnich minut i ostrzeżenie o zapełnianiu dysku. Tylko odczyt.
            ForEach(MenuBarSummary.lines(model), id: \.label) { l in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: l.symbol).frame(width: 18).foregroundStyle(Theme.Palette.textSecondary)
                        Text(l.label).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        Text(l.value).font(Theme.Typo.body.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.Palette.text)
                    }
                    if let series = l.series, series.count > 1 {
                        Sparkline(values: series, color: l.symbol == "cpu" ? AppModule.performance.foreground : AppModule.smartScan.foreground, upper: 100)
                            .frame(height: 26).padding(.leading, 26)
                            .accessibilityLabel(String(localized: "Wykres: \(l.label), ostatnie minuty"))
                    }
                    if let fill = l.fill {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.Palette.surfaceAlt)
                                Capsule().fill(model.diskTrend?.isWarning == true ? Theme.Palette.warning : AppModule.files.foreground)
                                    .frame(width: max(4, g.size.width * CGFloat(min(max(fill, 0), 1))))
                            }
                        }.frame(height: 6).padding(.leading, 26)
                        .accessibilityHidden(true)
                    }
                }
            }
            if let t = model.diskTrend, t.isWarning {
                Label(t.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let s = model.smartSummary {
                Text("Ostatni Smart Scan: \(s.date.formatted(date: .abbreviated, time: .shortened))").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
            }
            Divider()
            Button { runSmartScan() } label: { Label("Uruchom Smart Scan", systemImage: "wand.and.stars") }
                .buttonStyle(.prominent(.smartScan, large: false))
            HStack {
                Button("Otwórz MacCare") { show(nil) }.buttonStyle(.soft)
                Spacer()
                Button("Zakończ") { NSApp.terminate(nil) }.buttonStyle(.soft)
            }
            Text(model.isReadOnlyMode ? String(localized: "Tryb: tylko odczyt") : String(localized: "Tryb: Edycja")).font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(14).frame(width: 300)
    }

    /// Audyt 3: w trakcie skanu (np. automatycznego) tylko pokazuje postęp – bez cofania ekranu do startu.
    private func runSmartScan() {
        show(.smartScan)
        guard model.scanStage == nil else { return }
        Task { model.restart(.smartScan); await model.smartScan() }
    }

    private func show(_ module: AppModule?) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if let module { model.open(module) }
    }
}

/// Preferencja widoczności ikony (UserDefaults aplikacji – ustawienie wyglądu, nie trybu wykonania).
enum MenuBarPreference { static let key = "menuBarIcon" }

/// Wiersze podsumowania paska menu – osobno, żeby dało się je przetestować bez widoku.
enum MenuBarSummary {
    struct Line {
        let symbol: String; let label: String; let value: String
        /// Mini-wykres (procent 0–100) i zajętość (0–1) – nil, gdy nie dotyczy albo brak pomiaru.
        var series: [Double]? = nil
        var fill: Double? = nil
    }

    @MainActor static func lines(_ m: AppModel) -> [Line] {
        var out: [Line] = []
        out.append(Line(symbol: "cpu", label: String(localized: "Procesor"), value: m.cpuLive.last.map { String(format: "%.0f%%", $0) } ?? "—", series: m.cpuLive))
        out.append(Line(symbol: "memorychip", label: String(localized: "Pamięć"), value: m.memLive.last.map { String(format: "%.0f%%", $0) } ?? "—", series: m.memLive))
        if let v = m.snapshot?.bootVolume ?? m.bootVolumeQuick {
            out.append(Line(symbol: "internaldrive", label: String(localized: "Wolne na dysku"), value: ByteFormat.string(v.availableImportant), fill: 1 - v.freeFraction))
        }
        if let u = m.snapshot?.updates {
            out.append(Line(symbol: "arrow.down.circle", label: String(localized: "Aktualizacje Apple"), value: u.pending.isEmpty ? String(localized: "brak") : String(localized: "\(u.pending.count) do instalacji")))
        }
        out.append(Line(symbol: "exclamationmark.bubble", label: String(localized: "Sprawy do sprawdzenia"), value: "\(m.issueCount(m.findings))"))
        return out
    }
}

/// Ustawienia: ikona w pasku menu.
struct MenuBarSettings: View {
    @AppStorage(MenuBarPreference.key) private var showMenuBar = true
    var body: some View {
        SurfaceCard(padding: 20, radius: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $showMenuBar) { Text("Ikona w pasku menu").font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text) }
                    .toggleStyle(.switch)
                Text("Stan Maca w skrócie: wykresy procesora i pamięci z ostatnich minut, wolne miejsce z ostrzeżeniem, gdy dysk szybko się zapełnia, aktualizacje i szybki Smart Scan. Tylko odczyt.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}
