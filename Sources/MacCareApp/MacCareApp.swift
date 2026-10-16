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
        // Audyt 16.10 (3.5): sama obecność `MACCARE_HOME` nie wystarcza – musi wskazywać INNY katalog niż prawdziwy domowy.
        let trash: TrashService? = Self.substituteTrashAllowed(home: env["MACCARE_HOME"]) ? env["MACCARE_TRASH_DIR"].map { DirectoryTrash(dir: $0) } : nil
        _model = StateObject(wrappedValue: AppModel(dataDir: dir, home: home, trash: trash))
    }

    /// Kosz zastępczy wyłącznie dla syntetycznego katalogu domowego (zrzuty, demonstracje) – nigdy dla prawdziwego.
    static func substituteTrashAllowed(home: String?, realHome: String = NSHomeDirectory()) -> Bool {
        guard let home, !home.isEmpty else { return false }
        return PathTools.canonical(home, home: realHome) != PathTools.canonical(realHome, home: realHome)
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
