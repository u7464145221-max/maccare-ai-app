#if os(macOS)
import Foundation
import Security
import MacCareCore

public struct SignatureResult: Sendable, Equatable {
    public var status: SignatureStatus
    public var teamID: String?
    public var signerName: String?
    public init(_ status: SignatureStatus, teamID: String? = nil, signerName: String? = nil) {
        self.status = status; self.teamID = teamID; self.signerName = signerName
    }
}

/// Weryfikacja podpisu kodu przez Security.framework (bez uruchamiania pliku i bez zewnętrznych poleceń).
public enum CodeSignatureChecker {
    private static let appStoreReq = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"
    private static let devIDChain = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    /// `SecStaticCodeCheckValidity` blokuje wątek, czekając na pracę z grupy dispatch. Wywołane równolegle z wątków puli
    /// Swift Concurrency (po jednym na rdzeń) wyczerpuje pulę i zawiesza cały proces (zmierzone: 10 wątków w `Dispatch::Group::wait`,
    /// zero wątków roboczych Security). Dlatego WSZYSTKIE sprawdzenia idą na jedną dedykowaną kolejkę szeregową, a wywołujący tylko
    /// asynchronicznie czeka – wątki puli pozostają wolne. Publiczne API jest celowo wyłącznie asynchroniczne.
    private static let queue = DispatchQueue(label: "io.github.u7464145221-max.maccare.codesign", qos: .utility)

    /// - Parameter deep: `false` = tylko podstawowa weryfikacja podpisu (`kSecCSBasicValidateOnly`) – dużo szybsza dla dużych pakietów
    ///   (inwentarz aplikacji); nie wykrywa podmiany zasobów wewnątrz pakietu.
    public static func check(path: String, deep: Bool = true) async -> SignatureResult {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: checkCachedOnQueue(path: path, deep: deep)) }
        }
    }

    // MARK: Pamięć wyników (P2-6 / AUD-PERF-2)
    /// Wynik weryfikacji zapamiętany po ścieżce i odcisku pliku (urządzenie, inode, rozmiar, mtime); ważny `cacheTTL`. Dostęp WYŁĄCZNIE z kolejki `queue`.
    /// Wzbogacanie co 5 min nie weryfikuje więc ponownie kilkudziesięciu niezmienionych programów; zmiana pliku albo upływ czasu ⇒ pełna weryfikacja.
    private struct CacheEntry { var fingerprint: String; var at: Date; var result: SignatureResult }
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]
    nonisolated(unsafe) private static var _verifications: [String: Int] = [:]
    static let cacheTTL: TimeInterval = 3600

    /// Liczba faktycznych weryfikacji Security.framework dla ścieżki (do testów pamięci wyników).
    static func verifications(of path: String) -> Int { queue.sync { _verifications[path] ?? 0 } }

    private static func checkCachedOnQueue(path: String, deep: Bool, now: Date = Date()) -> SignatureResult {
        let key = (deep ? "deep|" : "basic|") + path
        let fp = FileStat.of(path).map { "\($0.device):\($0.inode):\($0.logicalSize):\($0.modified.timeIntervalSince1970)" }
        if let fp, let e = cache[key], e.fingerprint == fp, now.timeIntervalSince(e.at) < cacheTTL { return e.result }
        _verifications[path, default: 0] += 1
        let r = checkBlocking(path: path, deep: deep)
        if let fp, r.status != .notChecked { cache[key] = CacheEntry(fingerprint: fp, at: now, result: r) }
        if cache.count > 2000 { cache.removeAll(keepingCapacity: true); _verifications.removeAll() }
        return r
    }

    static func checkBlocking(path: String, deep: Bool = true) -> SignatureResult {
        guard FileManager.default.fileExists(atPath: path) else { return SignatureResult(.missingBinary) }
        // Plik istnieje, ale nie mamy prawa go czytać (np. pomocnik root z trybem --x--x--x): nie wiemy, jaki ma podpis.
        // „Brak podpisu” byłby fałszywym oskarżeniem, więc zwracamy „nie sprawdzono”.
        guard access(path, R_OK) == 0 else { return SignatureResult(.notChecked) }
        var created: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &created) == errSecSuccess, let code = created else {
            return SignatureResult(.unsigned)
        }
        let validity = SecStaticCodeCheckValidity(code, deep ? [] : SecCSFlags(rawValue: UInt32(kSecCSBasicValidateOnly)), nil)
        if validity == errSecCSUnsigned { return SignatureResult(.unsigned) }
        guard validity == errSecSuccess else { return SignatureResult(.invalid) }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        var signer: String?
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            signer = SecCertificateCopySubjectSummary(leaf) as String?
        }

        let kind = Classification(
            adHoc: flags & 0x2 != 0, apple: satisfies(code, "anchor apple"), appStore: satisfies(code, appStoreReq),
            developerIDChain: satisfies(code, devIDChain), notarized: satisfies(code, devIDChain + " and notarized"))
        return SignatureResult(classify(kind), teamID: team, signerName: kind.apple ? (signer ?? "Apple") : signer)
    }

    /// Zestaw faktów o podpisie – wejście czystej klasyfikacji (testowalnej bez prawdziwych certyfikatów).
    struct Classification: Equatable {
        var adHoc = false, apple = false, appStore = false, developerIDChain = false, notarized = false
    }

    /// Kolejność ma znaczenie: ad-hoc nie niesie tożsamości; potem Apple, App Store, Developer ID (z notaryzacją albo bez);
    /// pozostałe poprawne podpisy (self-signed, certyfikat deweloperski) to certyfikat spoza łańcucha Apple.
    static func classify(_ c: Classification) -> SignatureStatus {
        if c.adHoc { return .adHoc }
        if c.apple { return .appleSigned }
        if c.appStore { return .appStore }
        if c.developerIDChain { return c.notarized ? .developerID : .developerIDNotNotarized }
        return .untrustedCertificate
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let r = req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSBasicValidateOnly)), r) == errSecSuccess
    }
}
#endif
