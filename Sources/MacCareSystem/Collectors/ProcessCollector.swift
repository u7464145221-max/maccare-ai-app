#if os(macOS)
import Foundation
import Darwin
import MacCareCore

/// Lista procesów przez libproc: CPU z delt czasu procesora, `phys_footprint`, I/O dyskowe, ścieżka pakietu .app.
struct ProcessCollector {
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevWall: UInt64 = 0
    private var tb = mach_timebase_info_data_t()
    private let uid = getuid()
    /// Procesy widoczne w systemie, ale bez pomiarów (libproc odmawia danych o procesach roota/innych użytkowników
    /// bez uprawnień). Nie są ujęte w próbkach – ich CPU/pamięć jest nieznane, nie zerowe.
    private(set) var unmeasuredCount = 0
    /// Audyt 2 (4.6): nazwa i ścieżka procesu nie zmieniają się między pomiarami – zapamiętane pod kluczem (pid, czas startu, nazwa z jądra).
    /// `exec` zmienia `pbi_comm`, więc nowy program w tym samym procesie dostaje nowy wpis. Wpisy zakończonych procesów są usuwane co pomiar.
    struct Identity: Hashable { let pid: Int32; let startSec: UInt64; let startUsec: UInt64; let comm: String }
    private var names: [Identity: (name: String, path: String)] = [:]
    /// Audyt 2 (4.6): pełna lista z jądra (zombie i liczba procesów bez pomiaru) zmienia się powoli – odświeżana co `kernEvery` pomiarów.
    static let kernEvery = 5
    private var sampleNo = 0
    private var kernCache: [KernProc] = []
    /// Liczba odczytów nazwy/ścieżki w ostatnim pomiarze (do testu pamięci podręcznej).
    private(set) var lastNameLookups = 0

    init() { mach_timebase_info(&tb) }

    private func ns(_ t: UInt64) -> UInt64 { t &* UInt64(tb.numer) / UInt64(max(tb.denom, 1)) }

    /// Ścieżka pakietu (.app lub .xpc), do którego należy plik wykonywalny (najwcześniejszy pakiet na ścieżce).
    static func bundlePath(of executable: String) -> String? {
        let hits = [".app/", ".xpc/"].compactMap { executable.range(of: $0) }
        guard let r = hits.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        return String(executable[..<executable.index(r.lowerBound, offsetBy: 4)])
    }

    /// `proc_name` zwraca nazwę ściętą do MAXCOMLEN (np. „com.apple.Virtualization.Virtua”). Gdy ostatni komponent ścieżki jest dłuższy
    /// i zaczyna się od tej nazwy – używamy pełnej nazwy z ścieżki.
    static func resolveName(procName: String, executablePath: String) -> String {
        let last = (executablePath as NSString).lastPathComponent
        if !procName.isEmpty, last.count > procName.count, last.hasPrefix(procName) { return last }
        return procName.isEmpty ? last : procName
    }

    mutating func sample() -> [ProcessSample] {
        let wall = ns(mach_absolute_time())
        let dWall = prevWall == 0 ? 0.0 : Double(wall &- prevWall)
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }

        var out: [ProcessSample] = []
        var newCPU: [Int32: UInt64] = [:]
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var nameBuf = [CChar](repeating: 0, count: 256)
        var pathBuf = [CChar](repeating: 0, count: 4096)
        var newNames: [Identity: (name: String, path: String)] = [:]
        var lookups = 0

        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }

            var cpuNs: UInt64 = 0
            var mem: UInt64 = 0
            var diskR: UInt64?, diskW: UInt64?
            var ru = rusage_info_current()
            let rr = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
            }
            if rr == 0 {                                                                   // audyt 2 (4.6): czas CPU z tego samego odczytu (te same jednostki co pti_total_*)
                cpuNs = ns(ru.ri_user_time &+ ru.ri_system_time)
                mem = ru.ri_phys_footprint; diskR = ru.ri_diskio_bytesread; diskW = ru.ri_diskio_byteswritten
            } else {
                var ti = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, taskSize) == taskSize {
                    cpuNs = ns(ti.pti_total_user &+ ti.pti_total_system)
                    mem = ti.pti_resident_size
                }
            }
            newCPU[pid] = cpuNs
            var cpu = 0.0
            if dWall > 0, let p = prevCPU[pid], cpuNs >= p { cpu = Double(cpuNs - p) / dWall * 100 }

            let comm = withUnsafePointer(to: &bsd.pbi_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            let key = Identity(pid: pid, startSec: bsd.pbi_start_tvsec, startUsec: bsd.pbi_start_tvusec, comm: comm)
            let name: String, path: String
            if let cached = names[key] { (name, path) = cached }
            else {
                lookups += 1
                nameBuf[0] = 0; pathBuf[0] = 0
                proc_name(pid, &nameBuf, 256)
                proc_pidpath(pid, &pathBuf, 4096)
                var n = String(cString: nameBuf)
                if n.isEmpty { n = comm }
                path = String(cString: pathBuf)
                n = Self.resolveName(procName: n, executablePath: path)
                name = n.isEmpty ? "pid \(pid)" : n
            }
            newNames[key] = (name, path)

            out.append(ProcessSample(pid: pid, parentPID: Int32(bsd.pbi_ppid), name: name, executablePath: path,
                                     bundlePath: Self.bundlePath(of: path), isCurrentUser: bsd.pbi_uid == uid, cpuPercent: cpu,
                                     memoryFootprint: mem, diskReadBytes: diskR, diskWriteBytes: diskW, energyImpactHint: nil,
                                     isZombie: bsd.pbi_status == 5,
                                     startedAt: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))))
        }
        prevCPU = newCPU
        prevWall = wall
        names = newNames
        lastNameLookups = lookups
        if sampleNo % Self.kernEvery == 0 { kernCache = Self.kernProcAll() }
        sampleNo += 1

        // Pełna lista z jądra (bez uprawnień): zombie spośród procesów, których libproc nie pozwolił zmierzyć.
        let seen = Set(out.map { $0.pid })
        var unmeasured = 0
        for k in kernCache where !seen.contains(k.pid) {
            unmeasured += 1
            if k.isZombie {
                out.append(ProcessSample(pid: k.pid, parentPID: k.ppid, name: k.name, isCurrentUser: k.uid == uid,
                                         cpuPercent: 0, memoryFootprint: 0, isZombie: true))
            }
        }
        unmeasuredCount = unmeasured
        return out
    }

    struct KernProc { let pid: Int32; let ppid: Int32; let uid: UInt32; let name: String; let isZombie: Bool }

    private static func kernProcAll() -> [KernProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        for _ in 0..<4 {                                   // lista może urosnąć między wywołaniami
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            size += 16 * MemoryLayout<kinfo_proc>.stride
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            var bytes = buf.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 3, &buf, &bytes, nil, 0) == 0 {
                return buf.prefix(bytes / MemoryLayout<kinfo_proc>.stride).map { k in
                    var comm = k.kp_proc.p_comm
                    let name = withUnsafePointer(to: &comm) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) } }
                    return KernProc(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid,
                                    name: name, isZombie: k.kp_proc.p_stat == SZOMB)
                }
            }
        }
        return []
    }
}
#endif
