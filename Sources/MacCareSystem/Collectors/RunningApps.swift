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
