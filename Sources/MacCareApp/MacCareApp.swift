import SwiftUI
import MacCareCore

@main
struct MacCareApp: App {
    @StateObject private var model: AppModel
    /// Ikona w pasku menu (Ustawienia → „Ikona w pasku menu”); domyślnie włączona.
    @AppStorage(MenuBarPreference.key) private var showMenuBar = true

    init() {
        // Zmienne środowiskowe pozwalają uruchomić aplikację na danych testowych (zrzuty ekranu, testy ręczne).
        let env = ProcessInfo.processInfo.environment
        let dir = env["MACCARE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        let home = env["MACCARE_HOME"] ?? NSHomeDirectory()
        // Kosz zastępczy (zrzuty ekranu/demonstracja) działa WYŁĄCZNIE na syntetycznym HOME – bez `MACCARE_HOME` zmienna `MACCARE_TRASH_DIR` jest ignorowana.
        let trash: TrashService? = env["MACCARE_HOME"] == nil ? nil : env["MACCARE_TRASH_DIR"].map { DirectoryTrash(dir: $0) }
        _model = StateObject(wrappedValue: AppModel(dataDir: dir, home: home, trash: trash))
    }

    var body: some Scene {
        WindowGroup("MacCare AI", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear { model.start() }
                .task { await ScreenshotDriver.runIfRequested(model: model) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)

        // P2-10 etap 2: stan Maca w pasku menu (tylko odczyt). Ikona = kolor stanu nie jest dostępny w pasku, więc symbol zmienia się z oceną.
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
