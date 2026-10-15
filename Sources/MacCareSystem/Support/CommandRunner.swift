#if os(macOS)
import Foundation
import MacCareCore

/// Uruchamianie zewnętrznych poleceń **wyłącznie** z listy dozwolonych binarek (stała, bezwzględna ścieżka),
/// bez powłoki. Argumenty składa kod, nigdy tekst od użytkownika/AI. stderr jest odrzucany (nie miesza się z wynikiem).
public enum CommandRunner {
    public struct Result: Sendable {
        public let output: String; public let status: Int32; public let timedOut: Bool
        /// Wyjście przekroczyło limit (`maxOutputBytes`) – proces zatrzymano, `output` zawiera tylko początek. Wynik NIEPEŁNY.
        public var truncated = false
        init(output: String, status: Int32, timedOut: Bool, truncated: Bool = false) {
            self.output = output; self.status = status; self.timedOut = timedOut; self.truncated = truncated
        }
    }

    /// Górna granica odczytanego wyjścia (skill `maccare-command-allowlist`): największe dozwolone wyjście (`lsof`, `system_profiler`) ma kilka kB,
    /// więc 4 MB to zapas, a nie ograniczenie; chroni pamięć aplikacji przed nieoczekiwanie ogromnym wyjściem.
    public static let maxOutputBytes = 4 * 1024 * 1024

    /// Stałe, minimalne środowisko procesu potomnego zamiast dziedziczenia całego środowiska aplikacji: przewidywalny język wyjścia (parsery) niezależnie od
    /// tego, czy aplikację uruchomiono z Findera, czy z terminala, i żadnych zmiennych w rodzaju `DYLD_*` przekazanych z zewnątrz.
    /// Zgodność wyjścia sprawdzona na prawdziwym systemie: `Scripts/audit/command_env_parity.sh` (10 dozwolonych poleceń, identyczne wyjście).
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        for key in ["HOME", "USER", "TMPDIR"] { if let v = base[key] { env[key] = v } }
        return env
    }

    /// Zakończenie procesu: najpierw SIGTERM, po 2 s – gdy nadal działa – SIGKILL (proces ignorujący SIGTERM nie zawiesi kolektora).
    static func stop(_ p: Process, grace: TimeInterval = 2) {
        guard p.isRunning else { return }
        p.terminate()
        let end = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Każdy wpis to polecenie tylko do odczytu (lub, dla launchctl, odczyt stanu; zapisy dodaje T4 osobno).
    static let allowed: Set<String> = [
        "/usr/bin/csrutil", "/usr/sbin/spctl", "/usr/bin/fdesetup",
        "/usr/libexec/ApplicationFirewall/socketfilterfw", "/usr/sbin/softwareupdate",
        "/bin/launchctl", "/usr/sbin/lsof", "/usr/sbin/scutil",
        "/usr/sbin/system_profiler", "/usr/bin/tmutil"
    ]

    /// Dozwolone podpolecenia (tylko odczyt). Każde narzędzie z listy ma też warianty zmieniające system (`softwareupdate -i`, `csrutil disable`,
    /// `fdesetup enable`, `spctl --master-disable`, `socketfilterfw --setglobalstate` …), dlatego dopuszczone są WYŁĄCZNIE zestawy argumentów
    /// używane przez kod (F12, obrona warstwowa – argumenty i tak składa program, nie użytkownik ani AI). `launchctl` ma osobną bramkę w `run`.
    static let exactArguments: [String: [[String]]] = [
        "/usr/bin/csrutil": [["status"]],
        "/usr/bin/fdesetup": [["status"]],
        "/usr/sbin/spctl": [["--status"]],
        "/usr/sbin/softwareupdate": [["--schedule"]],
        "/usr/libexec/ApplicationFirewall/socketfilterfw": [["--getglobalstate"], ["--getstealthmode"]],
        "/usr/sbin/lsof": [["-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"]],
        "/usr/sbin/scutil": [["--dns"]],
        "/usr/sbin/system_profiler": [["SPPowerDataType", "-json"]],
    ]

    static func subcommandAllowed(_ binary: String, _ args: [String]) -> Bool {
        switch binary {
        case "/usr/bin/tmutil": return args.first.map { ["listlocalsnapshots", "listlocalsnapshotdates"].contains($0) } ?? false
        case "/bin/launchctl": return true                                                  // bramka print/bootout w `run`
        default: return exactArguments[binary]?.contains(args) ?? false
        }
    }

    public static func run(_ binary: String, _ args: [String], timeout: TimeInterval = 10, maxOutputBytes: Int = CommandRunner.maxOutputBytes) async -> Result {
        guard allowed.contains(binary) else { return Result(output: "", status: -2, timedOut: false) }
        guard subcommandAllowed(binary, args) else { return Result(output: "", status: -3, timedOut: false) }
        // launchctl: odczyt (`print`) zawsze; `bootout` (zmiana stanu systemu) tylko, gdy `ExecutionGuard` dopuszcza `.serviceBootout`. Inne podpolecenia – nigdy.
        if binary == "/bin/launchctl" {
            let verb = args.first ?? ""
            guard verb == "print" || (verb == "bootout" && ExecutionGuard.allows(.serviceBootout)) else { return Result(output: "", status: -3, timedOut: false) }
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = args
                p.environment = environment()
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: Result(output: "", status: -1, timedOut: false)); return }
                let flag = TimeoutFlag()
                // P3-11 (AUD-TEST-1b): strażnik limitu na WŁASNYM wątku (nie w puli GCD) – pod obciążeniem kolejka globalna bywała zajęta i zabójca
                // uruchamiał się dopiero po zakończeniu polecenia. Semafor budzi strażnika od razu, gdy proces skończy się wcześniej.
                let finished = DispatchSemaphore(value: 0)
                let killer = Thread {
                    if finished.wait(timeout: .now() + timeout) == .timedOut, p.isRunning { flag.set(); stop(p) }
                }
                killer.start()
                // Odczyt porcjami z limitem: po przekroczeniu proces jest zatrzymywany, a wynik oznaczony jako niepełny (`truncated`).
                var data = Data(), truncated = false
                let reader = out.fileHandleForReading
                while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    if data.count + chunk.count > maxOutputBytes {
                        data.append(chunk.prefix(max(0, maxOutputBytes - data.count)))
                        truncated = true
                        stop(p)
                        break
                    }
                    data.append(chunk)
                }
                p.waitUntilExit()
                finished.signal()
                cont.resume(returning: Result(output: String(decoding: data, as: UTF8.self), status: p.terminationStatus, timedOut: flag.value, truncated: truncated))
            }
        }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }
}
#endif
