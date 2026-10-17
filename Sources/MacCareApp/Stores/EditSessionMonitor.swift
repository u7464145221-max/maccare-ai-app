import AppKit
import MacCareCore

/// Pilnuje sesji Edycji (W4): aktywność użytkownika (klik, klawisz, przewijanie) odsuwa automatyczny powrót do odczytu, a zegar sprawdza limit bezczynności.
/// Działa TYLKO, gdy Edycja jest włączona – w trybie odczytu nic nie chodzi w tle (nie dokłada pętli do AUD-PERF-1). Samo bezpieczeństwo nie zależy od tego zegara:
/// `ExecutionState.mode` wygasza wygasłą Edycję przy każdym odczycie, więc nawet bez zegara przeterminowana sesja niczego nie dopuści.
@MainActor
final class EditSessionMonitor {
    private var eventMonitor: Any?
    private var task: Task<Void, Never>?

    func start(state: ExecutionState, interval: TimeInterval = 5) {
        stop()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { event in
            state.noteActivity()
            return event
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
                if Task.isCancelled { return }
                if state.mode == .readOnly { self?.stop(); return }               // odczyt `mode` wygasza przeterminowaną Edycję i powiadamia obserwatorów
            }
        }
    }

    func stop() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
        task?.cancel(); task = nil
    }
}
