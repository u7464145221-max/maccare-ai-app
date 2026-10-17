import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Flagi pliku z `lstat` (F9, z PureMac): elementy chronione przez system i pliki z chmury nieobecne na dysku.
public enum FileFlags {
    #if canImport(Darwin)
    /// SIP (`SF_RESTRICTED`), niezmienialne (`SF/UF_IMMUTABLE`) i tylko-do-dopisywania (`SF/UF_APPEND`) – MacCare ich nie rusza.
    public static let systemProtectedMask = UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | SF_APPEND | UF_APPEND)
    public static let datalessMask = UInt32(SF_DATALESS)

    public static func of(_ path: String) -> UInt32? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_flags : nil
    }
    #else
    public static let systemProtectedMask: UInt32 = 0
    public static let datalessMask: UInt32 = 0
    public static func of(_ path: String) -> UInt32? { nil }
    #endif

    public static func isSystemProtected(_ path: String) -> Bool { (of(path) ?? 0) & systemProtectedMask != 0 }
    /// Plik lub folder z chmury (iCloud/File Provider) obecny tylko jako zapowiedź – dane są na serwerze.
    public static func isDataless(_ path: String) -> Bool { (of(path) ?? 0) & datalessMask != 0 }
}

/// F9: MacCare nigdy nie wywołuje pobierania plików z chmury. Polityka procesu `IOPOL_MATERIALIZE_DATALESS_FILES_OFF`:
/// odczyt pliku lub folderu nieobecnego na dysku kończy się błędem zamiast ściągania danych (skan raportuje go wtedy jako nieczytelny – wynik niepełny).
public enum DatalessPolicy {
    @discardableResult
    public static func preventMaterialization() -> Bool {
        #if canImport(Darwin)
        return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        #else
        return true
        #endif
    }

    public static var isPrevented: Bool {
        #if canImport(Darwin)
        return getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        #else
        return true
        #endif
    }
}

/// Audyt 16.10 (P2): równoległy pomiar mapy trzyma otwarte katalogi (pomiar na ~/Library: szczyt +75 deskryptorów). Aplikacje z okienkiem startują
/// zwykle z miękkim limitem 256 – razem z bazą, FSEvents i potokami poleceń zapas byłby niewielki. Proces MacCare podnosi WŁASNY miękki limit
/// (w granicach twardego limitu systemu, najwyżej do `target`) – dotyczy tylko tego procesu, niczego w systemie nie zmienia.
public enum FileDescriptorLimit {
    /// Zwraca miękki limit po zmianie (albo bieżący, gdy już był wystarczający).
    @discardableResult
    public static func raise(to target: UInt64 = 4096) -> UInt64 {
        #if canImport(Darwin)
        var l = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &l) == 0 else { return 0 }
        let wanted = min(target, l.rlim_max)
        guard l.rlim_cur < wanted else { return l.rlim_cur }
        var n = l; n.rlim_cur = wanted
        return setrlimit(RLIMIT_NOFILE, &n) == 0 ? wanted : l.rlim_cur
        #else
        return 0
        #endif
    }
}
