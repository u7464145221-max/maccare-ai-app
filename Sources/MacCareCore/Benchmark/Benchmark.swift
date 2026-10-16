import Foundation

/// Mierzalne wskaźniki porównywane przed i po operacji. `lowerIsBetter` określa kierunek poprawy.
public enum BenchmarkMetric: String, Codable, Sendable, CaseIterable {
    case diskFreeBytes, memoryUsedBytes, swapUsedBytes, memoryPressureLevel, cpuBusyPercent, cpuWorkMs, smallFileOpsMs, loadAverage1m
    public var label: String {
        switch self {
        case .diskFreeBytes: return String(localized: "Wolne miejsce na dysku"); case .memoryUsedBytes: return String(localized: "Pamięć w użyciu"); case .swapUsedBytes: return String(localized: "Swap")
        case .memoryPressureLevel: return String(localized: "Ciśnienie pamięci (0–2)"); case .cpuBusyPercent: return String(localized: "Obciążenie CPU"); case .cpuWorkMs: return String(localized: "Czas stałego zadania CPU")
        case .smallFileOpsMs: return String(localized: "Czas operacji na małych plikach"); case .loadAverage1m: return String(localized: "Średnie obciążenie (1 min)")
        }
    }
    public var lowerIsBetter: Bool { self != .diskFreeBytes }
    /// Minimalna zmiana uznawana za praktycznie istotną (niezależnie od statystyki).
    public var minimumMeaningfulRelativeChange: Double {
        switch self { case .diskFreeBytes: return 0.005; case .memoryPressureLevel: return 0.0; case .cpuWorkMs, .smallFileOpsMs: return 0.20; default: return 0.10 }   // mikropomiary: zmienność tła sięga kilkudziesięciu %
    }
    public func format(_ v: Double) -> String {
        switch self {
        case .diskFreeBytes, .memoryUsedBytes, .swapUsedBytes: return ByteFormat.string(UInt64(max(0, v)))
        case .cpuBusyPercent: return String(format: "%.1f%%", v)
        case .cpuWorkMs, .smallFileOpsMs: return String(format: "%.1f ms", v)
        case .memoryPressureLevel, .loadAverage1m: return String(format: "%.2f", v)
        }
    }
}

public struct MeasurementSet: Codable, Sendable {
    public var takenAt: Date
    public var samples: [BenchmarkMetric: [Double]]
    /// Warunki pomiaru – do oceny porównywalności.
    public var onAC: Bool?
    public var thermal: ThermalLevel?
    public var backgroundCPUPercent: Double?
    public init(takenAt: Date, samples: [BenchmarkMetric: [Double]], onAC: Bool? = nil, thermal: ThermalLevel? = nil, backgroundCPUPercent: Double? = nil) {
        self.takenAt = takenAt; self.samples = samples; self.onAC = onAC; self.thermal = thermal; self.backgroundCPUPercent = backgroundCPUPercent
    }
}

public enum EffectVerdict: String, Codable, Sendable {
    case improved, worsened, noMeasurableEffect, insufficientData
    public var label: String {
        switch self { case .improved: return String(localized: "poprawa"); case .worsened: return String(localized: "pogorszenie"); case .noMeasurableEffect: return String(localized: "brak mierzalnego efektu"); case .insufficientData: return String(localized: "za mało danych") }
    }
}

public struct MetricComparison: Codable, Sendable {
    public var metric: BenchmarkMetric
    public var beforeMean: Double
    public var afterMean: Double
    public var relativeChange: Double
    public var pValue: Double?
    public var verdict: EffectVerdict
}

public struct BenchmarkComparison: Codable, Sendable, Identifiable {
    public var id: String
    public var operation: String
    public var before: MeasurementSet
    public var after: MeasurementSet
    public var metrics: [MetricComparison]
    public var conditionWarnings: [String]
    public var overall: EffectVerdict
    /// Metryki, z których liczona jest ocena ogólna (nil = wszystkie). Pozostałe są tłem – operacja nie może na nie realnie wpłynąć.
    public var decisiveMetrics: [BenchmarkMetric]? = nil
    public func isDecisive(_ m: BenchmarkMetric) -> Bool { decisiveMetrics.map { $0.contains(m) } ?? true }

    public var summary: String {
        var s = String(localized: "Operacja: \(operation) — ogólnie: \(overall.label).")
        for m in metrics {
            let pct = String(format: "%+.1f%%", m.relativeChange * 100)
            s += "\n- \(m.metric.label): \(m.metric.format(m.beforeMean)) → \(m.metric.format(m.afterMean)) (\(pct)) — \(m.verdict.label)"
            if let p = m.pValue { s += String(format: " [p=%.3f]", p) }
        }
        if !conditionWarnings.isEmpty { s += "\n" + String(localized: "Zastrzeżenia: ") + conditionWarnings.joined(separator: "; ") }
        return s
    }
}

public enum BenchmarkAnalyzer {
    /// Porównanie z testem Welcha (gdy ≥3 próbki po obu stronach) i progiem praktycznej istotności.
    /// Zmiana wolnego miejsca jest deterministyczna (1 próbka wystarcza), pozostałe metryki wymagają serii.
    /// - Parameter decisive: metryki, na które operacja może realnie wpłynąć (np. przeniesienie do Kosza – tylko wolne miejsce); nil = wszystkie.
    public static func compare(operation: String, before: MeasurementSet, after: MeasurementSet, alpha: Double = 0.05, decisive: Set<BenchmarkMetric>? = nil) -> BenchmarkComparison {
        var out: [MetricComparison] = []
        for metric in BenchmarkMetric.allCases {
            guard let b = before.samples[metric], let a = after.samples[metric], !b.isEmpty, !a.isEmpty else { continue }
            let mb = mean(b), ma = mean(a)
            let rel = mb == 0 ? (ma == 0 ? 0 : 1) : (ma - mb) / abs(mb)
            let improvedDirection = metric.lowerIsBetter ? ma < mb : ma > mb
            var p: Double? = nil
            var verdict: EffectVerdict
            if metric == .diskFreeBytes {
                verdict = abs(rel) < metric.minimumMeaningfulRelativeChange ? .noMeasurableEffect : (improvedDirection ? .improved : .worsened)
            } else if b.count < 3 || a.count < 3 {
                verdict = .insufficientData
            } else {
                p = welchPValue(b, a)
                if let p, p < alpha, abs(rel) >= metric.minimumMeaningfulRelativeChange, ma != mb { verdict = improvedDirection ? .improved : .worsened }
                else { verdict = .noMeasurableEffect }
            }
            out.append(MetricComparison(metric: metric, beforeMean: mb, afterMean: ma, relativeChange: rel, pValue: p, verdict: verdict))
        }
        var warnings: [String] = []
        if let x = before.onAC, let y = after.onAC, x != y { warnings.append(String(localized: "zmiana zasilania (sieć/bateria) między pomiarami")) }
        if let x = before.thermal, let y = after.thermal, x != y { warnings.append(String(localized: "inny stan termiczny (\(x.label) → \(y.label))")) }
        if let x = before.backgroundCPUPercent, let y = after.backgroundCPUPercent, abs(x - y) > 20 { warnings.append(String(localized: "różne obciążenie tła (\(Int(x))% → \(Int(y))%)")) }
        if after.takenAt.timeIntervalSince(before.takenAt) > 3600 { warnings.append(String(localized: "pomiary dzieli ponad godzina – inne procesy mogły wpłynąć na wynik")) }

        let counted = out.filter { decisive?.contains($0.metric) ?? true }
        let decided = counted.filter { $0.verdict == .improved || $0.verdict == .worsened }
        let overall: EffectVerdict
        if counted.isEmpty || counted.allSatisfy({ $0.verdict == .insufficientData }) { overall = .insufficientData }
        else if decided.isEmpty { overall = .noMeasurableEffect }
        else if decided.allSatisfy({ $0.verdict == .improved }) { overall = .improved }
        else if decided.allSatisfy({ $0.verdict == .worsened }) { overall = .worsened }
        else { overall = .noMeasurableEffect }   // sprzeczne sygnały – nie ogłaszamy sukcesu
        return BenchmarkComparison(id: UUID().uuidString, operation: operation, before: before, after: after, metrics: out,
                                   conditionWarnings: warnings, overall: overall, decisiveMetrics: decisive.map { BenchmarkMetric.allCases.filter($0.contains) })
    }

    public static func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(max(1, x.count)) }
    public static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x); return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)
    }

    /// Dwustronna wartość p testu t Welcha.
    public static func welchPValue(_ a: [Double], _ b: [Double]) -> Double {
        let va = variance(a) / Double(a.count), vb = variance(b) / Double(b.count)
        let se = (va + vb).squareRoot()
        if se == 0 { return mean(a) == mean(b) ? 1 : 0 }
        let t = abs(mean(a) - mean(b)) / se
        let df = (va + vb) * (va + vb) / ((va * va) / Double(a.count - 1) + (vb * vb) / Double(b.count - 1))
        return 2 * studentTUpperTail(t, df)
    }

    /// P(T > t) dla rozkładu t-Studenta przez regularyzowaną niekompletną funkcję beta.
    static func studentTUpperTail(_ t: Double, _ df: Double) -> Double {
        let x = df / (df + t * t)
        return 0.5 * regIncBeta(df / 2, 0.5, x)
    }

    static func regIncBeta(_ a: Double, _ b: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        let lbeta = lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x)
        if x < (a + 1) / (a + b + 2) { return exp(lbeta) * betacf(a, b, x) / a }
        return 1 - exp(lbeta) * betacf(b, a, 1 - x) / b
    }

    static func betacf(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let eps = 3e-14, fpmin = 1e-300
        var c = 1.0, d = 1 - (a + b) * x / (a + 1)
        if abs(d) < fpmin { d = fpmin }
        d = 1 / d; var h = d
        for m in 1...300 {
            let m2 = Double(2 * m), md = Double(m)
            var aa = md * (b - md) * x / ((a + m2 - 1) * (a + m2))
            d = 1 + aa * d; if abs(d) < fpmin { d = fpmin }
            c = 1 + aa / c; if abs(c) < fpmin { c = fpmin }
            d = 1 / d; h *= d * c
            aa = -(a + md) * (a + b + md) * x / ((a + m2) * (a + m2 + 1))
            d = 1 + aa * d; if abs(d) < fpmin { d = fpmin }
            c = 1 + aa / c; if abs(c) < fpmin { c = fpmin }
            d = 1 / d
            let del = d * c; h *= del
            if abs(del - 1) < eps { break }
        }
        return h
    }
}

/// Mikrobenchmarki o stałym koszcie – mierzą responsywność maszyny, nie „deklarowaną” poprawę.
public enum MicroBenchmark {
    /// Czas (ms) obliczenia SHA-256 z 8 MB danych.
    public static func cpuWorkMs() -> Double {
        let data = Data(repeating: 0xA5, count: 8 << 20)
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = SHA256Digest.hex(data)
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }
    /// Czas (ms) utworzenia, odczytu i usunięcia 200 małych plików w katalogu tymczasowym.
    public static func smallFileOpsMs(in dir: URL = FileManager.default.temporaryDirectory) -> Double {
        let d = dir.appendingPathComponent("maccare-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }   // try? świadomie: własny katalog tymczasowy pomiaru
        let payload = Data(repeating: 0x42, count: 4096)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<200 {
            let f = d.appendingPathComponent("f\(i)")
            try? payload.write(to: f)
            _ = try? Data(contentsOf: f)
            try? FileManager.default.removeItem(at: f)   // try? świadomie: własny plik tymczasowy pomiaru
        }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }
}
