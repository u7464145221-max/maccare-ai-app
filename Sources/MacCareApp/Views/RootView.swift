import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    /// Pasek zwija się do samych ikon w widokach wyniku (jak w referencji UX §7).
    private var collapsed: Bool { model.phase(model.module) == .result }

    var body: some View {
        ZStack {
            ModuleBackground(module: model.module)
            HStack(spacing: 0) {
                SidebarView(collapsed: collapsed)
                    .frame(width: collapsed ? 68 : 232)
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: collapsed)
                VStack(spacing: 0) {
                    ReadOnlyBanner()
                    if let warning = model.storageWarning { StorageWarningBar(text: warning) }
                    if let notice = model.editNotice { EditNoticeBar(text: notice) }
                    if model.showFilesShortcut { EditFilesShortcutBar() }
                    if let hint = model.proModeHint { ProModeHintBar(text: hint) }
                    content
                        .id(model.module)
                        .transition(.opacity.combined(with: .scale(scale: 0.99)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.module)
        .environment(\.viewMode, model.viewMode)
        .sheet(isPresented: $model.sensorConsentPresented) { SensorConsentSheet().environmentObject(model) }
        .sheet(isPresented: $model.editConfirmPresented) { EditModeSheet().environmentObject(model) }
        .sheet(item: $model.sheet, onDismiss: { Task { await model.dismissSheet() } }) { c in ApprovalSheet(content: c) }
        .frame(minWidth: 1040, minHeight: 700)
    }

    @ViewBuilder
    private var content: some View {
        switch model.module {
        case .smartScan: SmartScanView()
        case .cleanup: CleanupView()
        case .history: HistoryView()
        case .protection: ProtectionView()
        case .performance: PerformanceView()
        case .files: FilesView()
        case .settings: SettingsView()
        case .assistant: AssistantView(store: model.assistant)
        case .apps: AppsView(store: model.apps)
        case .tools, .activity, .notifications, .knowledge:
            ModulePlaceholder(module: model.module)
        }
    }
}

/// Uczciwy ekran dla modułów, które nie są jeszcze zbudowane (nic nie jest udawane).
struct ModulePlaceholder: View {
    let module: AppModule
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ModuleHero(module: module, size: 200)
            Text(module.title).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Theme.Palette.text)
            Text("Ten moduł jest w budowie – funkcja nie jest jeszcze dostępna.").font(Theme.Typo.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stały pasek trybu (W4): wskaźnik „Tylko odczyt” / „Edycja” (ikona + napis + kolor) i dwa przełączniki – tryb wykonania oraz tryb widoku.
/// Napis wskaźnika skraca się w wąskim oknie, przełączniki zawsze zostają w całości.
struct ReadOnlyBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ExecutionModeIndicator().layoutPriority(-1)
            Spacer(minLength: Theme.Space.s)
            ExecutionModeSwitch().fixedSize()
            ViewModeSwitch().fixedSize()
        }
        .padding(.leading, Theme.Space.xl).padding(.trailing, Theme.Space.xl).padding(.vertical, 4)
        .background(Theme.Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.hairline).frame(height: 1) }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    let collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 34)                                   // miejsce na „światła” okna (okno bez paska tytułu)
            ForEach(model.viewMode.mainModules) { item($0) }
            if model.viewMode.secondaryModules.isEmpty { EmptyView() }
            else if !collapsed { Text("NARZĘDZIA I AKTYWNOŚĆ").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Palette.textSecondary).padding(.leading, 14).padding(.top, 16).padding(.bottom, 2) }
            else { Rectangle().fill(Theme.Palette.hairline).frame(height: 1).padding(.vertical, 8) }
            ScrollView(showsIndicators: false) { VStack(spacing: 2) { ForEach(model.viewMode.secondaryModules) { item($0) } } }
            Spacer(minLength: 8)
            if AppModule.assistant.isBuilt { item(.assistant) }             // asystent przypięty na dole (ukryty, dopóki nie jest podłączony – P2-9/P2-15)
        }
        .padding(.horizontal, collapsed ? 8 : 10).padding(.bottom, 12)
        .background(SidebarBackground(module: model.module))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.Palette.hairline).frame(width: 1) }
    }

    private func badge(_ m: AppModule) -> Bool {
        switch m {
        case .notifications: return false
        default: return model.phase(m) == .result && model.module != m
        }
    }

    private func item(_ m: AppModule) -> some View {
        let active = model.module == m
        return Button { model.open(m) } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(m.fill)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: m.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(m.label))
                        .shadow(color: .black.opacity(active ? 0.28 : 0.12), radius: active ? 5 : 2, y: 2)
                    if badge(m) { Circle().fill(Theme.Palette.info).frame(width: 10, height: 10).overlay(Circle().stroke(Theme.Palette.surface, lineWidth: 2)).offset(x: 4, y: -4) }
                }
                if !collapsed { Text(m.title).font(.system(size: 13.5, weight: active ? .semibold : .regular)).foregroundStyle(Theme.Palette.text); Spacer(minLength: 0) }
            }
            .padding(.horizontal, collapsed ? 6 : 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? Theme.Palette.surface : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(active ? Theme.Palette.stroke : Color.clear, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.title)
        .accessibilityLabel(m.title)
    }
}

/// Tło paska bocznego: neutralne + zabarwienie kolorem aktywnego modułu (płynne przejście jak w tle okna).
struct SidebarBackground: View {
    let module: AppModule
    var body: some View {
        ZStack {
            Theme.Palette.sidebar
            ForEach(AppModule.allCases) { m in m.sidebarTint.opacity(m == module ? 1 : 0) }
        }
        .animation(.easeInOut(duration: 0.4), value: module)
    }
}
