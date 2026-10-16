import Foundation

/// P2-3 (AUD-RISK-1/2): Porządki nie czyszczą pamięci podręcznej narzędzia, które właśnie pracuje (instalacja pakietów, budowanie).
/// Narzędzia wiersza poleceń nie są aplikacjami `.app` (F10 ich nie widzi), a wiele z nich to skrypty interpretera (`node npm-cli.js`, `python pip`,
/// `ruby brew.rb`, `java … GradleDaemon`) – rozpoznawane po nazwie programu ALBO nazwie skryptu z argumentów. Znaczniki są wąskie celowo: nie „node”,
/// „python”, „java” (uruchamia je wiele programów – cache byłby zablokowany na stałe).
public enum ToolActivity {
    /// Reguła katalogu → znaczniki narzędzi (małe litery; porównywane z nazwą pliku programu i nazwami plików z argumentów).
    public static let ruleTools: [String: Set<String>] = [
        "xcode.deriveddata": ["xcodebuild", "xcbbuildservice", "swift-build", "swift-frontend"],
        "xcode.devicesupport": ["xcodebuild", "devicectl"],
        "simulator.caches": ["launchd_sim", "simctl"],
        "homebrew.cache": ["brew", "brew.rb"],
        "npm.cache": ["npm", "npx", "npm-cli.js", "npx-cli.js"],
        "yarn.cache": ["yarn", "yarn.js", "yarn.cjs"],
        "yarn.berry.cache": ["yarn", "yarn.js", "yarn.cjs"],
        "pnpm.store": ["pnpm", "pnpm.cjs", "pnpm.mjs", "pnpx"],
        "pip.cache": ["pip", "pip3"],
        "gradle.cache": ["gradle", "gradlew", "org.gradle.launcher.daemon.bootstrap.gradledaemon", "org.gradle.wrapper.gradlewrappermain"],
        "cargo.cache": ["cargo", "rustc"],
        "go.buildcache": ["go"],
        "cocoapods.cache": ["pod"],
        "swiftpm.cache": ["swift-build", "swift-package"],
        "bun.cache": ["bun"],
        "maven.repo": ["mvn", "org.codehaus.plexus.classworlds.launcher.launcher"],
        "nuget.packages": ["dotnet"],
        "playwright.browsers": ["playwright"],
        "ollama.logs": ["ollama"], "lmstudio.logs": ["lms"],
    ]
    /// Wszystkie znaczniki – warstwa systemowa zachowuje z procesów WYŁĄCZNIE te (nic innego z argumentów nie jest przechowywane).
    public static let allTokens: Set<String> = ruleTools.values.reduce(into: Set<String>()) { $0.formUnion($1) }

    public static func toolRunning(ruleID: String, runningTools: Set<String>) -> Bool {
        guard let t = ruleTools[ruleID] else { return false }
        return !t.isDisjoint(with: runningTools)
    }

    /// Znaczniki z jednego procesu: nazwa programu i nazwy plików z argumentów (najwyżej `maxArgs`), tylko te z `allTokens`.
    public static func tokens(executable: String, arguments: [String], maxArgs: Int = 16) -> Set<String> {
        var out = Set<String>()
        for a in [executable] + arguments.prefix(maxArgs) {
            let base = (a as NSString).lastPathComponent.lowercased()
            if allTokens.contains(base) { out.insert(base) }
        }
        return out
    }

    /// Bufor `KERN_PROCARGS2`: [argc: Int32][ścieżka programu\0][wypełnienie \0…][argv[0]\0 … argv[argc-1]\0][środowisko…]. Zwraca argv (bez środowiska).
    /// Nieufnie: granice bufora, limit liczby i długości argumentów; uszkodzony bufor ⇒ pusta lista.
    public static func parseProcArgs(_ data: [UInt8], maxArgs: Int = 64) -> [String] {
        guard data.count >= 4 else { return [] }
        let argc = Int(Int32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc > 0, argc < 4096 else { return [] }
        var i = 4
        while i < data.count && data[i] != 0 { i += 1 }              // ścieżka programu
        while i < data.count && data[i] == 0 { i += 1 }              // wypełnienie
        var args: [String] = []
        while i < data.count && args.count < min(argc, maxArgs) {
            let start = i
            while i < data.count && data[i] != 0 { i += 1 }
            guard i < data.count else { break }                       // argument bez zakończenia – bufor ucięty
            args.append(String(decoding: data[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
