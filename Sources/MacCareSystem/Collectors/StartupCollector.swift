#if os(macOS)
import Foundation
import MacCareCore

/// Autostart: plisty launchd (LaunchAgents/LaunchDaemons), status załadowania i podpis programu.
public struct StartupCollector: Sendable {
    public struct Directory: Sendable { public var path: String; public var scope: StartupScope
        public init(path: String, scope: StartupScope) { self.path = path; self.scope = scope } }

    let directories: [Directory]
    let uid: uid_t

    public init(home: String = NSHomeDirectory(), uid: uid_t = getuid(), directories: [Directory]? = nil) {
        self.uid = uid
        self.directories = directories ?? [
            Directory(path: home + "/Library/LaunchAgents", scope: .userAgent),
            Directory(path: "/Library/LaunchAgents", scope: .globalAgent),
            Directory(path: "/Library/LaunchDaemons", scope: .globalDaemon)
        ]
    }

    /// Label z plistu musi być „bezpiecznym” identyfikatorem, zanim trafi do argumentów launchctl.
    static func isValidLabel(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 200 && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
            && s.contains { $0 != "." }                                   // P3-5 (AUD-SEC-1): same kropki („.”, „..”) to nie etykieta
    }

    /// Czysty parser pojedynczego plistu (testowalny bez systemu).
    static func parse(plist: [String: Any], path: String, scope: StartupScope) -> StartupItem? {
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let label = (plist["Label"] as? String) ?? fallback
        var program = plist["Program"] as? String
        if program == nil, let args = plist["ProgramArguments"] as? [String], let first = args.first { program = first }
        var keepAlive = false
        if let b = plist["KeepAlive"] as? Bool { keepAlive = b }
        else if let d = plist["KeepAlive"] as? [String: Any] { keepAlive = !d.isEmpty }
        return StartupItem(label: label, program: program, plistPath: path, scope: scope,
                           runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive)
    }

    public func collect(checkSignatures: Bool = true, checkLoaded: Bool = true) async -> [StartupItem] {
        var items: [StartupItem] = []
        for d in directories {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".plist") }.sorted()   // try? świadomie: nieczytelny katalog ⇒ brak wpisów (tylko odczyt)
            for f in files {
                let path = d.path + "/" + f
                guard let data = SafeRead.regularFile(path, maxBytes: 1 << 20),               // audyt 2: bez dowiązań, FIFO i plików > 1 MB
                      let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
                      let item = Self.parse(plist: obj, path: path, scope: d.scope) else { continue }
                items.append(item)
            }
        }
        guard checkSignatures || checkLoaded else { return items }

        let uid = self.uid
        // Audyt 2: najwyżej 8 sprawdzeń naraz (każde to proces `launchctl`/`codesign`) – tysiące plistów nie wyczerpią limitu procesów użytkownika.
        let resolved: [StartupItem] = await withTaskGroup(of: (Int, StartupItem).self) { group in
            func check(_ i: Int, _ it: StartupItem) async -> (Int, StartupItem) {
                var item = it
                if checkSignatures {
                    if let prog = item.program, prog.hasPrefix("/") {
                        let r = await CodeSignatureChecker.check(path: prog)
                        item.signature = r.status; item.teamID = r.teamID; item.signerName = r.signerName
                    } // program względny/nieznany ⇒ .notChecked (nie zgadujemy)
                }
                if checkLoaded, Self.isValidLabel(item.label) {
                    item.isLoaded = await Self.loadedState(label: item.label, scope: item.scope, uid: uid)
                }
                return (i, item)
            }
            var pending = Array(items.enumerated()).makeIterator()
            for _ in 0..<8 { if let (i, it) = pending.next() { group.addTask { await check(i, it) } } }
            var out = items
            for await (i, it) in group {
                out[i] = it
                if let (j, nx) = pending.next() { group.addTask { await check(j, nx) } }
            }
            return out
        }
        return resolved
    }

    /// `launchctl print <domena>/<label>`: 0 ⇒ załadowany, 113 ⇒ nie ma takiej usługi, inne ⇒ nieznane.
    static func loadedState(label: String, scope: StartupScope, uid: uid_t) async -> Bool? {
        guard isValidLabel(label) else { return nil }
        let domain = scope == .globalDaemon ? "system" : "gui/\(uid)"
        let r = await CommandRunner.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 5)
        if r.timedOut { return nil }
        switch r.status { case 0: return true; case 113: return false; default: return nil }
    }
}
#endif
