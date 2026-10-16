import Foundation

public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case appCaches, browserCaches, logs, temporary, devTools, aiTools, installers, mailAttachments, updateLeftovers, trash, oldDownloads, appLeftovers
    public var label: String {
        switch self {
        case .appCaches: return String(localized: "Pamięć podręczna aplikacji"); case .browserCaches: return String(localized: "Pamięć podręczna przeglądarek")
        case .logs: return String(localized: "Dzienniki"); case .temporary: return String(localized: "Pliki tymczasowe"); case .devTools: return String(localized: "Narzędzia programistyczne")
        case .aiTools: return String(localized: "Narzędzia i modele AI"); case .installers: return String(localized: "Stare instalatory"); case .mailAttachments: return String(localized: "Załączniki Poczty (lokalne)")
        case .updateLeftovers: return String(localized: "Pozostałości aktualizacji"); case .trash: return String(localized: "Kosz"); case .oldDownloads: return String(localized: "Stare pliki w Pobranych")
        case .appLeftovers: return String(localized: "Pozostałości po aplikacjach")
        }
    }
}

/// Jak usuwać elementy z danej reguły.
public enum RemovalMode: String, Codable, Sendable {
    /// Przeniesienie do kwarantanny MacCare (przywracalne przez N dni).
    case quarantine
    /// Przeniesienie do Kosza systemowego (przywracalne z Findera).
    case trash
    /// Trwałe usunięcie – wyłącznie opróżnianie Kosza; zawsze osobne zatwierdzenie.
    case permanent
}

public enum CleanupMatch: Codable, Sendable, Equatable {
    /// Każde bezpośrednie dziecko katalogu to osobny element.
    case children
    /// Cały katalog/plik jako jeden element.
    case whole
    /// Bezpośrednie dzieci o podanych rozszerzeniach (np. dmg, pkg).
    case childrenWithExtensions([String])
    /// Bezpośrednie dzieci pasujące do wzorca nazwy z „*” (np. "Install macOS*.app").
    case childrenNamed(String)
}

/// Reguła z listy dozwolonych. Bez reguły – brak czyszczenia.
public struct CleanupRule: Codable, Sendable, Identifiable {
    public var id: String
    public var category: CleanupCategory
    public var title: String
    public var explanation: String          // co to jest i dlaczego można usunąć
    public var owner: String                // aplikacja/narzędzie, do którego należą dane
    public var ownerBundleIDs: [String]     // gdy aplikacja działa – element oznaczany „w użyciu”
    public var paths: [String]              // z „~”
    public var match: CleanupMatch
    public var excludeNames: [String]
    public var minAgeDays: Int?
    public var risk: RiskLevel
    /// true = dane odtwarzalne; domyślnie zaznaczane. false = wymaga świadomego wyboru.
    public var recreatable: Bool
    public var removal: RemovalMode
    public var regenerationNote: String?

    public init(id: String, category: CleanupCategory, title: String, explanation: String, owner: String, ownerBundleIDs: [String] = [],
                paths: [String], match: CleanupMatch = .whole, excludeNames: [String] = [], minAgeDays: Int? = nil,
                risk: RiskLevel, recreatable: Bool, removal: RemovalMode = .quarantine, regenerationNote: String? = nil) {
        self.id = id; self.category = category; self.title = title; self.explanation = explanation; self.owner = owner
        self.ownerBundleIDs = ownerBundleIDs; self.paths = paths; self.match = match; self.excludeNames = excludeNames
        self.minAgeDays = minAgeDays; self.risk = risk; self.recreatable = recreatable; self.removal = removal; self.regenerationNote = regenerationNote
    }
}

/// Wbudowany katalog reguł. Każda pozycja jest jawnie opisana – nic nie jest usuwane „bo leży w cache”.
public enum CleanupCatalog {
    public static let rules: [CleanupRule] = [
        // Przeglądarki
        CleanupRule(id: "chrome.cache", category: .browserCaches, title: String(localized: "Google Chrome – pamięć podręczna"), explanation: String(localized: "Kopie stron i skryptów. Chrome pobierze je ponownie."), owner: "Google Chrome",
                    ownerBundleIDs: ["com.google.Chrome"], paths: ["~/Library/Caches/Google/Chrome"], risk: .low, recreatable: true),
        CleanupRule(id: "firefox.cache", category: .browserCaches, title: String(localized: "Firefox – pamięć podręczna"), explanation: String(localized: "Pamięć podręczna profili Firefoksa."), owner: "Firefox",
                    ownerBundleIDs: ["org.mozilla.firefox"], paths: ["~/Library/Caches/Firefox"], risk: .low, recreatable: true),
        CleanupRule(id: "edge.cache", category: .browserCaches, title: String(localized: "Microsoft Edge – pamięć podręczna"), explanation: String(localized: "Kopie stron i skryptów."), owner: "Microsoft Edge",
                    ownerBundleIDs: ["com.microsoft.edgemac"], paths: ["~/Library/Caches/Microsoft Edge"], risk: .low, recreatable: true),
        CleanupRule(id: "brave.cache", category: .browserCaches, title: String(localized: "Brave – pamięć podręczna"), explanation: String(localized: "Kopie stron i skryptów."), owner: "Brave",
                    ownerBundleIDs: ["com.brave.Browser"], paths: ["~/Library/Caches/BraveSoftware"], risk: .low, recreatable: true),
        // Aplikacje
        CleanupRule(id: "spotify.cache", category: .appCaches, title: String(localized: "Spotify – utwory w pamięci podręcznej"), explanation: String(localized: "Bufor odtwarzania (nie pobrane playlisty offline)."), owner: "Spotify",
                    ownerBundleIDs: ["com.spotify.client"], paths: ["~/Library/Caches/com.spotify.client"], risk: .low, recreatable: true),
        CleanupRule(id: "slack.cache", category: .appCaches, title: String(localized: "Slack – pamięć podręczna"), explanation: String(localized: "Cache interfejsu i obrazów."), owner: "Slack",
                    ownerBundleIDs: ["com.tinyspeck.slackmacgap"], paths: ["~/Library/Application Support/Slack/Cache", "~/Library/Application Support/Slack/Service Worker/CacheStorage"], risk: .low, recreatable: true),
        CleanupRule(id: "teams.cache", category: .appCaches, title: String(localized: "Microsoft Teams – pamięć podręczna"), explanation: String(localized: "Cache interfejsu."), owner: "Microsoft Teams",
                    ownerBundleIDs: ["com.microsoft.teams2"], paths: ["~/Library/Containers/com.microsoft.teams2/Data/Library/Caches"], risk: .low, recreatable: true),
        CleanupRule(id: "discord.cache", category: .appCaches, title: String(localized: "Discord – pamięć podręczna"), explanation: String(localized: "Cache obrazów i interfejsu."), owner: "Discord",
                    ownerBundleIDs: ["com.hnc.Discord"], paths: ["~/Library/Application Support/discord/Cache", "~/Library/Application Support/discord/Code Cache"], risk: .low, recreatable: true),
        CleanupRule(id: "vscode.cache", category: .appCaches, title: String(localized: "VS Code – pamięć podręczna"), explanation: String(localized: "Cache i skompilowany kod rozszerzeń."), owner: "Visual Studio Code",
                    ownerBundleIDs: ["com.microsoft.VSCode"], paths: ["~/Library/Application Support/Code/Cache", "~/Library/Application Support/Code/CachedData", "~/Library/Application Support/Code/CachedExtensionVSIXs"], risk: .low, recreatable: true),
        CleanupRule(id: "other.caches", category: .appCaches, title: String(localized: "Pamięć podręczna pozostałych aplikacji"), explanation: String(localized: "Katalogi w ~/Library/Caches bez dedykowanej reguły. Zwykle odtwarzalne, ale nie zawsze – do przejrzenia, domyślnie niezaznaczone."), owner: "różne",
                    paths: ["~/Library/Caches"], match: .children,
                    excludeNames: ["Google", "Firefox", "Microsoft Edge", "BraveSoftware", "com.spotify.client", "Homebrew", "pip", "Yarn", "go-build", "CocoaPods",
                                   "org.swift.swiftpm", "JetBrains", "MacCareAI", "com.apple.HomeKit", "CloudKit", "com.apple.Safari", "com.apple.akd", "FamilyCircle",
                                   "com.apple.ap.adprivacyd", "com.apple.containermanagerd", "ms-playwright", "node-gyp"],
                    risk: .medium, recreatable: false),
        // Logi i tymczasowe
        CleanupRule(id: "user.logs", category: .logs, title: String(localized: "Dzienniki aplikacji"), explanation: String(localized: "Logi zapisane przez aplikacje. Starsze niż 14 dni."), owner: "różne",
                    paths: ["~/Library/Logs"], match: .children, excludeNames: ["DiagnosticReports", "MacCareAI"], minAgeDays: 14, risk: .low, recreatable: true),
        CleanupRule(id: "crash.reports.old", category: .logs, title: String(localized: "Stare raporty awarii"), explanation: String(localized: "Raporty starsze niż 60 dni – nowsze zostają do diagnostyki."), owner: "macOS",
                    paths: ["~/Library/Logs/DiagnosticReports"], match: .children, minAgeDays: 60, risk: .low, recreatable: true),
        CleanupRule(id: "user.tmp", category: .temporary, title: String(localized: "Pliki tymczasowe użytkownika"), explanation: String(localized: "Elementy w katalogu tymczasowym nieużywane od 3 dni. Długo działające programy mogą tu trzymać blokady i gniazda – dlatego nie są zaznaczane same."), owner: "różne",
                    paths: ["$TMPDIR"], match: .children, excludeNames: ["com.apple", "TemporaryItems", "MacCareAI"], minAgeDays: 3, risk: .medium, recreatable: true),   // P2-3
        // Programistyczne
        CleanupRule(id: "xcode.deriveddata", category: .devTools, title: String(localized: "Xcode – DerivedData"), explanation: String(localized: "Wyniki kompilacji i indeksy. Xcode odbuduje je przy następnym buildzie."), owner: "Xcode",
                    ownerBundleIDs: ["com.apple.dt.Xcode"], paths: ["~/Library/Developer/Xcode/DerivedData"], match: .children, risk: .low, recreatable: true, regenerationNote: String(localized: "Pierwszy build potrwa dłużej.")),
        CleanupRule(id: "xcode.devicesupport", category: .devTools, title: String(localized: "Xcode – iOS DeviceSupport"), explanation: String(localized: "Symbole urządzeń. Starsze niż 90 dni."), owner: "Xcode",
                    paths: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport", "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport"], match: .children, minAgeDays: 90, risk: .low, recreatable: true),
        CleanupRule(id: "xcode.archives", category: .devTools, title: String(localized: "Xcode – archiwa"), explanation: String(localized: "Archiwa wydanych buildów (potrzebne do symbolikacji raportów). Tylko świadomy wybór."), owner: "Xcode",
                    paths: ["~/Library/Developer/Xcode/Archives"], match: .children, risk: .medium, recreatable: false, removal: .trash),
        CleanupRule(id: "simulator.caches", category: .devTools, title: String(localized: "Symulatory – pamięć podręczna"), explanation: String(localized: "Cache CoreSimulator."), owner: "Xcode",
                    paths: ["~/Library/Developer/CoreSimulator/Caches"], risk: .low, recreatable: true),
        CleanupRule(id: "homebrew.cache", category: .devTools, title: String(localized: "Homebrew – pobrane paczki"), explanation: String(localized: "Archiwa pobranych formuł. `brew` pobierze je w razie potrzeby."), owner: "Homebrew",
                    paths: ["~/Library/Caches/Homebrew"], match: .children, risk: .low, recreatable: true),
        CleanupRule(id: "npm.cache", category: .devTools, title: String(localized: "npm – pamięć podręczna"), explanation: String(localized: "Cache pakietów npm (_cacache)."), owner: "npm",
                    paths: ["~/.npm/_cacache"], risk: .low, recreatable: true),
        CleanupRule(id: "yarn.cache", category: .devTools, title: String(localized: "Yarn – pamięć podręczna"), explanation: String(localized: "Cache pakietów Yarn."), owner: "Yarn",
                    paths: ["~/Library/Caches/Yarn"], risk: .low, recreatable: true),
        CleanupRule(id: "pnpm.store", category: .devTools, title: String(localized: "pnpm – magazyn pakietów"), explanation: String(localized: "Współdzielony magazyn pnpm. Projekty mogą do niego linkować – po usunięciu wykonaj `pnpm install`."), owner: "pnpm",
                    paths: ["~/Library/pnpm/store"], risk: .medium, recreatable: true),
        CleanupRule(id: "pip.cache", category: .devTools, title: String(localized: "pip – pamięć podręczna"), explanation: String(localized: "Pobrane pakiety Pythona."), owner: "pip",
                    paths: ["~/Library/Caches/pip"], risk: .low, recreatable: true),
        CleanupRule(id: "gradle.cache", category: .devTools, title: String(localized: "Gradle – pamięć podręczna"), explanation: String(localized: "Zależności i wyniki budowania."), owner: "Gradle",
                    paths: ["~/.gradle/caches"], risk: .low, recreatable: true),
        CleanupRule(id: "cargo.cache", category: .devTools, title: String(localized: "Cargo – archiwa crate'ów"), explanation: String(localized: "Pobrane archiwa crate'ów."), owner: "Rust/Cargo",
                    paths: ["~/.cargo/registry/cache"], risk: .low, recreatable: true),
        CleanupRule(id: "go.buildcache", category: .devTools, title: String(localized: "Go – cache kompilacji"), explanation: String(localized: "Wyniki kompilacji Go."), owner: "Go",
                    paths: ["~/Library/Caches/go-build"], risk: .low, recreatable: true),
        CleanupRule(id: "cocoapods.cache", category: .devTools, title: String(localized: "CocoaPods – pamięć podręczna"), explanation: String(localized: "Pobrane pody."), owner: "CocoaPods",
                    paths: ["~/Library/Caches/CocoaPods"], risk: .low, recreatable: true),
        CleanupRule(id: "swiftpm.cache", category: .devTools, title: String(localized: "SwiftPM – pamięć podręczna"), explanation: String(localized: "Klony repozytoriów zależności."), owner: "Swift Package Manager",
                    paths: ["~/Library/Caches/org.swift.swiftpm"], risk: .low, recreatable: true),
        CleanupRule(id: "jetbrains.cache", category: .devTools, title: String(localized: "JetBrains – pamięć podręczna IDE"), explanation: String(localized: "Indeksy IDE. Odbudują się przy otwarciu projektu."), owner: "JetBrains",
                    ownerBundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm",
                                     "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.PhpStorm", "com.jetbrains.rider", "com.jetbrains.rubymine",
                                     "com.jetbrains.datagrip", "com.jetbrains.rustrover", "com.jetbrains.fleet", "com.jetbrains.toolbox"],
                    paths: ["~/Library/Caches/JetBrains"], match: .children, risk: .low, recreatable: true),
        CleanupRule(id: "playwright.browsers", category: .devTools, title: String(localized: "Playwright – pobrane przeglądarki"), explanation: String(localized: "Przeglądarki testowe. `npx playwright install` pobierze je ponownie."), owner: "Playwright",
                    paths: ["~/Library/Caches/ms-playwright"], match: .children, risk: .medium, recreatable: true),
        // AI
        CleanupRule(id: "hf.cache", category: .aiTools, title: String(localized: "Hugging Face – pobrane modele"), explanation: String(localized: "Modele i zbiory danych z hub. Pobiorą się ponownie (często wiele GB)."), owner: "Hugging Face",
                    paths: ["~/.cache/huggingface/hub"], match: .children, risk: .medium, recreatable: true, removal: .trash),
        CleanupRule(id: "torch.cache", category: .aiTools, title: String(localized: "PyTorch Hub – modele"), explanation: String(localized: "Wagi modeli pobrane przez torch.hub."), owner: "PyTorch",
                    paths: ["~/.cache/torch"], match: .children, risk: .medium, recreatable: true, removal: .trash),
        CleanupRule(id: "whisper.cache", category: .aiTools, title: String(localized: "Whisper – modele"), explanation: String(localized: "Modele rozpoznawania mowy."), owner: "OpenAI Whisper",
                    paths: ["~/.cache/whisper"], match: .children, risk: .medium, recreatable: true, removal: .trash),
        CleanupRule(id: "lmstudio.models", category: .aiTools, title: String(localized: "LM Studio – modele"), explanation: String(localized: "Pobrane modele LM Studio. Tylko świadomy wybór."), owner: "LM Studio",
                    paths: ["~/.lmstudio/models", "~/.cache/lm-studio/models"], match: .children, risk: .high, recreatable: true, removal: .trash),
        CleanupRule(id: "cursor.cache", category: .aiTools, title: String(localized: "Cursor – pamięć podręczna"), explanation: String(localized: "Cache edytora Cursor."), owner: "Cursor",
                    ownerBundleIDs: ["com.todesktop.230313mzl4w4u92"], paths: ["~/Library/Application Support/Cursor/Cache", "~/Library/Application Support/Cursor/CachedData"], risk: .low, recreatable: true),
        // Instalatory, poczta, aktualizacje
        // F9 (z PureMac): logi narzędzi AI i kontenerów, pamięć podręczna menedżerów pakietów; repozytoria Maven/NuGet tylko świadomie (Kosz).
        // Świadomie POMINIĘTE: ~/Library/HTTPStorages (ciasteczka sesji = dane logowania) i obrazy dysków maszyn Docker/OrbStack (usunięcie kasuje
        // wszystkie kontenery, obrazy i wolumeny – rozmiar widać na mapie dysku; porządkuje się je narzędziem `docker system prune`).
        CleanupRule(id: "ollama.logs", category: .logs, title: String(localized: "Ollama – stare logi"), explanation: String(localized: "Logi serwera Ollama starsze niż 7 dni. Modele zostają."), owner: "Ollama",
                    ownerBundleIDs: ["com.electron.ollama"], paths: ["~/.ollama/logs"], match: .children, minAgeDays: 7, risk: .low, recreatable: true),
        CleanupRule(id: "lmstudio.logs", category: .logs, title: String(localized: "LM Studio – stare logi"), explanation: String(localized: "Logi serwera LM Studio starsze niż 7 dni. Modele zostają."), owner: "LM Studio",
                    ownerBundleIDs: ["ai.elementlabs.lmstudio"], paths: ["~/.lmstudio/server-logs", "~/.cache/lm-studio/server-logs"], match: .children, minAgeDays: 7, risk: .low, recreatable: true),
        CleanupRule(id: "docker.logs", category: .logs, title: String(localized: "Docker Desktop – stare logi"), explanation: String(localized: "Logi Docker Desktop starsze niż 7 dni. Kontenery, obrazy i wolumeny nie są ruszane."), owner: "Docker",
                    ownerBundleIDs: ["com.docker.docker"], paths: ["~/Library/Containers/com.docker.docker/Data/log"], match: .children, minAgeDays: 7, risk: .low, recreatable: true),
        CleanupRule(id: "orbstack.logs", category: .logs, title: String(localized: "OrbStack – stare logi"), explanation: String(localized: "Logi OrbStack starsze niż 7 dni. Maszyny i kontenery nie są ruszane."), owner: "OrbStack",
                    ownerBundleIDs: ["dev.kdrag0n.MacVirt"], paths: ["~/.orbstack/log"], match: .children, minAgeDays: 7, risk: .low, recreatable: true),
        CleanupRule(id: "bun.cache", category: .devTools, title: String(localized: "Bun – pamięć podręczna"), explanation: String(localized: "Pobrane pakiety Bun. `bun install` pobierze je ponownie."), owner: "Bun",
                    paths: ["~/.bun/install/cache"], risk: .low, recreatable: true),
        CleanupRule(id: "yarn.berry.cache", category: .devTools, title: String(localized: "Yarn (Berry) – pamięć podręczna"), explanation: String(localized: "Globalna pamięć podręczna Yarn 2+. Projekty z „zero-install” mają własną kopię."), owner: "Yarn",
                    paths: ["~/.yarn/berry/cache"], risk: .low, recreatable: true),
        CleanupRule(id: "maven.repo", category: .devTools, title: String(localized: "Maven – lokalne repozytorium"), explanation: String(localized: "Pobrane biblioteki Javy. Pobiorą się ponownie przy budowaniu, ale mogą tu leżeć też artefakty zainstalowane lokalnie (`mvn install`) – tylko świadomy wybór."), owner: "Maven",
                    paths: ["~/.m2/repository"], match: .children, risk: .medium, recreatable: false, removal: .trash),
        CleanupRule(id: "nuget.packages", category: .devTools, title: String(localized: "NuGet – pakiety"), explanation: String(localized: "Pobrane pakiety .NET. `dotnet restore` pobierze je ponownie – tylko świadomy wybór."), owner: "NuGet",
                    paths: ["~/.nuget/packages"], match: .children, risk: .medium, recreatable: true, removal: .trash),
        CleanupRule(id: "installers", category: .installers, title: String(localized: "Pliki instalacyjne (.dmg, .pkg, .xip, .iso)"), explanation: String(localized: "Instalatory w Pobranych i na Biurku. Po instalacji zwykle zbędne."), owner: "użytkownik",
                    paths: ["~/Downloads", "~/Desktop"], match: .childrenWithExtensions(["dmg", "pkg", "mpkg", "xip", "iso"]), minAgeDays: 7, risk: .medium, recreatable: false, removal: .trash),
        CleanupRule(id: "macos.installers", category: .updateLeftovers, title: String(localized: "Instalatory macOS"), explanation: String(localized: "Aplikacje „Install macOS …” zostawione po aktualizacji."), owner: "macOS",
                    paths: ["/Applications"], match: .childrenNamed("Install macOS*.app"), risk: .medium, recreatable: true, removal: .trash),
        CleanupRule(id: "mail.downloads", category: .mailAttachments, title: String(localized: "Pobrane załączniki Poczty"), explanation: String(localized: "Lokalne kopie otwieranych załączników. Oryginały pozostają w wiadomościach na serwerze. Nie dotyczy operacji na serwerze pocztowym."), owner: "Mail",
                    ownerBundleIDs: ["com.apple.mail"], paths: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], match: .children, risk: .medium, recreatable: false, removal: .trash),
        CleanupRule(id: "old.downloads", category: .oldDownloads, title: String(localized: "Pliki w Pobranych nieużywane od 90 dni"), explanation: String(localized: "Mogą być ważne – zawsze do przejrzenia, trafiają do Kosza."), owner: "użytkownik",
                    paths: ["~/Downloads"], match: .children, minAgeDays: 90, risk: .medium, recreatable: false, removal: .trash),
        CleanupRule(id: "trash", category: .trash, title: String(localized: "Kosz"), explanation: String(localized: "Opróżnienie jest NIEODWRACALNE. Wymaga osobnego zatwierdzenia."), owner: "użytkownik",
                    paths: ["~/.Trash"], match: .children, risk: .high, recreatable: false, removal: .permanent)
    ]

    public static func rule(_ id: String) -> CleanupRule? { rules.first { $0.id == id } }

    /// Korzenie dozwolone dla PathPolicy (scope .ruleCleanup).
    /// Katalogi, które NIGDY nie mogą być korzeniem reguły (współdzielone/systemowe).
    public static let forbiddenRoots: Set<String> = ["/", "/tmp", "/var", "/var/tmp", "/private", "/private/tmp", "/Users", "/Library", "/System"]

    /// Rozwija ścieżkę reguły: „~” → katalog domowy, „$TMPDIR” → prywatny katalog tymczasowy użytkownika.
    public static func expand(_ raw: String, home: String, tempDir: String) -> String {
        let r = raw.hasPrefix("$TMPDIR") ? tempDir + String(raw.dropFirst("$TMPDIR".count)) : raw
        return PathTools.canonical(r, home: home)
    }

    /// Korzenie dozwolone dla PathPolicy (scope .ruleCleanup). Wyklucza korzenie współdzielone.
    public static func allowedRoots(_ rules: [CleanupRule] = CleanupCatalog.rules, home: String = PathTools.home,
                                    tempDir: String = NSTemporaryDirectory()) -> [String] {
        rules.flatMap { r in r.paths.map { (r, $0) } }.compactMap { (r, raw) in
            let p = expand(raw, home: home, tempDir: tempDir)
            if forbiddenRoots.contains(p) { return nil }
            // /Applications dopuszczone wyłącznie dla reguł z dopasowaniem po nazwie (instalatory macOS)
            if p == "/Applications" { if case .childrenNamed = r.match { return p } else { return nil } }
            return p
        }
    }
}
