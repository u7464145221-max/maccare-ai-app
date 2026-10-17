import SwiftUI
import MacCareCore
import MacCareSystem

enum HistoryTab: String, CaseIterable, Identifiable {
    case scans = "Skany", operations = "Dziennik operacji", measurements = "Pomiary", quarantine = "Kwarantanna"
    var id: String { rawValue }
}

/// Faza ekranu modułu: ekran startowy → skanowanie → wynik. Pasek boczny zwija się w fazie wyniku.
enum ModulePhase { case start, scanning, result }

/// Wynik operacji pokazywany użytkownikowi: deklarowane i **zmierzone** zmiany – nigdy tylko deklaracja.
struct OperationReport: Identifiable {
    let id = UUID()
    var date = Date()
    var title: String
    var success: Bool
    var message: String
    var estimatedBytes: UInt64?
    /// Zmiana wolnego miejsca na wolumenie (po − przed). nil = nie mierzono.
    var measuredDelta: Int64?
    var note: String?
    /// Narzędzie, którego dotyczy raport (np. wynik Kosza pokazujemy w „Moje pliki”).
    var tool: String?
    /// Wynik CZĘŚCIOWY: część elementów przeniesiona, część nie – to nie jest sukces.
    var partial = false
    /// Ścieżki elementów w Koszu (do „Pokaż w Koszu”).
    var trashedPaths: [String] = []
}

/// Zawartość arkusza operacji: to samo okno pokazuje zatwierdzenie (gdy zmiany są dozwolone) i sam podgląd (tryb tylko do odczytu).
struct SheetContent: Identifiable {
    var id = UUID()
    var toolName: String
    var preview: OperationPreview
    var permissions: [Permission]
    var separate: [SensitiveCategory]
    var origin: String
    /// true = tryb tylko do odczytu: nic nie zostanie wykonane, przycisk zatwierdzenia jest wyłączony.
    var readOnly: Bool
    var reason: String?
    /// Włączenie Edycji (w bieżącym zakresie) odblokowałoby tę operację ⇒ arkusz podglądu pokazuje skrót „Włącz edycję…”.
    var canEnableEdit = false
    /// Tytuł przycisku zatwierdzenia (domyślnie „Zatwierdź i wykonaj”).
    var approveTitle: String {
        if toolName == "uninstall_app_to_trash" { return String(localized: "Odinstaluj do Kosza") }
        return ["trash_selected", "trash_cleanup_items", "trash_app_leftovers"].contains(toolName) ? String(localized: "Przenieś do Kosza") : String(localized: "Zatwierdź i wykonaj")
    }
    /// Gdy operacji nie odblokuje nawet Edycja (zakres `.trashSelectedOnly`): komunikat o dostępności po poprawkach bezpieczeństwa.
    var futureNote: String?
}

struct SmartScanSummary {
    var date: Date
    var health: Int?
    var findings: Int
    var safeReclaimable: UInt64
    var totalReclaimable: UInt64
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Usługi
    let home: String
    let tempDir: String
    let dataDir: URL
    let history: HistoryStore
    let quarantine: QuarantineStore
    let provider: MacDiagnosticsProvider
    let executor: ToolExecutor
    let diskMap: DiskMapStore
    /// Asystent AI (P2-9) – lokalny model, własny wykonawca narzędzi (ten sam rejestr i dziennik audytu).
    let assistant: AssistantStore
    /// Moduł „Aplikacje” (tylko odczyt).
    let apps: AppsStore
    /// Aktualizacje z publicznego repozytorium GitHub (decyzja właściciela 15.10.2026) – tylko na żądanie albo raz w tygodniu po włączeniu.
    let updates = UpdateChecker()
    /// F21: powiadomienia o ważnych sprawach (domyślnie wyłączone).
    let notifier = ImportantNotifier()

    // MARK: Nawigacja
    @Published var module: AppModule = .smartScan
    /// Tryb widoku (Prosty/Profesjonalny) – zapamiętany w `HistoryStore.settings`; domyślnie Prosty.
    @Published private(set) var viewMode: ViewMode = .simple
    /// Podpowiedź „Przejdź do trybu Profesjonalnego” (Prosty zablokował ryzykowną operację).
    @Published var proModeHint: String?
    /// „Szczegółowe czujniki” (powermetrics, opcjonalnie, za zgodą, tylko Profesjonalny).
    enum SensorState: Equatable { case idle, running, done(PowerMetricsSample), cancelled, failed(String), unparsed }
    @Published private(set) var sensors: SensorState = .idle
    @Published var sensorConsentPresented = false
    let sensorSampler: SensorSampling
    @Published private(set) var phases: [AppModule: ModulePhase] = [:]
    @Published var cleanupDetail = false
    @Published var moduleStage: [AppModule: String] = [:]
    @Published var cleanupFocus: CleanupCategory?
    @Published var historyTab: HistoryTab = .scans

    // MARK: Panel
    /// Dane na żywo – osobny obiekt (`LiveMetrics`); tutaj tylko odczyt dla logiki i testów.
    let live = LiveMetrics()
    var snapshot: SystemSnapshot? { live.state.snapshot }
    /// Zajętość dysku startowego odczytana od razu przy starcie (jedno szybkie zapytanie o wolumen) – zanim pojawi się pierwszy pełny pomiar.
    let bootVolumeQuick: VolumeStats? = BootVolumeQuickRead.read()
    var assessment: HealthAssessment? { live.state.assessment }
    @Published private(set) var findings: [Finding] = []
    var evidenceByID: [String: Evidence] { live.state.evidenceByID }
    var cpuLive: [Double] { live.state.cpuLive }
    var memLive: [Double] { live.state.memLive }
    @Published private(set) var scanStage: String?
    @Published private(set) var smartSummary: SmartScanSummary?

    // MARK: Czyszczenie
    @Published private(set) var scanResult: CleanupScanResult?
    @Published private(set) var cleanupScanning = false
    @Published var selection: Set<String> = []
    @Published var pending: PendingApproval?
    @Published var sheet: SheetContent?
    @Published private(set) var lastReport: OperationReport?
    @Published private(set) var operationRunning = false

    // MARK: Tryb wykonania (W4)
    /// Jedno źródło prawdy o trybie to `ExecutionGuard` (stan uruchomieniowy, ZAWSZE „tylko odczyt” po starcie – nie jest zapisywany). Tu tylko odbicie dla interfejsu.
    var executionMode: ExecutionMode { ExecutionGuard.mode }
    /// Zmienia się przy każdej zmianie trybu (także automatycznym powrocie po bezczynności) – odświeża widoki.
    @Published private(set) var executionRevision = 0
    /// Arkusz potwierdzenia włączenia Edycji.
    @Published var editConfirmPresented = false
    /// Informacja po automatycznym powrocie do odczytu (zamykana przez użytkownika).
    @Published var editNotice: String?
    /// P2-7: problem z bazą historii (uszkodzona/niedostępna) – pokazywany na pasku u góry, nie ukrywany.
    @Published var storageWarning: String?

    /// Przenosi uszkodzony plik bazy (i pliki -wal/-shm) obok, pod nazwę `history.sqlite.corrupt-<data>`. Tylko własne pliki aplikacji w jej katalogu danych;
    /// nic nie jest kasowane. Zwraca nową nazwę albo nil (brak pliku / nie udało się przenieść).
    nonisolated static func archiveCorruptDatabase(_ path: String, now: Date = Date()) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let target = path + ".corrupt-" + f.string(from: now)
        guard (try? fm.moveItem(atPath: path, toPath: target)) != nil else { return nil }   // try? świadomie: wynik sprawdzany – nil ⇒ baza w pamięci z komunikatem
        for ext in ["-wal", "-shm"] where fm.fileExists(atPath: path + ext) { try? fm.moveItem(atPath: path + ext, toPath: target + ext) }   // try? świadomie: pliki pomocnicze SQLite – najlepsza próba, główny plik już zachowany
        return (target as NSString).lastPathComponent
    }
    /// Automatyczny powrót do odczytu po tylu minutach bezczynności w Edycji (ustawienie; domyślnie 15). Zapisywany jest TYLKO ten czas, nigdy sam tryb.
    @Published private(set) var editAutoReturnMinutes = AppModel.defaultAutoReturnMinutes
    static let autoReturnChoices = [5, 15, 30, 60]
    static let defaultAutoReturnMinutes = 15
    static let autoReturnKey = "edit.autoReturnMinutes"
    let executionState: ExecutionState
    private var executionObservation: ExecutionState.Observation?
    private let editMonitor = EditSessionMonitor()
    private let monitorEditActivity: Bool
    private var suppressAutoReturnNotice = false

    var isReadOnlyMode: Bool { executionMode == .readOnly }
    /// Czy operacje kwarantanny i systemowe są zablokowane (podgląd zamiast wykonania): tak w odczycie i w Edycji (poza zakresem `.trashOperations`).
    var readOnly: Bool { !ExecutionGuard.allows(.quarantineMove) }
    /// Porządki do Kosza: tylko podgląd w trybie odczytu; w Edycji (`.trashOperations`) – wykonanie po potwierdzeniu.
    var cleanupPreviewOnly: Bool { !ExecutionGuard.allows(.cleanupToTrash) }
    /// Czy zaznaczone pliki można teraz przenieść do Kosza (W5).
    var canTrashSelected: Bool { ExecutionGuard.allows(.trashSelected) }
    /// Podpowiedź przy przyciskach, które dają tylko podgląd.
    var previewHint: String {
        isReadOnlyMode ? String(localized: "Tryb tylko do odczytu – zobaczysz podgląd, MacCare niczego nie zmieni.") : String(localized: "Ta operacja czeka na poprawki bezpieczeństwa kwarantanny – na razie tylko podgląd.")
    }

    static func validAutoReturnMinutes(_ raw: String?) -> Int { raw.flatMap { Int($0) }.flatMap { autoReturnChoices.contains($0) ? $0 : nil } ?? defaultAutoReturnMinutes }

    /// Krok 1: użytkownik wybrał „Edycja” – pokazujemy arkusz potwierdzenia. Samo kliknięcie niczego nie włącza.
    func requestEditMode() {
        guard isReadOnlyMode else { return }
        editConfirmPresented = true
    }

    /// Skrót „Włącz edycję…” z arkusza podglądu: zamyka podgląd i dopiero potem pokazuje potwierdzenie (dwa arkusze naraz SwiftUI nie pokaże).
    func requestEditModeFromPreview() async {
        await decline()
        try? await Task.sleep(nanoseconds: 350_000_000)   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
        requestEditMode()
    }

    func cancelEditConfirmation() { editConfirmPresented = false }

    /// Skrót po włączeniu Edycji (Przegląd 31): „Przenieś do Kosza” działa tylko w „Moje pliki” (tryb Profesjonalny) – pasek podpowiada, gdzie to jest.
    @Published var filesShortcutDismissed = false
    var showFilesShortcut: Bool { !isReadOnlyMode && module != .files && !filesShortcutDismissed }

    /// Otwiera panel „Pełny dostęp do dysku” w Ustawieniach systemowych (tylko otwarcie – niczego nie zmienia; P1-4).
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    /// Przechodzi do „Moje pliki”; w trybie Prostym przełącza najpierw widok na Profesjonalny (tam znajduje się ten moduł).
    func openMyFiles() {
        if viewMode != .pro { setViewMode(.pro) }
        module = .files
        filesShortcutDismissed = true
    }

    /// Krok 2: potwierdzone w arkuszu. Włącza WYŁĄCZNIE zakres `EditScope.production` (`.trashOperations`: wszystko tylko przez Kosz); `.full` nie jest osiągalny z interfejsu.
    func confirmEditMode() {
        editConfirmPresented = false
        editNotice = nil
        filesShortcutDismissed = false
        executionState.idleLimit = TimeInterval(editAutoReturnMinutes * 60)
        executionState.enterEdit()                                                  // jedyny zakres dostępny publicznie: wszystko tylko przez Kosz
        recordModeAudit(message: String(localized: "Włączono tryb Edycja (zakres: tylko „Przenieś do Kosza” – zaznaczone pliki, Porządki, odinstalowanie; powrót do odczytu po \(editAutoReturnMinutes) min bezczynności)."), origin: .user, mode: "edit")
        if monitorEditActivity { editMonitor.start(state: executionState) }
    }

    func leaveEditMode() {
        guard !isReadOnlyMode else { return }
        suppressAutoReturnNotice = true                      // powrót z woli użytkownika – bez komunikatu o bezczynności
        editNotice = nil
        executionState.leaveEdit()
        recordModeAudit(message: String(localized: "Wyłączono tryb Edycja – powrót do trybu tylko do odczytu."), origin: .user, mode: "readOnly")
    }

    func setEditAutoReturnMinutes(_ minutes: Int) {
        guard Self.autoReturnChoices.contains(minutes), minutes != editAutoReturnMinutes else { return }
        editAutoReturnMinutes = minutes
        executionState.idleLimit = TimeInterval(minutes * 60)
        history.setSetting(Self.autoReturnKey, String(minutes))
    }

    /// Wpis audytu przy KAŻDEJ zmianie trybu (kto, kiedy, zakres) – widoczny w Historii → Dziennik operacji.
    private func recordModeAudit(message: String, origin: CallOrigin, mode: String) {
        history.record(AuditRecord(callID: UUID().uuidString, tool: "set_execution_mode", argumentsJSON: "{\"mode\":\"\(mode)\"}", origin: origin, mode: .assistant, outcome: .executed, message: message))
        reloadHistory()
    }

    private func executionModeChanged(_ mode: ExecutionMode) {
        executionRevision += 1
        guard mode == .readOnly else { return }
        editMonitor.stop()
        if suppressAutoReturnNotice { suppressAutoReturnNotice = false }
        else {
            let limit = executionState.idleLimit                       // rzeczywisty limit, po którym wygasła sesja
            let after = limit >= 60 ? "\(Int(limit / 60)) min" : "\(Int(limit)) s"
            editNotice = String(localized: "Edycja wyłączona po \(after) bezczynności – wróciłem do trybu tylko do odczytu.")
            recordModeAudit(message: String(localized: "Edycja wyłączona automatycznie po \(after) bezczynności – powrót do trybu tylko do odczytu."), origin: .schedule, mode: "readOnly")
        }
    }

    // MARK: Historia

    @Published private(set) var scans: [HistoryStore.ScanRow] = []
    @Published private(set) var operations: [AuditRecord] = []
    @Published private(set) var quarantineEntries: [QuarantineEntry] = []
    @Published private(set) var measuredReclaimedTotal: Int64 = 0
    /// P2-17: nieudane zapisy/odczyty historii albo spisu kwarantanny – pokazywane w Historii zamiast przemilczenia.
    @Published private(set) var historyProblem: String?
    /// F22: porównania przed/po operacjach (najnowsze najpierw).
    @Published private(set) var benchmarks: [BenchmarkComparison] = []

    private var liveTask: Task<Void, Never>?
    private var started = false

    /// - Parameters:
    ///   - dataDir: katalog danych (historia, kwarantanna). Domyślnie ~/Library/Application Support/MacCare AI.
    ///   - home: katalog domowy, którego dotyczy skan czyszczenia (testy podają syntetyczny).
    /// - `tempDir`: katalog tymczasowy skanowany przez regułę „pliki tymczasowe”. **Domyślnie wynika z `home`**: dla prawdziwego
    ///   katalogu domowego to systemowy `$TMPDIR`, dla każdego innego (testy, tryb demonstracyjny) – podkatalog tego `home`.
    ///   Dzięki temu model z syntetycznym `home` nigdy nie skanuje (a więc nie ruszy) prawdziwego `$TMPDIR`.
    /// Kosz zastępczy (katalog) zamiast systemowego – tylko syntetyczny HOME (zrzuty, demonstracje).
    let usesSubstituteTrash: Bool

    init(dataDir: URL? = nil, home: String = NSHomeDirectory(), tempDir: String? = nil, sensorSampler: SensorSampling = PowerMetricsSampler(), monitorEditActivity: Bool = true, trash: TrashService? = nil) {
        usesSubstituteTrash = trash is DirectoryTrash
        DatalessPolicy.preventMaterialization()                                         // F9: skan nigdy nie pobiera plików z chmury (iCloud/File Provider)
        FileDescriptorLimit.raise()                                                       // audyt 16.10: zapas deskryptorów dla równoległego skanu
        self.home = home
        self.sensorSampler = sensorSampler
        self.monitorEditActivity = monitorEditActivity
        executionState = ExecutionGuard.current                      // produkcja: jedyny stan `ExecutionGuard.shared` (zawsze „tylko odczyt” po starcie); testy: wstrzyknięty
        let dir = dataDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacCare AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])   // try? świadomie: brak katalogu ⇒ kolejny zapis sam zgłosi błąd
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)   // try? świadomie: audyt 2 – dane tylko dla właściciela konta (także istniejący katalog)
        self.dataDir = dir
        let store: HistoryStore
        let dbPath = dir.appendingPathComponent("history.sqlite").path
        var warning: String?
        if let s = try? HistoryStore(path: dbPath, redactingHome: home) { store = s }   // try? świadomie: nieudane otwarcie ⇒ niżej archiwum uszkodzonej bazy albo baza w pamięci z ostrzeżeniem
        else if let archived = Self.archiveCorruptDatabase(dbPath), let s = try? HistoryStore(path: dbPath, redactingHome: home) {   // try? świadomie: nieudane otwarcie ⇒ niżej archiwum uszkodzonej bazy albo baza w pamięci z ostrzeżeniem
            // P2-7 (AUD-STAB-1): uszkodzony plik NIE jest kasowany – zostaje obok pod nową nazwą, a aplikacja zakłada nową, trwałą bazę
            store = s
            warning = String(localized: "Baza historii była uszkodzona. Zachowałem ją jako „\(archived)” w katalogu danych MacCare i założyłem nową – wcześniejsza historia i ustawienia nie są widoczne.")
        } else {
            store = try! HistoryStore(path: ":memory:", redactingHome: home)                     // ostatnia deska ratunku – aplikacja działa bez trwałej historii
            warning = String(localized: "Nie udało się otworzyć bazy historii – historia i ustawienia z tej sesji nie zostaną zapisane po zamknięciu aplikacji.")
        }
        storageWarning = warning
        history = store
        viewMode = ViewMode.stored(store.setting(ViewMode.storageKey))
        let autoReturn = Self.validAutoReturnMinutes(store.setting(Self.autoReturnKey))
        editAutoReturnMinutes = autoReturn
        executionState.idleLimit = TimeInterval(autoReturn * 60)
        let isRealHome = PathTools.canonical(home) == PathTools.canonical(NSHomeDirectory())
        let tmp = tempDir ?? (isRealHome ? NSTemporaryDirectory() : home + "/.tmp")
        if !isRealHome { precondition(PathTools.canonical(tmp) != PathTools.canonical(NSTemporaryDirectory()), "Syntetyczny HOME nie może używać prawdziwego $TMPDIR") }
        self.tempDir = tmp
        quarantine = QuarantineStore(root: dir.appendingPathComponent("quarantine", isDirectory: true), home: home, tempDir: tmp)
        provider = MacDiagnosticsProvider(history: store, settings: .init(home: home, tempDir: tmp))
        let actions = MacSystemActions(quarantine: quarantine, home: home)
        let registry = StandardTools.registry(provider: provider, actions: actions, quarantine: quarantine, trash: trash ?? MacTrash(home: home), home: home, tempDir: tmp, appDataDirs: [dir.path],
                                             runningApps: { await RunningApps.all() },          // F15: odinstalowanie tylko aplikacji, która nie działa
                                             installedApps: { [home] in                          // F20: pustej listy (nieczytelne katalogi) nie uznajemy za „nic nie zainstalowano”
                                                 let ids = Set(AppInventory.enumerate(home: home).map(\.bundleID).filter { !$0.isEmpty })
                                                 return ids.isEmpty ? nil : ids
                                             },
                                             appKnownToSystem: { AppInventory.launchServicesKnows($0) })      // audyt 2.2: aplikacja w dowolnym miejscu
        executor = ToolExecutor(registry: registry, policy: ApprovalPolicy(), mode: .assistant, audit: store)
        assistant = AssistantStore(executor: ToolExecutor(registry: registry, policy: ApprovalPolicy(), mode: .assistant, audit: store))
        diskMap = DiskMapStore(root: home, persistenceURL: dir.appendingPathComponent("diskmap-cache.lzfse"), home: home)   // F4: wynik mapy zapamiętany między uruchomieniami
        apps = AppsStore(home: home)
        executionObservation = executionState.observe { [weak self] mode in Task { @MainActor in self?.executionModeChanged(mode) } }
        purgeExpiredQuarantine()
        reloadHistory()
        diskMap.duplicateClones = APFSCloneInfo()                  // duplikaty: kopie APFS współdzielą dane – ich usunięcie nie zwalnia miejsca
        assistant.memory = { [weak self] in self?.snapshot?.memory }
        if diskMap.isCached(home) { phases[.files] = .result }               // F4: zapamiętana mapa jest widoczna od razu (stara jest odświeżana w tle)
        assistant.preferredModel = store.setting(Self.assistantModelKey)
        assistant.onPreferenceChange = { [weak self] v in self?.history.setSetting(Self.assistantModelKey, v) }
    }

    /// Przełączenie trybu widoku bez restartu; ten sam stan danych, inna prezentacja. Zapamiętywane w `HistoryStore.settings`.
    static let assistantModelKey = "assistant.model"

    func setViewMode(_ m: ViewMode) {
        guard m != viewMode else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            viewMode = m
            if !m.allows(module) { module = .smartScan }              // moduł niedostępny w Prostym ⇒ wróć do Smart Scan
        }
        history.setSetting(ViewMode.storageKey, m.rawValue)
    }

    /// Krok 1: pokaż arkusz zgody (co zostanie uruchomione). Samo kliknięcie przycisku niczego nie uruchamia.
    func requestDetailedSensors() {
        guard viewMode == .pro else { proModeHint = String(localized: "Szczegółowe czujniki są dostępne w trybie Profesjonalnym."); return }
        sensorConsentPresented = true
    }

    /// Krok 2: dopiero po potwierdzeniu w arkuszu zgody. Hasło trafia do systemowego okna, nie do MacCare; nic nie jest zapamiętywane.
    func confirmDetailedSensors() async {
        guard sensorConsentPresented, viewMode == .pro, sensors != .running else { return }
        sensorConsentPresented = false
        sensors = .running
        switch await sensorSampler.sample() {
        case .ok(let s): sensors = .done(s)
        case .cancelled: sensors = .cancelled
        case .failed(let m): sensors = .failed(m)
        case .unparsed: sensors = .unparsed
        }
    }

    func cancelDetailedSensorsConsent() { sensorConsentPresented = false }

    /// Liczba spraw tak, jak widzi ją użytkownik: w Prostym po scaleniu ustaleń tej samej reguły, w Profesjonalnym – wszystkie ustalenia.
    func issueCount(_ list: [Finding]) -> Int {
        viewMode == .simple ? simpleRecommendations(list, limit: .max).count : list.count
    }

    /// Rekomendacje prostym językiem (max 3) – akcje tylko o niskim ryzyku, reszta „wymaga trybu Profesjonalnego”.
    func simpleRecommendations(_ list: [Finding]? = nil, limit: Int = 3) -> [SimplePresentation.Recommendation] {
        SimplePresentation.recommendations(findings: list ?? findings, evidence: evidenceByID,
                                           riskOf: { [executor] in executor.registry.tool($0)?.spec.risk },
                                           reclaimable: scanResult?.safeReclaimable, limit: limit)
    }

    func phase(_ m: AppModule) -> ModulePhase { phases[m] ?? .start }
    func setPhase(_ m: AppModule, _ p: ModulePhase) { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { phases[m] = p } }
    func restart(_ m: AppModule) { setPhase(m, .start) }
    /// Przejście do modułu (np. z kafla wyniku „Przejrzyj”).
    func open(_ m: AppModule) { guard m.isBuilt else { return }; withAnimation(.easeInOut(duration: 0.4)) { module = m } }

    // MARK: Cykl życia
    // MARK: Widoczność okna (AUD-PERF-1)
    static let visibleLiveInterval: TimeInterval = 2
    static let hiddenLiveInterval: TimeInterval = 30
    /// Czy okno aplikacji jest widoczne (nieukryte, niezminimalizowane, nieprzesłonięte). Ukryta aplikacja odświeża dane rzadko i bez zbędnych przeliczeń widoków.
    private(set) var appVisible = true
    var liveInterval: TimeInterval { appVisible ? Self.visibleLiveInterval : Self.hiddenLiveInterval }
    private var occlusionObserver: NSObjectProtocol?

    func setAppVisible(_ visible: Bool) {
        guard visible != appVisible else { return }
        appVisible = visible
        Task { await provider.setBackground(!visible) }
        if started { restartLiveLoop() }                           // wybudza uśpioną pętlę: po pokazaniu okna dane odświeżają się od razu
    }

    private var windowOcclusionObserver: NSObjectProtocol?

    /// Czy widać jakiekolwiek okno MacCare poza ikoną w pasku menu (okno główne albo otwarty panel paska menu). Ikona paska menu (`NSStatusBarWindow`)
    /// jest zawsze „widoczna”, więc `NSApp.occlusionState` sam nie wystarcza – inaczej pętle nigdy nie zwalniałyby (P2-5).
    static func anyContentWindowVisible() -> Bool {
        guard let app = NSApp else { return true }
        return app.windows.contains { w in
            w.isVisible && w.occlusionState.contains(.visible) && !String(describing: type(of: w)).contains("StatusBar")
        }
    }

    private func observeVisibility() {
        guard occlusionObserver == nil else { return }
        let update: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.setAppVisible(Self.anyContentWindowVisible()) } }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main, using: update)
        windowOcclusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main, using: update)
        if NSApp != nil, !Self.anyContentWindowVisible() { setAppVisible(false) }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await provider.start() }
        observeVisibility()
        restartLiveLoop()
        if !ScreenshotDriver.isRequested { Task { await updates.checkIfDue() } }      // tylko gdy użytkownik włączył „raz w tygodniu”
    }

    private func restartLiveLoop() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLive()
                if n % 5 == 0 { await self.refreshFindings() }
                n += 1
                let interval = self.liveInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
            }
        }
    }

    func stop() { liveTask?.cancel(); liveTask = nil; started = false; Task { await provider.stop() } }

    // MARK: Panel
    func refreshLive() async {
        let s = await provider.snapshot()
        live.update(snapshot: s, evidence: await provider.evidence())
    }

    func refreshFindings() async {
        let fresh = await provider.findings()
        if fresh != findings { findings = fresh }                                        // audyt 2 (4.12): bez zmian = bez przeliczania widoków
        guard !ScreenshotDriver.isRequested else { return }                              // uruchomienia do zrzutów – bez powiadomień i bez sieci
        await updates.checkIfDue()                                                        // audyt P3: „raz w tygodniu” także, gdy aplikacja działa tygodniami (tanie, gdy nie pora)
        var newVersion: String?
        if case .available(let r) = updates.state { newVersion = r.tag }
        if notifier.enabled { notifier.evaluate(freeBytes: freeSpace(), findings: findings, newVersion: newVersion) }   // audyt 2: odczyt wolumenu tylko, gdy potrzebny
    }

    func evidence(_ id: String) -> Evidence? { evidenceByID[id] }

    private var iconCache: [String: NSImage] = [:]
    /// Ikona aplikacji grupy procesów (z pakietu .app; dla pozostałych – ogólna).
    func icon(for g: ProcessGroup) -> NSImage {
        let key = g.bundlePath ?? "generic"
        if let i = iconCache[key] { return i }
        let img = g.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) } ?? (NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
        iconCache[key] = img
        return img
    }

    // MARK: Zestawienia dla modułów i Smart Scan
    // Audyt 2 (3.7): ustalenia „stabilność” też mają swój moduł – powtarzające się awarie w Ochronie (zakładka awarii), zombie i czas bez restartu w Wydajności.
    var protectionFindings: [Finding] { Self.protection(findings) }
    var performanceFindings: [Finding] { Self.performance(findings) }
    static func protection(_ f: [Finding]) -> [Finding] { f.filter { [.security, .startup].contains($0.category) || ($0.category == .stability && $0.ruleID == "stability.crashes") } }
    static func performance(_ f: [Finding]) -> [Finding] { f.filter { [.cpu, .memory, .thermal, .battery].contains($0.category) || ($0.category == .stability && $0.ruleID != "stability.crashes") } }
    var cleanupFindings: [Finding] { findings.filter { [.storage, .cleanup].contains($0.category) } }

    /// Werdykt o stanie Maca – JEDNO źródło dla obu trybów (Prosty: „Wszystko OK / Wymaga uwagi / Pilne”, Profesjonalny: poniższe etykiety).
    /// Uwzględnia ocenę z jawną metodologią ORAZ nasilenie ustaleń (ostrzeżenie nie może dać „Dobry”).
    var healthStatus: SimplePresentation.Status? { SimplePresentation.status(assessment: assessment, findings: findings) }
    var stateLabel: String {
        switch healthStatus { case nil: return String(localized: "Zbieram dane"); case .ok?: return String(localized: "Dobry"); case .attention?: return String(localized: "Wymaga uwagi"); case .urgent?: return String(localized: "Krytyczny") }
    }
    var stateColor: Color { healthStatus?.color ?? Theme.Palette.textSecondary }
    /// Symbol w pasku menu zależny od stanu (kolor nie jest tam pokazywany).
    var menuBarSymbol: String {
        switch healthStatus { case .urgent?: return "exclamationmark.shield.fill"; case .attention?: return "shield.lefthalf.filled"; default: return "checkmark.shield" }
    }

    /// P2-4: przerwanie trwającego skanu (Smart Scan / Porządki) przyciskiem „Zatrzymaj”.
    private var scanCancel: CancelFlag?
    var canCancelScan: Bool { scanCancel != nil }
    func cancelScan() { scanCancel?.set() }

    func smartScan() async {
        guard scanStage == nil else { return }
        let cancel = CancelFlag(); scanCancel = cancel
        defer { scanCancel = nil }
        setPhase(.smartScan, .scanning)
        scanStage = String(localized: "Pomiary systemu…")
        await refreshLive()
        scanStage = String(localized: "Silnik reguł…")
        await refreshFindings()
        scanStage = String(localized: "Skan czyszczenia…")
        let r = await provider.cleanupScan(categories: nil, recordInHistory: false, cancel: cancel)
        applyScan(r)
        phases[.cleanup] = .result
        let health = assessment?.overall
        if r.isComplete { history.recordScan(kind: "smart", at: Date(), findings: findings, reclaimable: r.safeReclaimable, health: health) }
        smartSummary = SmartScanSummary(date: Date(), health: health, findings: findings.count, safeReclaimable: r.safeReclaimable, totalReclaimable: r.totalReclaimable)
        scanStage = nil
        setPhase(.smartScan, .result)
        reloadHistory()
    }

    // MARK: Ochrona i Wydajność (skany modułów)
    func scanProtection() async {
        guard phase(.protection) != .scanning else { return }
        setPhase(.protection, .scanning)
        moduleStage[.protection] = String(localized: "Sprawdzam zabezpieczenia, autostart i podpisy programów…")
        await provider.refreshEnrichmentNow()
        await refreshLive(); await refreshFindings()
        moduleStage[.protection] = nil
        setPhase(.protection, .result)
    }

    func scanPerformance() async {
        guard phase(.performance) != .scanning else { return }
        setPhase(.performance, .scanning)
        moduleStage[.performance] = String(localized: "Mierzę obciążenie procesora, pamięci i baterii…")
        await refreshLive()
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
        await refreshLive(); await refreshFindings()
        moduleStage[.performance] = nil
        setPhase(.performance, .result)
    }

    // MARK: Czyszczenie
    func scanCleanup() async {
        guard !cleanupScanning else { return }
        cleanupScanning = true
        let cancel = CancelFlag(); scanCancel = cancel
        defer { scanCancel = nil }
        setPhase(.cleanup, .scanning)
        let r = await provider.cleanupScan(categories: nil, recordInHistory: true, cancel: cancel)
        applyScan(r)
        cleanupScanning = false
        setPhase(.cleanup, .result)
        reloadHistory()
    }

    private func applyScan(_ r: CleanupScanResult) {
        scanResult = r
        // Domyślnie zaznaczone są wyłącznie elementy bezpieczne (odtwarzalne, niskie ryzyko, aplikacja nie działa).
        selection = Set(r.candidates.filter { $0.safeToRemove }.map { $0.path })
    }

    var candidates: [CleanupCandidate] { scanResult?.candidates ?? [] }
    /// Kandydaci widoczni w bieżącym trybie: w Prostym tylko ryzyko ≤ niskie (średnie/wysokie – dopiero w Profesjonalnym).
    var visibleCandidates: [CleanupCandidate] { viewMode == .simple ? candidates.filter { $0.risk <= .low } : candidates }
    var hiddenByModeCount: Int { candidates.count - visibleCandidates.count }
    var selectedCandidates: [CleanupCandidate] { visibleCandidates.filter { selection.contains($0.path) } }
    var selectedReclaimable: UInt64 { selectedCandidates.reduce(0) { $0 + $1.reclaimableSize } }

    func toggle(_ c: CleanupCandidate) {
        guard !c.ownerRunning else { return }
        if selection.contains(c.path) { selection.remove(c.path) } else { selection.insert(c.path) }
    }

    func selectSafe(in category: CleanupCategory) {
        let paths = candidates.filter { $0.category == category && $0.safeToRemove }.map { $0.path }
        selection.formUnion(paths)
    }

    func clearSelection(in category: CleanupCategory) {
        selection.subtract(candidates.filter { $0.category == category }.map { $0.path })
    }

    static let maxPathsPerCall = 500

    /// Przygotowuje operację przez executor – nic nie jest wykonywane, dopóki użytkownik nie zatwierdzi arkusza.
    func proposeCleanup() async {
        let chosen = selectedCandidates.filter { $0.removal != .permanent && !$0.ownerRunning }.sorted { $0.reclaimableSize > $1.reclaimableSize }
        guard !chosen.isEmpty else { return }
        let paths = chosen.prefix(Self.maxPathsPerCall).map { $0.path }
        // Decyzja właściciela 15.10.2026: Porządki przez Kosz (zakres produkcyjny `.trashOperations`). Kwarantanna – tylko gdy zakres ją obejmuje
        // (dziś wyłącznie `.full`, nieosiągalny z interfejsu: testy mechanizmu kwarantanny w piaskownicy).
        let call = ExecutionGuard.allows(.quarantineMove)
            ? ToolCall(name: "quarantine_cleanup_items", arguments: ["paths": .array(paths.map { .string($0) }), "only_safe": .bool(false)])
            : ToolCall(name: "trash_cleanup_items", arguments: ["paths": .array(paths.map { .string($0) })])
        await propose(call)
    }

    func proposeEmptyTrash() async { await propose(ToolCall(name: "empty_trash")) }

    func propose(_ call: ToolCall) async {
        // Prosty: operacje o ryzyku średnim/wysokim niedostępne nawet jako podgląd (obrona w głąb – UI w ogóle ich nie oferuje).
        if viewMode == .simple {
            guard let risk = executor.registry.tool(call.name)?.spec.risk, risk <= .low else {
                proModeHint = String(localized: "Ta operacja jest dostępna w trybie Profesjonalnym.")
                return
            }
        }
        switch await executor.handle(call, origin: .user) {
        case .needsApproval(let p):
            pending = p
            // Audyt 2 (3.12): podgląd operacji przez Kosz bez żadnego elementu (np. odmowa: aplikacja działa) – nie ma czego zatwierdzać.
            let nothing = Self.measuredTools.contains(p.call.name) && p.preview.affectedItems.isEmpty
            sheet = SheetContent(toolName: p.call.name, preview: p.preview, permissions: p.spec.permissions, separate: p.separateCategories,
                                 origin: Self.originLabel(p.origin), readOnly: nothing,
                                 reason: nothing ? (p.preview.warnings.first ?? String(localized: "Nic nie zostanie zmienione.")) : nil)
        case .previewOnly(let pv, let reason):
            let spec = executor.registry.tool(call.name)?.spec
            let op = executor.registry.tool(call.name)?.operation ?? .unclassified
            let canEnable = ExecutionGuard.editWouldAllow(op)
            let future = (!canEnable && ExecutionGuard.isReadOnly) ? String(localized: "Ta operacja będzie dostępna dopiero po zakończeniu poprawek bezpieczeństwa kwarantanny – tryb Edycja jej jeszcze nie odblokuje.") : nil   // np. kwarantanna, opróżnianie Kosza
            sheet = SheetContent(toolName: call.name, preview: pv, permissions: spec?.permissions ?? [], separate: spec?.sensitive ?? [],
                                 origin: String(localized: "zlecił użytkownik"), readOnly: true, reason: reason, canEnableEdit: canEnable, futureNote: future)
        case .completed(let r): lastReport = OperationReport(title: Self.reportTitle(call.name), success: r.success, message: r.summary, tool: call.name)
        case .rejected(let m): lastReport = OperationReport(title: Self.reportTitle(call.name), success: false, message: String(localized: "Odrzucono: \(m)"), tool: call.name)
        case .failed(let m): lastReport = OperationReport(title: Self.reportTitle(call.name), success: false, message: String(localized: "Błąd: \(m)"), tool: call.name)
        }
        reloadHistory()          // każda próba (także odrzucona lub tylko podgląd) zostawia ślad w dzienniku audytu
    }

    /// Audyt 2 (P3): pochodzenie operacji po polsku/angielsku zamiast surowego `user`/`llm`.
    static func originLabel(_ o: CallOrigin) -> String {
        switch o {
        case .user: return String(localized: "zlecił użytkownik")
        case .llm: return String(localized: "zaproponował asystent AI")
        case .schedule: return String(localized: "zaplanowane")
        case .rule: return String(localized: "z reguły")
        }
    }

    static func reportTitle(_ tool: String) -> String {
        switch tool {
        case "trash_selected": return String(localized: "Przeniesienie do Kosza")
        case "trash_cleanup_items": return String(localized: "Porządki – przeniesienie do Kosza")
        case "uninstall_app_to_trash": return String(localized: "Odinstalowanie aplikacji")
        case "trash_app_leftovers": return String(localized: "Pozostałości po aplikacjach do Kosza")
        default: return tool
        }
    }

    /// „Przenieś do Kosza” dla elementów zaznaczonych w Moich plikach (W5). Odciski zaznaczenia (lstat) trafiają do narzędzia, które sprawdza je ponownie tuż przed operacją.
    /// `includeCloud`: osobny przełącznik „Także pliki w chmurze” (domyślnie wyłączony – pliki w chmurze są pomijane).
    func proposeTrashSelected(includeCloud: Bool = false) async {
        let paths = diskMap.selectedPaths
        guard !paths.isEmpty else { return }
        filesReportDismissed()
        guard paths.count <= TrashSelectedTool.maxItems else {                             // audyt 2 (3.10): jasny komunikat zamiast odrzucenia całości
            lastReport = OperationReport(title: String(localized: "Za dużo zaznaczonych elementów"), success: false,
                                         message: String(localized: "Zaznaczono \(paths.count) elementów – jednorazowo można przenieść najwyżej \(TrashSelectedTool.maxItems). Zaznacz folder zamiast pojedynczych plików albo podziel operację."),
                                         tool: "trash_selected")
            return
        }
        var args: [String: JSONValue] = ["paths": .array(paths.map { .string($0) }), "fingerprints": .array(diskMap.fingerprints(for: paths).map { .string($0) })]
        if includeCloud { args["include_cloud"] = true }
        await propose(ToolCall(name: "trash_selected", arguments: args))
    }

    /// F15: odinstalowanie przez Kosz – aplikacja (z odciskiem pakietu z chwili wyboru) i dane wybrane przez użytkownika. Narzędzie sprawdza wszystko ponownie.
    /// F20: zaznaczone pozostałości po odinstalowanych aplikacjach – z odciskami z chwili wyboru (zmiana przed wykonaniem ⇒ odmowa dla elementu).
    func proposeLeftovers(paths: [String]) async {
        let pairs = paths.compactMap { p in FileFingerprint(path: p).map { (p, $0.encoded) } }
        guard !pairs.isEmpty else { return }
        await propose(ToolCall(name: "trash_app_leftovers", arguments: ["items": .array(pairs.map { .string($0.0) }), "fingerprints": .array(pairs.map { .string($0.1) })]))
    }

    func proposeUninstall(appPath: String, items: [String]) async {
        guard let fp = FileFingerprint(path: appPath)?.encoded else { return }
        await propose(ToolCall(name: "uninstall_app_to_trash", arguments: ["app_path": .string(appPath), "app_fingerprint": .string(fp), "items": .array(items.map { .string($0) })]))
    }

    /// Zamyka raport z Kosza pokazany w Moich plikach.
    func filesReportDismissed() { if lastReport?.tool == "trash_selected" { lastReport = nil } }

    func approve(confirmed: Set<SensitiveCategory>) async {
        guard let p = pending, !operationRunning else { return }
        operationRunning = true
        let before = freeSpace()
        let measuredBefore = Self.measuredTools.contains(p.call.name) ? await measurementSet() : nil      // F22: pomiar przed (tylko operacje przez Kosz)
        let outcome = await executor.approve(p.id, confirmedCategories: confirmed)
        pending = nil
        sheet = nil
        let tool = p.call.name
        var movedPaths: [String]?                                                         // audyt 2 (4.1): co faktycznie trafiło do Kosza
        switch outcome {
        case .completed(let r):
            movedPaths = (r.data["moved"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            try? await Task.sleep(nanoseconds: 1_200_000_000)          // chwila na odświeżenie liczników wolumenu   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
            let delta: Int64? = before.flatMap { b in freeSpace().map { $0 - b } }
            let note = Self.measurementNote(tool: tool)
            // Do sumy „odzyskanego miejsca” trafia pomiar tylko z operacji, które FAKTYCZNIE zwalniają miejsce. Przeniesienie do
            // kwarantanny/Kosza to rename na tym samym dysku – zmierzona różnica to szum innych zapisów, więc nie jest zapisywana jako zysk.
            let frees = (tool == "empty_trash" || tool == "purge_quarantine")
            history.recordReclaimed(operation: p.preview.title, estimated: p.preview.estimatedBytes ?? 0, measured: frees ? delta : nil, note: note, at: Date())
            var report = OperationReport(title: p.preview.title, success: r.success, message: r.summary, estimatedBytes: p.preview.estimatedBytes,
                                         measuredDelta: delta, note: note, tool: tool)
            report.partial = r.data["partial"]?.boolValue == true            // P1-6: „częściowo” dla każdego narzędzia, które to zgłasza
            if tool == "trash_selected" || tool == "trash_cleanup_items" {
                // pamięć mapy (W1) korygowana bez pełnego skanu: element znika z listingu, rozmiar odjęty od przodków, zaznaczenie wyczyszczone
                let moved = r.data["moved"]?.arrayValue ?? []
                diskMap.itemsTrashed(moved.compactMap { m in m["path"]?.stringValue.map { (path: $0, bytes: UInt64(max(0, m["bytes"]?.numberValue ?? 0))) } })
                report.trashedPaths = moved.compactMap { $0["trash_path"]?.stringValue }.filter { !$0.isEmpty }
            }
            lastReport = report
            if let b = measuredBefore, !(r.data["moved"]?.arrayValue ?? []).isEmpty {          // audyt P3: pomiar tylko, gdy coś faktycznie przeniesiono
                history.recordBenchmark(BenchmarkAnalyzer.compare(operation: p.preview.title, before: b, after: await measurementSet(), decisive: Self.trashDecisive), at: Date())
            }
        case .rejected(let m): lastReport = OperationReport(title: p.preview.title, success: false, message: String(localized: "Odrzucono: \(m)"), tool: tool)
        case .failed(let m): lastReport = OperationReport(title: p.preview.title, success: false, message: String(localized: "Błąd: \(m)"), tool: tool)
        case .needsApproval, .previewOnly: break
        }
        operationRunning = false
        reloadHistory()
        if ["quarantine_cleanup_items", "trash_cleanup_items", "empty_trash", "restore_from_quarantine", "purge_quarantine"].contains(tool) {
            if tool == "trash_cleanup_items", let moved = movedPaths, var r = scanResult {
                // Audyt 2 (4.1): bez TRZECIEGO pełnego skanu (ok. 20 s pracy dysku) – przeniesione pozycje (i leżące w nich) znikają z wyniku,
                // jak w mapie dysku. Podgląd i wykonanie nadal weryfikują świeżym skanem (bezpieczeństwo).
                r.candidates.removeAll { c in moved.contains { c.path == $0 || PathTools.isWithin(c.path, $0) } }
                scanResult = r
                selection.removeAll()
            } else {
                if tool == "trash_cleanup_items" { selection.removeAll() }
                await scanCleanup()
            }
        }
        if tool == "uninstall_app_to_trash" || tool == "trash_app_leftovers" { await apps.load(force: true) }
    }

    func decline() async {
        if let p = pending { await executor.decline(p.id) }
        pending = nil
        sheet = nil
        reloadHistory()
    }

    /// Zamknięcie arkusza (także gestem). Gdy czekało zatwierdzenie – to równoznaczne z anulowaniem.
    func dismissSheet() async { await decline() }

    static func measurementNote(tool: String) -> String {
        switch tool {
        case "quarantine_cleanup_items":
            return String(localized: "Elementy trafiły do kwarantanny (przeniesienie w obrębie dysku) lub do Kosza – wolne miejsce zwiększy się dopiero po opróżnieniu kwarantanny (automatycznie po 7 dniach) lub Kosza. Pomiar obejmuje też inne zapisy na dysku.")
        case "empty_trash": return String(localized: "Zmiana zmierzona po opróżnieniu Kosza. Pomiar obejmuje też inne zapisy na dysku.")
        case "purge_quarantine": return String(localized: "Pomiar obejmuje też inne zapisy na dysku, a lokalne migawki Time Machine mogą wstrzymać zwrot miejsca.")
        case "trash_selected", "trash_cleanup_items": return String(localized: "Elementy trafiły do systemowego Kosza (przeniesienie w obrębie dysku) – wolne miejsce zwiększy się dopiero po opróżnieniu Kosza w Finderze. Możesz je stamtąd przywrócić (Odłóż).")
        default: return String(localized: "Pomiar obejmuje też inne zapisy na dysku.")
        }
    }

    /// Wolne miejsce faktycznie dostępne na wolumenie katalogu domowego (bez purgeable).
    func freeSpace() -> Int64? {
        (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map { Int64($0) }   // try? świadomie: brak wartości ⇒ nieznane
    }

    // MARK: Historia i kwarantanna
    func reloadHistory() {
        scans = history.scans(limit: 100)
        operations = history.operations(limit: 200)
        quarantineEntries = quarantine.entries.sorted { $0.quarantinedAt > $1.quarantinedAt }
        measuredReclaimedTotal = history.totalReclaimedMeasured()
        benchmarks = history.benchmarks(limit: 30)
        historyProblem = Self.historyProblem(failures: history.failureCount, lastError: history.lastError, manifestError: quarantine.lastManifestError)
    }

    // MARK: Pomiary przed/po (F22)
    /// Operacje, przed i po których mierzymy: przeniesienia do Kosza (miejsce wraca dopiero po opróżnieniu Kosza – stąd „Zmierz ponownie”).
    /// Przeniesienie do Kosza realnie zmienia tylko wolne miejsce (po opróżnieniu Kosza); szybkość procesora i plików to tło – nie wpływa na ocenę.
    static let trashDecisive: Set<BenchmarkMetric> = [.diskFreeBytes]
    static let measuredTools: Set<String> = ["trash_selected", "trash_cleanup_items", "uninstall_app_to_trash", "trash_app_leftovers", "empty_trash"]

    /// Wolne miejsce, pamięć i dwa mikropomiary po 3 próbki: stałe zadanie CPU i 200 małych plików we WŁASNYM katalogu danych aplikacji (`bench`).
    func measurementSet() async -> MeasurementSet {
        let free = freeSpace(), s = snapshot
        let dir = dataDir.appendingPathComponent("bench", isDirectory: true)
        let (cpu, files) = await Task.detached(priority: .utility) {
            ((0..<3).map { _ in MicroBenchmark.cpuWorkMs() }, (0..<3).compactMap { _ in MicroBenchmark.smallFileOpsMs(in: dir) })
        }.value
        var samples: [BenchmarkMetric: [Double]] = [.cpuWorkMs: cpu, .smallFileOpsMs: files]
        if let free { samples[.diskFreeBytes] = [Double(free)] }
        if let m = s?.memory { samples[.memoryUsedBytes] = [Double(m.used)]; samples[.swapUsedBytes] = [Double(m.swapUsed)] }
        return MeasurementSet(takenAt: Date(), samples: samples, onAC: s?.battery?.onAC, thermal: s?.thermal, backgroundCPUPercent: s?.cpu?.totalPercent)
    }

    /// Nowy pomiar „po” dla zapisanego porównania (np. po opróżnieniu Kosza w Finderze) – ten sam pomiar „przed”, ten sam identyfikator.
    func remeasure(_ id: String) async {
        guard let old = benchmarks.first(where: { $0.id == id }) else { return }
        var c = BenchmarkAnalyzer.compare(operation: old.operation, before: old.before, after: await measurementSet(), decisive: old.decisiveMetrics.map(Set.init))
        c.id = old.id
        history.recordBenchmark(c, at: Date())
        reloadHistory()
    }

    static func historyProblem(failures: Int, lastError: String?, manifestError: String?) -> String? {
        var parts: [String] = []
        if failures > 0 { parts.append(String(localized: "Część historii nie została zapisana lub odczytana (błędów: \(failures)). Ostatni: \(lastError ?? "—")")) }
        if let m = manifestError { parts.append(String(localized: "Nie udało się zapisać spisu kwarantanny – elementy są bezpieczne (opis leży obok każdego), ale spis może być nieaktualny: \(m)")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func proposeRestore(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await propose(ToolCall(name: "restore_from_quarantine", arguments: ["ids": .array(ids.map { .string($0) })]))
    }

    /// Trwałe usunięcie z kwarantanny – jak każda operacja przechodzi przez executor (podgląd w trybie tylko do odczytu,
    /// zatwierdzenie z osobnym potwierdzeniem „nieodwracalne” gdy zmiany będą dozwolone).
    func proposePurge(ids: Set<String>?) async {
        let target = ids ?? Set(quarantine.entries.map { $0.id })
        guard !target.isEmpty else { return }
        await propose(ToolCall(name: "purge_quarantine", arguments: ["ids": .array(target.sorted().map { .string($0) })]))
    }

    private func purgeExpiredQuarantine() {
        guard ExecutionGuard.allows(.quarantinePurge) else { return }          // odczyt i Edycja poza zakresem: nie usuwamy nawet przeterminowanej kwarantanny
        let expired = quarantine.entries.filter { Date().timeIntervalSince($0.quarantinedAt) >= 7 * 86400 }
        guard !expired.isEmpty else { return }
        let out = quarantine.purgeDetailed()
        recordPurgeAudit(count: expired.count - out.refused.count, bytes: out.freed, origin: .schedule)
        if !out.refused.isEmpty {
            history.record(AuditRecord(callID: UUID().uuidString, tool: "purge_quarantine", argumentsJSON: "{\"refused\":\(out.refused.count)}", origin: .schedule, mode: .assistant, outcome: .failed,
                                       message: String(localized: "Odrzucono \(out.refused.count) wpisów kwarantanny wskazujących poza jej katalog (uszkodzony lub podmieniony manifest) – nic z nich nie skasowano")))
        }
    }

    private func recordPurgeAudit(count: Int, bytes: UInt64, origin: CallOrigin) {
        history.record(AuditRecord(callID: UUID().uuidString, tool: "purge_quarantine", argumentsJSON: "{\"count\":\(count)}", origin: origin,
                                   mode: .assistant, outcome: .executed, message: String(localized: "Trwale usunięto \(Plural.elements(count)) z kwarantanny (\(ByteFormat.string(bytes)))")))
    }
}
