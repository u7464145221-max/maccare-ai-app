#if os(macOS)
import Foundation
import MacCareCore

/// Wolumeny: `/` oraz zamontowane wewnętrzne, lokalne (bez ukrytych wolumenów systemowych).
enum VolumeCollector {
    static func read() -> [VolumeStats] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey]
        // 18.10 (zgłoszenie właściciela): `mountedVolumeURLs(includingResourceValuesForKeys:)` pobierał pojemność WSZYSTKICH wolumenów, także
        // sieciowych – już to wywoływało pytanie macOS o dostęp do plików na woluminie sieciowym (choć sieciowe i tak były potem odrzucane).
        // Teraz lista montowań z tablicy jądra (`getfsstat`, bez dotykania samych dysków), a wartości – tylko dla lokalnych.
        let urls = localMountPoints().map { URL(fileURLWithPath: $0, isDirectory: true) }
        var out: [VolumeStats] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }   // try? świadomie: brak wartości ⇒ nieznane
            let path = u.path
            let isRoot = path == "/"
            guard isRoot || (v.volumeIsLocal == true && v.volumeIsInternal == true && !path.hasPrefix("/System/Volumes")) else { continue }
            let total = UInt64(max(0, v.volumeTotalCapacity ?? 0))
            guard total > 0 else { continue }
            out.append(VolumeStats(mountPoint: path, name: v.volumeName ?? path, total: total,
                                   availableImportant: UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0)),
                                   availableStrict: UInt64(max(0, v.volumeAvailableCapacity ?? 0)),
                                   fileSystem: fsType(path), isInternal: v.volumeIsInternal ?? false))
        }
        return out.sorted { $0.mountPoint == "/" ? true : ($1.mountPoint == "/" ? false : $0.mountPoint < $1.mountPoint) }
    }

    /// Punkty montowania lokalnych wolumenów (`MNT_LOCAL`), bez ukrytych (`MNT_DONTBROWSE`) – z tablicy montowań, bez odczytu z dysków.
    static func localMountPoints() -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&mounts, MNT_NOWAIT)                                               // tablica jądra; bez odczytu z samych dysków
        guard n > 0, let m = mounts else { return ["/"] }
        return (0..<Int(n)).compactMap { i -> String? in
            let fs = m[i], path = mountPath(fs)
            guard fs.f_flags & UInt32(MNT_LOCAL) != 0, fs.f_flags & UInt32(MNT_DONTBROWSE) == 0 || path == "/" else { return nil }
            return path
        }
    }

    static func mountPath(_ fs: statfs) -> String {
        var f = fs
        return withUnsafePointer(to: &f.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    }

    private static func fsType(_ path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "?" }
        return withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
    }
}
#endif
