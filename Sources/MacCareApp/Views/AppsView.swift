import SwiftUI
import MacCareCore
import MacCareSystem

/// Moduł „Aplikacje”: inwentarz i możliwe pozostałości (odczyt). F15: odinstalowanie przez Kosz – aplikacja i wybrane dane, w trybie Edycja i po potwierdzeniu.
struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: AppsStore
    @State private var tab = Tab.apps
    @State private var uninstallTarget: InstalledApp?
    /// F20: zaznaczone pozostałości (ŚCIEŻKI) – domyślnie nic (to heurystyka, wybór świadomy). Audyt 2.2: Application Support i kontenery
    /// wybiera się osobnym polem – nie przechodzą razem z pamięcią podręczną i preferencjami.
    @State private var chosenLeftovers: Set<String> = []
    enum Tab: String, CaseIterable { case apps = "Aplikacje", leftovers = "Możliwe pozostałości" }

    var body: some View {
        switch model.phase(.apps) {
        case .start:
            ModuleStart(module: .apps, scanTitle: String(localized: "Skanuj")) { start() }
        case .scanning, .result:
            result
        }
    }

    private func start() {
        model.setPhase(.apps, .result)
        Task { await store.load(force: true) }
    }

    private var result: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { model.restart(.apps) } label: { Label("Zacznij od nowa", systemImage: "chevron.left") }.buttonStyle(.soft).fixedSize()
                if store.loading {
                    ProgressView(value: Double(store.progress.done), total: Double(max(store.progress.total, 1))).frame(maxWidth: 220)
                    Text("Sprawdzono \(store.progress.done) z \(store.progress.total)").font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                SegmentedSwitch(selection: $tab, options: Tab.allCases, title: { $0.title }, module: .apps, width: 360, accessibilityName: String(localized: "Widok aplikacji"))
            }
            if tab == .apps { appsList } else { leftoversList }
            Text("Odinstalowanie przenosi aplikację i wybrane przez Ciebie dane do Kosza – w trybie Edycja i po potwierdzeniu; w trybie tylko do odczytu zobaczysz podgląd. Aplikacji Apple i działających MacCare nie odinstalowuje.")
                .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 16)
        .onReceive(NotificationCenter.default.publisher(for: .init("MacCareScreenshotApps"))) { n in   // tylko tryb zrzutów (W8)
            guard let what = n.object as? String else { return }
            if what == "leftovers" { tab = .leftovers; chosenLeftovers = Set((store.leftovers ?? []).filter { $0.bundleID.hasPrefix("com.oldvendor") }.flatMap { $0.safeItems.map(\.path) }) }
            else if what == "none" { uninstallTarget = nil }
            else if let a = store.apps.first(where: { $0.path == what }) { tab = .apps; uninstallTarget = a }
        }
        .sheet(item: $uninstallTarget) { app in
            UninstallChooser(app: app, home: model.home, onCancel: { uninstallTarget = nil }) { items in
                uninstallTarget = nil
                Task { await model.proposeUninstall(appPath: app.path, items: items) }
            }
        }
    }

    private var appsList: some View {
        SurfaceCard(padding: 0, radius: 24) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(AppsStore.headline(store.apps))
                        .font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                    Spacer()
                    Picker("Filtr", selection: $store.filter) { ForEach(AppsStore.Filter.allCases, id: \.self) { Text($0.title).tag($0) } }.fixedSize()
                    Picker("Sortuj", selection: $store.sort) { ForEach(AppsStore.Sort.allCases, id: \.self) { Text($0.title).tag($0) } }.fixedSize()
                }.padding(14)
                Divider().opacity(0.3)
                List(store.visibleApps) { a in appRow(a) }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .overlay { if store.visibleApps.isEmpty && !store.loading { Text("Brak aplikacji spełniających kryteria.").foregroundStyle(Theme.Palette.textSecondary) } }
            }
        }
    }

    private func appRow(_ a: InstalledApp) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.version.isEmpty ? a.name : "\(a.name) \(a.version)").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1)
                Text("\(AppsStore.usageText(a)) · \(a.signature.label)").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if a.isIntelOnly { Pill(text: String(localized: "Intel"), color: Theme.Palette.warning).help("Aplikacja tylko dla procesorów Intel – na Apple Silicon działa przez Rosetta 2, wolniej i z większym zużyciem energii.") }
            Pill(text: a.source.label, color: Theme.Palette.textSecondary)
            Text(ByteFormat.string(a.size)).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text).frame(minWidth: 80, alignment: .trailing)
            Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }.buttonStyle(.soft)
            if !a.isSystem && !a.bundleID.lowercased().hasPrefix("com.apple.") {
                Button("Odinstaluj…") { uninstallTarget = a }.buttonStyle(.soft)
                    .help(model.isReadOnlyMode ? model.previewHint : String(localized: "Aplikacja i wybrane dane trafią do Kosza – przywrócisz je w Finderze"))
            }
        }
    }

    /// Pole wyboru dla zestawu wpisów: zaznaczone, gdy wszystkie są wybrane.
    private func pathsBinding(_ items: [AppLeftover]) -> Binding<Bool> {
        Binding(get: { !items.isEmpty && items.allSatisfy { chosenLeftovers.contains($0.path) } },
                set: { on in for it in items { if on { chosenLeftovers.insert(it.path) } else { chosenLeftovers.remove(it.path) } } })
    }

    private var leftoversList: some View {
        SurfaceCard(padding: 0, radius: 24) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.leftovers.map { "\(Plural.counted($0.count, one: "możliwa pozostałość", few: "możliwe pozostałości", many: "możliwych pozostałości")) · \(ByteFormat.string(store.leftoversSize))" } ?? String(localized: "Szukam pozostałości…"))
                        .font(Theme.Typo.headline).foregroundStyle(Theme.Palette.text)
                    Text("Wpisy w ~/Library nazwane identyfikatorem aplikacji, której system nie zna – ani w folderach Programy, ani w innym miejscu. To heurystyka: część może należeć do narzędzi bez aplikacji (np. wiersz poleceń) – sprawdź przed usunięciem. Dane aplikacji (Application Support, kontenery) zaznaczasz osobno.")
                        .font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }.padding(14)
                Divider().opacity(0.3)
                List(store.leftovers ?? []) { g in
                    HStack(spacing: 10) {
                        if g.safeItems.isEmpty { Color.clear.frame(width: 28, height: 28) }
                        else {
                            Toggle("", isOn: pathsBinding(g.safeItems)).labelsHidden().toggleStyle(.largeCheckbox).accessibilityLabel(g.bundleID)
                        }
                        Image(systemName: "shippingbox").foregroundStyle(Theme.Palette.textSecondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.bundleID).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle)
                            Text("\(g.locations) · ostatnia zmiana \(g.lastModified.formatted(date: .abbreviated, time: .omitted))").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if !g.riskyItems.isEmpty {
                            Toggle(isOn: pathsBinding(g.riskyItems)) { Text("dane aplikacji") }.toggleStyle(.largeCheckbox)
                                .foregroundStyle(Theme.Palette.warning)
                                .help(String(localized: "Application Support i kontenery mogą zawierać dokumenty i ustawienia – zaznacz tylko, jeśli na pewno nie wrócisz do tej aplikacji"))
                        }
                        Text(ByteFormat.string(g.size)).font(Theme.Typo.metricSmall).foregroundStyle(Theme.Palette.text)
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting(g.items.map { URL(fileURLWithPath: $0.path) }) }.buttonStyle(.soft)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if store.leftovers?.isEmpty == true { Text("Nie znaleziono pozostałości.").foregroundStyle(Theme.Palette.textSecondary) } }
                Divider().opacity(0.3)
                HStack(spacing: 12) {
                    let picked = (store.leftovers ?? []).flatMap(\.items).filter { chosenLeftovers.contains($0.path) }
                    Text("Zaznaczono: \(picked.count) · \(ByteFormat.string(picked.reduce(0) { $0 + $1.size }))").font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Button(model.isReadOnlyMode ? String(localized: "Podgląd przeniesienia do Kosza") : String(localized: "Przenieś zaznaczone do Kosza…")) {
                        let paths = picked.map(\.path)
                        chosenLeftovers = []
                        Task { await model.proposeLeftovers(paths: paths) }
                    }
                    .buttonStyle(.prominent(.apps)).disabled(picked.isEmpty)
                    .help(model.isReadOnlyMode ? model.previewHint : String(localized: "Zaznaczone pozostałości trafią do Kosza – przywrócisz je w Finderze"))
                }.padding(14)
            }
        }
    }
}

/// F15: wybór danych aplikacji przed odinstalowaniem. Domyślnie zaznaczone tylko pewne i bez danych użytkownika; Application Support i kontener – świadomie.
struct UninstallChooser: View {
    let app: InstalledApp
    let home: String
    let onCancel: () -> Void
    let onConfirm: ([String]) -> Void
    @State private var items: [AppDataItem]?
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(String(localized: "Odinstalować \(app.name)?")).font(Theme.Typo.title).foregroundStyle(Theme.Palette.text)
            Text("Aplikacja trafi do Kosza. Zaznacz, które jej dane z ~/Library przenieść razem z nią.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
            if let items {
                if items.isEmpty {
                    Text("Nie znaleziono danych tej aplikacji w ~/Library.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { it in row(it) }
                        }
                    }
                    .frame(maxHeight: 280)
                    if items.contains(where: { $0.risky }) {
                        Text("Application Support i kontener mogą zawierać Twoje dokumenty i ustawienia – dlatego nie są zaznaczone.").font(Theme.Typo.caption).foregroundStyle(Theme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ProgressView().controlSize(.regular)
            }
            HStack {
                Spacer()
                Button("Anuluj", action: onCancel).buttonStyle(.soft).keyboardShortcut(.cancelAction)
                Button("Dalej – podgląd") { onConfirm(items?.filter { chosen.contains($0.path) }.map(\.path) ?? []) }
                    .buttonStyle(.prominent(.apps)).disabled(items == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            let id = app.bundleID, home = home
            let found = await Task.detached(priority: .utility) { AppData.find(appBundleID: id, home: home) }.value
            items = found
            chosen = Set(found.filter(\.defaultSelected).map(\.path))
        }
    }

    private func row(_ it: AppDataItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { chosen.contains(it.path) }, set: { on in if on { chosen.insert(it.path) } else { chosen.remove(it.path) } }))
                .labelsHidden().toggleStyle(.largeCheckbox)
                .accessibilityLabel((it.path as NSString).lastPathComponent)
            VStack(alignment: .leading, spacing: 1) {
                Text((it.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Palette.text).lineLimit(1).truncationMode(.middle)
                Text(it.association == .certain ? String(localized: "\(it.location) · pewne powiązanie") : String(localized: "\(it.location) · składnik aplikacji (prawdopodobne)"))
                    .font(Theme.Typo.caption).foregroundStyle(it.risky ? Theme.Palette.warning : Theme.Palette.textSecondary)
            }
            Spacer(minLength: 6)
            Text(ByteFormat.string(it.size)).font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
