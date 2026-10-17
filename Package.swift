// swift-tools-version:5.9
// MacCare AI — natywna aplikacja macOS do diagnostyki, konserwacji i lokalnej analizy AI.
import PackageDescription

// Audyt 16.10: kompilator sprawdza współbieżność w pełnym zakresie (ostrzeżenia trybu Swift 6) dla kodu aplikacji – nowe wyścigi nie przejdą po cichu.
let strictConcurrency: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(
    name: "MacCareAI",
    defaultLocalization: "pl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacCareApp", targets: ["MacCareApp"]),
        .executable(name: "maccare", targets: ["maccare"]),
        .library(name: "MacCareCore", targets: ["MacCareCore"])
    ],
    targets: [
        // SQLite z systemu (macOS SDK / libsqlite3-dev na Linuksie – tylko do testów CI).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite",
                       providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        // Rdzeń niezależny od platformy: modele, reguły, polityki, agent, executor, historia.
        .target(name: "MacCareCore", dependencies: ["CSQLite"], swiftSettings: strictConcurrency),
        // Pomiary i operacje specyficzne dla macOS (IOKit, Mach, Security, launchd…).
        .target(name: "MacCareSystem", dependencies: ["MacCareCore"], swiftSettings: strictConcurrency,
                linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS])),
                                 .linkedFramework("Security", .when(platforms: [.macOS]))]),
        // Dostawcy modeli językowych i orkiestracja asystenta.
        .target(name: "MacCareAI", dependencies: ["MacCareCore"], swiftSettings: strictConcurrency),
        // Aplikacja SwiftUI + pasek menu.
        .executableTarget(name: "MacCareApp", dependencies: ["MacCareCore", "MacCareSystem", "MacCareAI"],
                         exclude: ["Localization"], swiftSettings: strictConcurrency),   // pliki .lproj kopiuje Scripts/build_app.sh do Contents/Resources (SwiftUI szuka w Bundle.main)
        // CLI z bezpiecznymi, udokumentowanymi operacjami.
        .executableTarget(name: "maccare", dependencies: ["MacCareCore", "MacCareSystem"], swiftSettings: strictConcurrency)
    ]
)
