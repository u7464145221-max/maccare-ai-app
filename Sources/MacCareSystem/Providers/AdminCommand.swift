#if os(macOS)
import Foundation
import MacCareCore

/// Operacje wymagające hasła administratora. Skrypt jest **stałym literałem** – nie ma interpolacji żadnych danych
/// wejściowych (od użytkownika ani od AI). Hasło wpisuje się w systemowym oknie autoryzacji przy każdej operacji.
enum AdminCommand: CaseIterable {
    case reindexSpotlightRoot
    case flushDNS
    /// Jednorazowa próbka czujników (moc CPU/GPU/ANE, częstotliwości, presja termiczna). To WYŁĄCZNIE odczyt.
    case powermetricsSample

    var script: String {
        switch self {
        case .reindexSpotlightRoot: return "do shell script \"/usr/bin/mdutil -E /\" with administrator privileges"
        case .flushDNS: return "do shell script \"/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder\" with administrator privileges"
        case .powermetricsSample: return "do shell script \"\(PowerMetricsSampler.commandLine)\" with administrator privileges"
        }
    }

    /// Operacja niczego nie zmienia w systemie. Tylko takie przechodzą w trybie tylko do odczytu (wyjątek zlecony przez właściciela –
    /// opcjonalne „Szczegółowe czujniki”). Lista jest jawna: nowa operacja domyślnie JEST zmieniająca i zostaje zablokowana.
    var isReadOnlyOperation: Bool {
        switch self {
        case .powermetricsSample: return true
        case .reindexSpotlightRoot, .flushDNS: return false
        }
    }

    enum Outcome: Equatable { case ok(String), cancelled, failed(String) }

    func run(timeout: TimeInterval = 180, runner: AdminScriptRunning = OsascriptRunner()) async -> Outcome {
        if !isReadOnlyOperation && !ExecutionGuard.allows(.adminCommand) { return .failed(ExecutionGuard.refusalMessage(for: .adminCommand)) }
        return await runner.run(script: script, timeout: timeout)
    }
}

/// Wykonawca skryptu z uprawnieniami administratora. Produkcja: `osascript` (systemowe okno hasła). Testy podstawiają atrapę –
/// żaden test nie otwiera okna hasła.
protocol AdminScriptRunning: Sendable {
    func run(script: String, timeout: TimeInterval) async -> AdminCommand.Outcome
}

struct OsascriptRunner: AdminScriptRunning {
    func run(script: String, timeout: TimeInterval) async -> AdminCommand.Outcome {
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch { cont.resume(returning: .failed(error.localizedDescription)); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit(); killer.cancel()
                if p.terminationStatus == 0 { cont.resume(returning: .ok(o.trimmingCharacters(in: .whitespacesAndNewlines))) }
                else if e.contains("-128") { cont.resume(returning: .cancelled) }
                else { cont.resume(returning: .failed(e.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
        }
    }
}
#endif
