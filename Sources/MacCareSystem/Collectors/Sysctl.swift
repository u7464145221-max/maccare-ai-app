#if os(macOS)
import Foundation

/// Cienkie, bezpieczne typowo opakowanie `sysctlbyname` (stałe nazwy, bez danych wejściowych od użytkownika).
enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var s = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &s, nil, 0) == 0 ? v : nil
    }

    static func string(_ name: String) -> String? {
        var s = 0
        guard sysctlbyname(name, nil, &s, nil, 0) == 0, s > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: s)
        guard sysctlbyname(name, &buf, &s, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func value<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T? {
        var v = initial
        var s = MemoryLayout<T>.size
        return sysctlbyname(name, &v, &s, nil, 0) == 0 ? v : nil
    }
}
#endif
