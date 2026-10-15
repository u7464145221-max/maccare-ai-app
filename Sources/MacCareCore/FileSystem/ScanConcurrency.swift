import Foundation

/// Ile folderów mierzyć naraz (technika z Radixa): połowa rdzeni, od 2 do 8; w trybie niskiego zużycia energii albo przy wysokiej temperaturze – połowa
/// tego (co najmniej 1). Skan nie zajmuje całego procesora, a na Macu z 10 rdzeniami (M5) pracuje 5 wątków zamiast tylu, ile da pula systemowa.
public enum ScanConcurrency {
    public static func limit(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                             lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
                             thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Int {
        var n = min(8, max(2, cores / 2))
        if lowPower || thermal == .serious || thermal == .critical { n = max(1, n / 2) }
        return n
    }
}

/// Flaga przerwania skanu współdzielona z wątkami pomiaru (sprawdzana co porcję wpisów).
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Licznik równoczesnych pomiarów (dowód w testach, że limit `ScanConcurrency` jest przestrzegany).
public final class ParallelGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0, maxSeen = 0
    public init() {}
    public func enter() { lock.lock(); current += 1; maxSeen = max(maxSeen, current); lock.unlock() }
    public func leave() { lock.lock(); current -= 1; lock.unlock() }
    public var peak: Int { lock.lock(); defer { lock.unlock() }; return maxSeen }
}
