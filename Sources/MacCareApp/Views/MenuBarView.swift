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
            ForEach(MenuBarSummary.lines(model), id: \.label) { l in
                HStack {
                    Image(systemName: l.symbol).frame(width: 18).foregroundStyle(Theme.Palette.textSecondary)
                    Text(l.label).font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Text(l.value).font(Theme.Typo.body.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.Palette.text)
                }
            }
            Divider()
            Button { show(.smartScan); Task { model.restart(.smartScan); await model.smartScan() } } label: { Label("Uruchom Smart Scan", systemImage: "wand.and.stars") }
                .buttonStyle(.prominent(.smartScan, large: false))
            HStack {
                Button("Otwórz MacCare") { show(nil) }.buttonStyle(.soft)
                Spacer()
                Button("Zakończ") { NSApp.terminate(nil) }.buttonStyle(.soft)
            }
            Text("Tryb: \(model.isReadOnlyMode ? "tylko odczyt" : "Edycja")").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(14).frame(width: 300)
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
    struct Line { let symbol: String; let label: String; let value: String }

    @MainActor static func lines(_ m: AppModel) -> [Line] {
        var out: [Line] = []
        out.append(Line(symbol: "cpu", label: String(localized: "Procesor"), value: m.cpuLive.last.map { String(format: "%.0f%%", $0) } ?? "—"))
        out.append(Line(symbol: "memorychip", label: String(localized: "Pamięć"), value: m.memLive.last.map { String(format: "%.0f%%", $0) } ?? "—"))
        if let v = m.snapshot?.bootVolume ?? m.bootVolumeQuick { out.append(Line(symbol: "internaldrive", label: String(localized: "Wolne na dysku"), value: ByteFormat.string(v.availableImportant))) }
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
                Text("Stan Maca w skrócie (procesor, pamięć, wolne miejsce, aktualizacje) i szybki Smart Scan. Tylko odczyt.")
                    .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}
