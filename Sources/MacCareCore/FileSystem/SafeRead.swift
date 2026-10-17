import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Audyt 2 (17.10, pkt 2.3): odczyt NIEUFNYCH plików z dysku (plisty autostartu, raporty awarii). `FileManager.contents(atPath:)` podąża za
/// dowiązaniem i czyta wszystko – dowiązanie do `/dev/zero` wyczerpuje pamięć, a FIFO zawiesza odczyt na zawsze. Tu: bez podążania za dowiązaniem,
/// bez blokowania, tylko plik ZWYKŁY, rozmiar sprawdzany na tym samym otwartym deskryptorze (bez okna TOCTOU).
public enum SafeRead {
    /// Cała zawartość, gdy plik zwykły ma najwyżej `maxBytes`; inaczej nil.
    public static func regularFile(_ path: String, maxBytes: Int) -> Data? { read(path, maxBytes: maxBytes, prefixOnly: false) }

    /// Początek pliku (najwyżej `bytes`) – dla nagłówków dużych plików; nil, gdy to nie plik zwykły.
    public static func prefix(_ path: String, bytes: Int) -> Data? { read(path, maxBytes: bytes, prefixOnly: true) }

    private static func read(_ path: String, maxBytes: Int, prefixOnly: Bool) -> Data? {
        #if canImport(Darwin)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        if !prefixOnly && st.st_size > off_t(maxBytes) { return nil }
        let want = Int(min(off_t(maxBytes), st.st_size))
        var buf = [UInt8](repeating: 0, count: max(0, want))
        var got = 0
        while got < want {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, want - got, off_t(got)) }
            if n <= 0 { break }
            got += n
        }
        return Data(buf.prefix(got))
        #else
        return FileManager.default.contents(atPath: path).map { prefixOnly ? $0.prefix(maxBytes) : $0 }.flatMap { prefixOnly || $0.count <= maxBytes ? Data($0) : nil }
        #endif
    }
}
