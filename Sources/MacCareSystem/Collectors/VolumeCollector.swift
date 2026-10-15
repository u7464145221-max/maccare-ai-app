#if os(macOS)
import Foundation
import MacCareCore

/// Wolumeny: `/` oraz zamontowane wewnętrzne, lokalne (bez ukrytych wolumenów systemowych).
enum VolumeCollector {
    static func read() -> [VolumeStats] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeStats] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
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

    private static func fsType(_ path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "?" }
        return withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
    }
}
#endif
