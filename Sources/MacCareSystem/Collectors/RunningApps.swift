#if os(macOS)
import AppKit
import Darwin
import MacCareCore

/// Działające aplikacje do ochrony przy czyszczeniu: aplikacje z okna (`NSWorkspace`) oraz właściciele WSZYSTKICH odczytywalnych procesów –
/// procesy pomocnicze i działające bez okna przypisane do zewnętrznego pakietu `.app` (`RunningOwners`). Tylko odczyt.
public enum RunningApps {
    public static func processOwnerBundleIDs() -> Set<String> {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var paths: [String] = []
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            buf[0] = 0
            if proc_pidpath(pid, &buf, 4096) > 0 { paths.append(String(cString: buf)) }
        }
        return RunningOwners.bundleIDs(executables: paths) { Bundle(path: $0)?.bundleIdentifier }
    }

    /// P2-3: znaczniki pracujących narzędzi wiersza poleceń (`ToolActivity.allTokens`) – z procesów TEGO konta: nazwa programu i nazwy plików
    /// z argumentów (`KERN_PROCARGS2`). Argumenty mogą zawierać dane wrażliwe, dlatego zostaje WYŁĄCZNIE dopasowany znacznik – nic innego
    /// nie jest przechowywane, zapisywane ani logowane.
    public static func runningToolTokens() -> Set<String> {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        let uid = getuid()
        var out = Set<String>()
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, bsd.pbi_uid == uid else { continue }
            pathBuf[0] = 0
            let exe = proc_pidpath(pid, &pathBuf, 4096) > 0 ? String(cString: pathBuf) : ""
            out.formUnion(ToolActivity.tokens(executable: exe, arguments: arguments(of: pid)))
        }
        return out
    }

    /// argv procesu (tylko do dopasowania znaczników – patrz wyżej).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size <= 1 << 20 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return ToolActivity.parseProcArgs(Array(buf.prefix(size)))
    }

    @MainActor
    public static func windowAppBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    public static func all() async -> Set<String> {
        let window = await MainActor.run { windowAppBundleIDs() }
        let owners = await Task.detached(priority: .utility) { processOwnerBundleIDs() }.value
        return window.union(owners)
    }
}
#endif
