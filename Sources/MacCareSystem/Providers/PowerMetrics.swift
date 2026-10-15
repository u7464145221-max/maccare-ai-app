#if os(macOS)
import Foundation
import MacCareCore

/// Wynik jednorazowej próbki `powermetrics` (opcjonalne „Szczegółowe czujniki”, tryb Profesjonalny, za zgodą użytkownika).
/// Temperatur rdzeni NIE ma: wymagają prywatnych interfejsów (SMC/IOHID), których nie używamy – nie zgadujemy.
public struct PowerMetricsSample: Sendable, Equatable {
    public struct Cluster: Sendable, Equatable {
        public var name: String
        public var frequencyMHz: Double
        public init(name: String, frequencyMHz: Double) { self.name = name; self.frequencyMHz = frequencyMHz }
    }
    public var cpuPowerMW: Double?
    public var gpuPowerMW: Double?
    public var anePowerMW: Double?
    public var combinedPowerMW: Double?
    public var thermalPressure: String?
    public var clusters: [Cluster]
    public var gpuFrequencyMHz: Double?
    public var measuredAt: Date
    public init(cpuPowerMW: Double? = nil, gpuPowerMW: Double? = nil, anePowerMW: Double? = nil, combinedPowerMW: Double? = nil,
                thermalPressure: String? = nil, clusters: [Cluster] = [], gpuFrequencyMHz: Double? = nil, measuredAt: Date = Date()) {
        self.cpuPowerMW = cpuPowerMW; self.gpuPowerMW = gpuPowerMW; self.anePowerMW = anePowerMW; self.combinedPowerMW = combinedPowerMW
        self.thermalPressure = thermalPressure; self.clusters = clusters; self.gpuFrequencyMHz = gpuFrequencyMHz; self.measuredAt = measuredAt
    }
}

public enum SensorSampleResult: Sendable, Equatable {
    case ok(PowerMetricsSample)
    case cancelled                 // użytkownik zamknął okno hasła
    case failed(String)
    case unparsed                  // komenda się powiodła, ale nie rozpoznaliśmy wyjścia – nic nie zgadujemy
}

public protocol SensorSampling: Sendable { func sample() async -> SensorSampleResult }

/// Jednorazowa próbka przez `AdminCommand.powermetricsSample` (stały literał skryptu, hasło wpisuje się w systemowym oknie,
/// nic nie jest zapamiętywane, żadnych demonów pomocniczych).
public struct PowerMetricsSampler: SensorSampling {
    /// Dokładne polecenie pokazywane w arkuszu zgody i uruchamiane przez `AdminCommand.powermetricsSample` (jedno źródło prawdy).
    public static let commandLine = "/usr/bin/powermetrics --samplers cpu_power,gpu_power,thermal -i 1000 -n 1 -f plist"
    let runner: AdminScriptRunning
    public init() { runner = OsascriptRunner() }
    init(runner: AdminScriptRunning) { self.runner = runner }

    public func sample() async -> SensorSampleResult {
        switch await AdminCommand.powermetricsSample.run(timeout: 60, runner: runner) {
        case .cancelled: return .cancelled
        case .failed(let m): return .failed(m)
        case .ok(let out): return PowerMetricsParser.parse(out).map(SensorSampleResult.ok) ?? .unparsed
        }
    }
}

/// Parser listy właściwości z `powermetrics -f plist`. Defensywny: klucze szukane rekurencyjnie, moc z `*_power` (mW)
/// albo z `*_energy` (mJ) ÷ czas próbki; brak rozpoznanych pól ⇒ nil (a nie „zera”).
enum PowerMetricsParser {
    static func parse(_ raw: String, now: Date = Date()) -> PowerMetricsSample? {
        // `do shell script` zamienia końce linii na CR; powermetrics oddziela próbki znakiem NUL.
        var text = raw.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\0", with: "")
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", options: .backwards), start.lowerBound < end.upperBound else { return nil }
        text = String(text[start.lowerBound..<end.upperBound])
        guard let data = text.data(using: .utf8),
              let any = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil), let root = any as? [String: Any] else { return nil }

        let elapsedS = number("elapsed_ns", in: root).map { $0 / 1e9 }
        func power(_ k: String) -> Double? {
            if let p = number("\(k)_power", in: root), p >= 0 { return p }
            if let e = number("\(k)_energy", in: root), e >= 0, let s = elapsedS, s > 0 { return e / s }     // mJ / s = mW
            return nil
        }
        var s = PowerMetricsSample(cpuPowerMW: power("cpu"), gpuPowerMW: power("gpu"), anePowerMW: power("ane"),
                                   combinedPowerMW: number("combined_power", in: root).flatMap { $0 >= 0 ? $0 : nil },
                                   thermalPressure: string("thermal_pressure", in: root), measuredAt: now)
        s.clusters = clusters(in: root)
        if let gpu = root["gpu"] as? [String: Any] { s.gpuFrequencyMHz = frequencyMHz(gpu) }
        let nothing = s.cpuPowerMW == nil && s.gpuPowerMW == nil && s.anePowerMW == nil && s.combinedPowerMW == nil
            && s.thermalPressure == nil && s.clusters.isEmpty
        return nothing ? nil : s
    }

    private static func frequencyMHz(_ d: [String: Any]) -> Double? {
        if let hz = (d["freq_hz"] as? NSNumber)?.doubleValue, hz > 0 { return hz / 1e6 }
        if let mhz = (d["freq_mhz"] as? NSNumber)?.doubleValue, mhz > 0 { return mhz }
        return nil
    }

    private static func clusters(in node: Any) -> [PowerMetricsSample.Cluster] {
        var out: [PowerMetricsSample.Cluster] = []
        func walk(_ n: Any) {
            if let d = n as? [String: Any] {
                if let arr = d["clusters"] as? [[String: Any]] {
                    for c in arr { if let name = c["name"] as? String, let f = frequencyMHz(c) { out.append(.init(name: name, frequencyMHz: f)) } }
                }
                d.values.forEach(walk)
            } else if let a = n as? [Any] { a.forEach(walk) }
        }
        walk(node)
        return out
    }

    private static func number(_ key: String, in node: Any) -> Double? {
        if let d = node as? [String: Any] {
            if let n = d[key] as? NSNumber { return n.doubleValue }
            for v in d.values { if let r = number(key, in: v) { return r } }
        } else if let a = node as? [Any] { for v in a { if let r = number(key, in: v) { return r } } }
        return nil
    }

    private static func string(_ key: String, in node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let s = d[key] as? String { return s }
            for v in d.values { if let r = string(key, in: v) { return r } }
        } else if let a = node as? [Any] { for v in a { if let r = string(key, in: v) { return r } } }
        return nil
    }
}
#endif
