#if os(macOS)
import Foundation
import ImageIO
import CoreGraphics
import MacCareCore

/// Podobne zdjęcia (P2-13, część): dHash z miniatury obrazu (ImageIO – korzysta z miniatur osadzonych w plikach, bez dekodowania pełnej rozdzielczości).
/// Tylko odczyt. Formaty RAW są pomijane (dekodowanie byłoby kosztowne, a kopie RAW i tak wykrywa porównanie treści w „Duplikatach”).
public enum ImageHasher {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    public static func dHash(path: String) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: false]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        var px = [UInt8](repeating: 0, count: 9 * 8)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard ok else { return nil }
        let rows = (0..<8).map { r in (0..<9).map { c in Double(px[r * 9 + c]) } }
        return PerceptualHash.dHash(luminance9x8: rows)
    }

    public struct ScanResult: Sendable {
        public var groups: [[FileEntry]]
        public var imagesChecked: Int
        public var complete: Bool
    }

    /// Przeszukuje `root` (pliki użytkownika: bez danych programów, projektów, Kosza, bibliotek Zdjęć) i grupuje podobne obrazy.
    public static func similar(root: String, minSize: UInt64 = 100_000, threshold: Int = 5, maxImages: Int = 5000, timeLimit: TimeInterval = 120,
                               isCancelled: @Sendable () -> Bool = { false }) -> ScanResult {
        let deadline = Date().addingTimeInterval(timeLimit)
        var entries: [FileEntry] = []
        var complete = true
        let walk = DiskAnalyzer.enumerate(root: root, deadline: deadline, minSize: minSize, isCancelled: isCancelled) { f in
            guard f.size >= minSize, extensions.contains((f.path as NSString).pathExtension.lowercased()),
                  !DuplicateFinder.skippedKinds.contains(f.kind), !f.path.contains("/.Trash/") else { return }
            if entries.count < maxImages { entries.append(f) } else { complete = false }
        }
        if !walk.isComplete { complete = false }                                            // audyt 2: foldery bez dostępu / limit czasu = niepełny
        var hashes: [(path: String, hash: UInt64)] = []
        for e in entries {
            if isCancelled() || Date() > deadline.addingTimeInterval(timeLimit) { complete = false; break }
            if let h = autoreleasepool(invoking: { dHash(path: e.path) }) { hashes.append((e.path, h)) }
        }
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = PerceptualHash.groups(hashes, threshold: threshold).filter { $0.count > 1 }
            .map { $0.compactMap { byPath[$0] }.sorted { $0.size > $1.size } }
            .sorted { $0.reduce(0) { $0 + $1.size } > $1.reduce(0) { $0 + $1.size } }
        return ScanResult(groups: groups, imagesChecked: hashes.count, complete: complete)
    }
}
#endif
