import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Flaga przerwania długiej operacji (P2-4): ustawiana z interfejsu, sprawdzana w pętli skanera. `Task.detached` nie dziedziczy anulowania zadania,
/// więc przerwanie przekazujemy jawnie. Bezpieczna wątkowo.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}

/// Zakres trybu Edycja (W4). Zakres to osobna, nieprzekraczalna bariera: nawet przy włączonej Edycji operacja spoza zakresu jest odrzucana przez każdą warstwę.
public enum EditScope: String, Sendable, CaseIterable {
    /// Pierwotny zakres W4/W5: wyłącznie „Przenieś do Kosza” dla plików, które użytkownik sam zaznaczył w „Moje pliki”. Zostaje jako zakres testowy i wzorzec.
    case trashSelectedOnly
    /// ZAKRES PRODUKCYJNY od decyzji właściciela z 15.10.2026: wszystko wyłącznie przez systemowy Kosz (przywracalne z Findera) – pliki zaznaczone
    /// w „Moje pliki”, pozycje zaznaczone w Porządkach i odinstalowanie aplikacji. Kwarantanna, opróżnianie Kosza, zamykanie aplikacji, agenci
    /// autostartu i polecenia administratora – nadal poza zakresem.
    case trashOperations
    /// Wszystko, co przechodzi przez kwarantannę, trwałe usuwanie, opróżnianie Kosza, agentów autostartu i polecenia administratora.
    /// **Nieosiągalny z interfejsu** – wolno go włączyć wyłącznie decyzją właściciela po zamknięciu AUD-DEL-1…8 (Paczka 1 planu naprawczego).
    case full

    /// Zakres włączany z interfejsu (jedyny osiągalny w produkcji). `.full` nie jest osiągalny z interfejsu.
    public static let production: EditScope = .trashOperations

    public func allows(_ op: MutatingOperation) -> Bool {
        switch self {
        case .trashSelectedOnly: return op == .trashSelected
        case .trashOperations: return [.trashSelected, .cleanupToTrash, .uninstallToTrash, .leftoversToTrash].contains(op)
        case .full: return true
        }
    }
}

/// Tryb wykonania: domyślnie (po każdym uruchomieniu) „tylko odczyt”.
public enum ExecutionMode: Equatable, Sendable {
    case readOnly
    case edit(EditScope)
    public var isReadOnly: Bool { self == .readOnly }
}

/// Każda operacja, która zmienia komputer albo trwale kasuje dane (także własne dane aplikacji). Każda warstwa pyta `ExecutionGuard` o SWOJĄ operację.
public enum MutatingOperation: String, Sendable, CaseIterable {
    /// „Przenieś do Kosza” dla ręcznie zaznaczonych plików (W5) – jedyna operacja odblokowana zakresem `.trashSelectedOnly`.
    case trashSelected
    /// Porządki: zaznaczone pozycje do systemowego Kosza (decyzja właściciela 15.10.2026).
    case cleanupToTrash
    /// Odinstalowanie aplikacji: pakiet i wybrane dane aplikacji do systemowego Kosza (decyzja właściciela 15.10.2026).
    case uninstallToTrash
    /// Pozostałości po odinstalowanych aplikacjach do systemowego Kosza (decyzja właściciela 15.10.2026, wieczór).
    case leftoversToTrash
    case quarantineMove, quarantineRestore
    /// Trwałe usunięcie wpisów kwarantanny (także automatyczne po 7 dniach).
    case quarantinePurge
    /// Odzyskiwanie po przerwaniu (`QuarantineStore.recoverInterrupted`) – może przenosić i kasować, więc w trybie odczytu nie działa.
    case quarantineRecover
    case emptyTrash
    case quitApp
    case disableLaunchAgent
    /// Zatrzymanie usługi systemowej (`bootout` w `CommandRunner`).
    case serviceBootout
    /// Polecenia z hasłem administratora (mdutil, dscacheutil, killall).
    case adminCommand
    /// Narzędzie typu `.action` bez przypisanej operacji – traktowane jak operacja wymagająca zakresu `.full` (domyślnie odmowa).
    case unclassified

    public var title: String {
        switch self {
        case .trashSelected: return String(localized: "Przenieś do Kosza")
        case .cleanupToTrash: return String(localized: "Porządki – przeniesienie do Kosza")
        case .uninstallToTrash: return String(localized: "Odinstalowanie aplikacji do Kosza")
        case .leftoversToTrash: return String(localized: "Pozostałości po aplikacjach do Kosza")
        case .quarantineMove: return String(localized: "Czyszczenie przez kwarantannę")
        case .quarantineRestore: return String(localized: "Przywrócenie z kwarantanny")
        case .quarantinePurge: return String(localized: "Trwałe usunięcie z kwarantanny")
        case .quarantineRecover: return String(localized: "Odzyskiwanie kwarantanny po awarii")
        case .emptyTrash: return String(localized: "Opróżnienie Kosza")
        case .quitApp: return String(localized: "Zamknięcie aplikacji")
        case .disableLaunchAgent: return String(localized: "Wyłączenie agenta autostartu")
        case .serviceBootout: return String(localized: "Zatrzymanie usługi systemowej (launchd)")
        case .adminCommand: return String(localized: "Polecenie administratora")
        case .unclassified: return String(localized: "Operacja niesklasyfikowana")
        }
    }
}

/// Stan wykonania aplikacji – JEDNO źródło prawdy o tym, czy MacCare może cokolwiek zmieniać. Nie jest zapisywany: każde uruchomienie zaczyna w „tylko odczyt”.
/// Bezczynność w Edycji dłuższa niż `idleLimit` (domyślnie 15 min) cofa stan do odczytu – sprawdzane przy KAŻDYM odczycie trybu (niezależnie od zegara interfejsu).
public final class ExecutionState: @unchecked Sendable {
    public static let defaultIdleLimit: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var _mode: ExecutionMode = .readOnly
    private var _lastActivity: Date
    private var _idleLimit: TimeInterval
    private let now: @Sendable () -> Date
    private var observers: [UUID: @Sendable (ExecutionMode) -> Void] = [:]

    /// Zegar monotoniczny (skill `maccare-edit-mode-guard`): `CLOCK_MONOTONIC` rośnie także w czasie uśpienia Maca i NIE cofa się po zmianie zegara
    /// systemowego – cofnięcie godziny nie wydłuży Edycji, a uśpienie się do bezczynności wlicza. Zwracana „data” służy wyłącznie do odejmowania.
    public static func monotonicNow() -> Date {
        #if canImport(Darwin)
        return Date(timeIntervalSince1970: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9)
        #else
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        return Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
        #endif
    }

    public init(idleLimit: TimeInterval = ExecutionState.defaultIdleLimit, now: @escaping @Sendable () -> Date = { ExecutionState.monotonicNow() }) {
        self.now = now; _idleLimit = idleLimit; _lastActivity = now()
    }

    /// Efektywny tryb. Wygasła Edycja wraca tu do odczytu (i powiadamia obserwatorów).
    public var mode: ExecutionMode {
        let (m, changed) = lock.withLock { () -> (ExecutionMode, Bool) in
            if case .edit = _mode, now().timeIntervalSince(_lastActivity) >= _idleLimit { _mode = .readOnly; return (.readOnly, true) }
            return (_mode, false)
        }
        if changed { notify(m) }
        return m
    }

    public var idleLimit: TimeInterval {
        get { lock.withLock { _idleLimit } }
        set { lock.withLock { _idleLimit = max(1, newValue) } }
    }

    /// Włącza Edycję w JEDYNYM zakresie dostępnym w produkcji: `.trashSelectedOnly` (interfejs wywołuje to dopiero po potwierdzeniu w arkuszu).
    /// Zakres `.full` NIE jest osiągalny publicznym API: wariant z zakresem jest `internal` (widoczny wyłącznie dla testów przez `@testable`),
    /// więc żaden kod aplikacji, narzędzi ani modelu AI nie może go włączyć – wymaga to świadomej zmiany kodu po decyzji właściciela.
    public func enterEdit() { enterEdit(EditScope.production) }

    func enterEdit(_ scope: EditScope) {
        let m = lock.withLock { () -> ExecutionMode in _mode = .edit(scope); _lastActivity = now(); return _mode }
        notify(m)
    }

    public func leaveEdit() {
        let changed = lock.withLock { () -> Bool in let was = _mode != .readOnly; _mode = .readOnly; return was }
        if changed { notify(.readOnly) }
    }

    /// Aktywność użytkownika (klik, klawisz, przewijanie) odsuwa automatyczny powrót do odczytu.
    /// Audyt 2 (pkt 2.2): wygaśnięcie sprawdzane PRZED odsunięciem – klik tuż po upływie limitu (np. w zostawionym arkuszu) nie ożywia Edycji.
    public func noteActivity() {
        let expired = lock.withLock { () -> Bool in
            if case .edit = _mode, now().timeIntervalSince(_lastActivity) >= _idleLimit { _mode = .readOnly; return true }
            _lastActivity = now(); return false
        }
        if expired { notify(.readOnly) }
    }

    /// Ile zostało do automatycznego powrotu do odczytu (nil w odczycie).
    public var remainingIdle: TimeInterval? {
        guard mode != .readOnly else { return nil }
        return lock.withLock { max(0, _idleLimit - now().timeIntervalSince(_lastActivity)) }
    }

    /// Wymusza sprawdzenie limitu bezczynności (zegar interfejsu); zwraca `true`, gdy właśnie wrócono do odczytu.
    @discardableResult public func enforceIdleLimit() -> Bool {
        let before = lock.withLock { _mode }
        return before != .readOnly && mode == .readOnly
    }

    public final class Observation: @unchecked Sendable {
        private let cancelAction: @Sendable () -> Void
        init(_ cancel: @escaping @Sendable () -> Void) { cancelAction = cancel }
        public func cancel() { cancelAction() }
        deinit { cancelAction() }
    }

    /// Powiadomienie o każdej zmianie trybu (wywoływane na wątku, który ją spowodował).
    public func observe(_ handler: @escaping @Sendable (ExecutionMode) -> Void) -> Observation {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return Observation { [weak self] in self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) } }
    }

    private func notify(_ mode: ExecutionMode) {
        let handlers = lock.withLock { Array(observers.values) }
        for h in handlers { h(mode) }
    }
}

/// Fasada, o którą pytają wszystkie warstwy (kwarantanna, Kosz, akcje systemowe, polecenia administratora, executor narzędzi).
///
/// Wcześniej: stała w kodzie `readOnly = true` – żadna operacja nigdy się nie wykonywała. Teraz: stan uruchomieniowy `ExecutionState` (zawsze „tylko odczyt” po starcie),
/// przełączany WYŁĄCZNIE przez interfejs po potwierdzeniu użytkownika, z zakresem `EditScope` (obecnie tylko Kosz dla zaznaczonych plików).
/// Model AI nie ma żadnego narzędzia zmieniającego tryb (test `ExecutionModeSwitchTests`).
public enum ExecutionGuard {
    public static let message = String(localized: "Tryb tylko do odczytu – MacCare nie wprowadza zmian w systemie")
    public static let scopeMessage = String(localized: "Poza zakresem Edycji – w trybie Edycja działa przenoszenie do Kosza (zaznaczone pliki, Porządki, odinstalowanie, pozostałości po aplikacjach); kwarantanna, opróżnianie Kosza i operacje systemowe czekają na poprawki bezpieczeństwa")

    /// Jedyny stan produkcyjny. Zawsze startuje w `.readOnly` (nie jest zapisywany ani odtwarzany).
    public static let shared = ExecutionState()

    /// Obejścia wyłącznie dla testów na piaskownicy: `internal` ⇒ osiągalne tylko przez `@testable import`. Task-local: obejmują tylko zadanie testu
    /// i jego potomków – równoległe testy się nie widzą.
    /// `testOverride`: `true` = tylko odczyt, `false` = Edycja w pełnym zakresie (dotychczasowe testy mutacji w piaskownicy).
    @TaskLocal static var testOverride: Bool? = nil
    /// Wstrzyknięcie całego stanu (zegar, limit bezczynności, konkretny zakres) – testy macierzy tryb × operacja.
    @TaskLocal static var testState: ExecutionState? = nil

    /// Stan obowiązujący w bieżącym zadaniu (w produkcji zawsze `shared`).
    public static var current: ExecutionState { testState ?? shared }

    public static var mode: ExecutionMode {
        if let s = testState { return s.mode }
        if let o = testOverride { return o ? .readOnly : .edit(.full) }
        return shared.mode
    }

    public static var isReadOnly: Bool { mode == .readOnly }

    public static func allows(_ op: MutatingOperation) -> Bool {
        switch mode {
        case .readOnly: return false
        case .edit(let scope): return scope.allows(op)
        }
    }

    /// Czy włączenie Edycji (w bieżącym zakresie) odblokowałoby tę operację – steruje skrótem „Włącz edycję…”.
    public static func editWouldAllow(_ op: MutatingOperation) -> Bool { mode == .readOnly && EditScope.production.allows(op) }

    /// Powód odmowy pokazywany użytkownikowi i zapisywany w audycie.
    public static func refusalMessage(for op: MutatingOperation) -> String {
        switch mode {
        case .readOnly: return message
        case .edit: return scopeMessage
        }
    }

    public static func refusal(for op: MutatingOperation) -> ActionError { ActionError(refusalMessage(for: op)) }

    /// Wejście do każdej operacji zmieniającej: rzuca odmowę, gdy tryb/zakres jej nie dopuszcza.
    public static func require(_ op: MutatingOperation) throws {
        guard allows(op) else { throw refusal(for: op) }
    }
}
