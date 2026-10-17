#if os(macOS)
import Foundation
import MacCareCore

/// Stan zabezpieczeń – tylko odczyt: csrutil, spctl, fdesetup, socketfilterfw, softwareupdate --schedule,
/// wersje XProtect, test FDA (próba otwarcia, bez czytania treści), porty nasłuchujące.
public struct SecurityCollector: Sendable {
    let xprotectBundlePlist: String
    let xprotectAppPlist: String
    let fdaProbePath: String

    public init(xprotectBundlePlist: String = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist",
                xprotectAppPlist: String = "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/Info.plist",
                fdaProbePath: String = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db") {
        self.xprotectBundlePlist = xprotectBundlePlist; self.xprotectAppPlist = xprotectAppPlist; self.fdaProbePath = fdaProbePath
    }

    /// `ports: false` (audyt 3): bez `lsof` – lekkie odświeżenie co 5 min; porty dostawca bierze z ostatniego pełnego odczytu.
    public func collect(ports readPorts: Bool = true) async -> SecurityPosture {
        async let sip = CommandRunner.run("/usr/bin/csrutil", ["status"])
        async let gk = CommandRunner.run("/usr/sbin/spctl", ["--status"])
        async let fv = CommandRunner.run("/usr/bin/fdesetup", ["status"])
        async let fw = CommandRunner.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        async let st = CommandRunner.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])
        async let au = CommandRunner.run("/usr/sbin/softwareupdate", ["--schedule"])
        // Audyt 3: `-b` – lsof nie wywołuje stat()/lstat() na zamontowanych systemach plików (wolumin sieciowy Time Machine na SMB wywoływał
        // pytanie macOS o dostęp do plików na woluminie sieciowym, przypisywane MacCare); `-w` – bez ostrzeżeń. Wynik dla gniazd TCP bez zmian.
        async let ports = readPorts ? CommandRunner.run("/usr/sbin/lsof", ["-b", "-w", "-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"], timeout: 15) : CommandRunner.Result.skipped
        let (rSip, rGk, rFv, rFw, rSt, rAu, rPorts) = await (sip, gk, fv, fw, st, au, ports)

        var p = SecurityPosture()
        p.sip = Self.parseSIP(rSip.output)
        p.gatekeeper = Self.parseGatekeeper(rGk.output)
        p.fileVault = Self.parseFileVault(rFv.output)
        p.firewall = Self.parseFirewall(rFw.output)
        p.firewallStealth = Self.parseStealth(rSt.output)
        p.autoUpdateCheck = Self.parseAutoUpdate(rAu.output)
        p.xprotectVersion = Self.bundleVersion(xprotectBundlePlist)
        p.xprotectRemediatorVersion = Self.bundleVersion(xprotectAppPlist)
        p.fullDiskAccessGranted = Self.probeFullDiskAccess(path: fdaProbePath)
        p.listeningExternalPorts = Self.parseListeningPorts(rPorts.output).filter { $0.external }.map { "\($0.process) (pid \($0.pid)) → \($0.address)" }
        p.portsRead = !rPorts.timedOut && (rPorts.status == 0 || (rPorts.status == 1 && rPorts.output.isEmpty))   // lsof: 1 = nic nie nasłuchuje
        return p
    }

    // MARK: Parsery (czyste funkcje, testowane na prawdziwych napisach z macOS)
    static func parseSIP(_ s: String) -> ToggleState {
        let t = s.lowercased()
        if t.contains("status: enabled") { return .enabled }
        if t.contains("status: disabled") { return .disabled }
        return .unknown
    }
    static func parseGatekeeper(_ s: String) -> ToggleState {
        let t = s.lowercased()
        if t.contains("assessments enabled") { return .enabled }
        if t.contains("assessments disabled") { return .disabled }
        return .unknown
    }
    static func parseFileVault(_ s: String) -> ToggleState {
        if s.contains("FileVault is On") { return .enabled }
        if s.contains("FileVault is Off") { return .disabled }
        return .unknown
    }
    static func parseFirewall(_ s: String) -> ToggleState {
        if s.contains("State = 1") || s.contains("State = 2") { return .enabled }
        if s.contains("State = 0") { return .disabled }
        return .unknown
    }
    static func parseStealth(_ s: String) -> ToggleState {
        let t = s.lowercased()
        if t.contains("stealth mode is on") || t.contains("stealth mode enabled") { return .enabled }
        if t.contains("stealth mode is off") || t.contains("stealth mode disabled") { return .disabled }
        return .unknown
    }
    static func parseAutoUpdate(_ s: String) -> ToggleState {
        let t = s.lowercased()
        if t.contains("turned on") { return .enabled }
        if t.contains("turned off") { return .disabled }
        return .unknown
    }

    struct ListeningPort: Equatable { var process: String; var pid: Int; var address: String
        var external: Bool { !(address.hasPrefix("127.0.0.1") || address.hasPrefix("[::1]") || address.hasPrefix("localhost")) } }

    /// Format `lsof -F pcn`: linie `p<pid>`, `c<polecenie>`, `n<adres>`; inne linie (ostrzeżenia) ignorowane.
    static func parseListeningPorts(_ out: String) -> [ListeningPort] {
        var res: [ListeningPort] = []
        var pid = 0, cmd = ""
        for line in out.split(separator: "\n") {
            guard let f = line.first else { continue }
            let v = String(line.dropFirst())
            switch f {
            case "p": pid = Int(v) ?? 0
            case "c": cmd = v
            case "n": res.append(ListeningPort(process: cmd, pid: pid, address: v))
            default: break
            }
        }
        var seen = Set<String>()
        return res.filter { seen.insert("\($0.pid)|\($0.address)").inserted }
    }

    static func bundleVersion(_ plistPath: String) -> String? {
        (NSDictionary(contentsOfFile: plistPath)?["CFBundleShortVersionString"] as? String)
    }

    /// Próba **otwarcia** chronionego pliku (bez czytania treści). EPERM/EACCES ⇒ brak FDA; ENOENT ⇒ nie wiadomo.
    static func probeFullDiskAccess(path: String) -> Bool? {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        switch errno { case EPERM, EACCES: return false; default: return nil }
    }
}
#endif
