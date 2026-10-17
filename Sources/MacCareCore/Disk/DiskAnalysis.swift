import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var size: UInt64            // zajęte bloki
    public var modified: Date
    public var accessed: Date
    public var kind: FileKind
}

public enum FileKind: String, Codable, Sendable, CaseIterable {
    case image, video, audio, archive, installer, document, code, diskImage, other
    /// Rodzaje „kontekstowe” – wynikają ze ŚCIEŻKI, nie z rozszerzenia (np. blob bez rozszerzenia w `~/.ollama`).
    case aiModel, container, project, appData, application

    /// Rodzaj pliku: najpierw kontekst ścieżki (aplikacja, model AI, kontener/VM, projekt i zależności, dane aplikacji), potem rozszerzenie.
    public static func of(_ path: String) -> FileKind {
        var c = FileKindClassifier()
        return c.kind(of: path)
    }

    /// Tablice rozszerzeń (AUD-SCAN-6 / W6). macOS (UTType) nie zna części formatów twórczych (np. indd, afphoto, sketch, braw, r3d, daf), więc lista jest statyczna.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp", "ico", "avif", "jxl", "exr", "tga", "svg", "eps",
        // RAW aparatów
        "raw", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "rwl", "srw", "pef", "3fr", "fff", "iiq", "erf", "mrw", "kdc", "dcr", "x3f", "gpr",
        // grafika robocza
        "psd", "psb", "ai", "xcf", "afphoto", "afdesign", "sketch", "fig", "kra", "clip"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mxf", "braw", "r3d", "mts", "m2ts", "mpg", "mpeg", "wmv", "flv", "3gp", "vob", "ogv", "crm"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "opus", "wma", "caf", "mid", "midi", "alac"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar", "zst", "lz4", "lzma", "lz", "z", "cab", "arj",
                                                 "daf"]       // .daf = DupArchive (kopia zapasowa Duplicator Pro dla WordPressa)
    static let diskImageExtensions: Set<String> = ["dmg", "iso", "toast", "cdr", "sparseimage", "sparsebundle", "img"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "xlsm", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "csv",
                                                  "md", "odt", "ods", "odp", "epub", "indd", "afpub"]

    public static func byExtension(_ path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if archiveExtensions.contains(ext) { return .archive }
        if diskImageExtensions.contains(ext) { return .diskImage }
        if documentExtensions.contains(ext) { return .document }
        switch ext {
        case "pkg", "mpkg", "xip": return .installer
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m": return .code
        case "gguf", "ggml", "safetensors", "ckpt", "onnx", "pth", "tflite": return .aiModel
        case "vmdk", "qcow2", "vdi", "vhd", "vhdx", "utm", "pvm": return .container
        default: return .other
        }
    }

    public var label: String {
        switch self {
        case .image: return String(localized: "Obrazy"); case .video: return String(localized: "Wideo"); case .audio: return String(localized: "Audio"); case .archive: return String(localized: "Archiwa")
        case .installer: return String(localized: "Instalatory"); case .document: return String(localized: "Dokumenty"); case .code: return String(localized: "Kod"); case .diskImage: return String(localized: "Obrazy dysków"); case .other: return String(localized: "Inne")
        case .aiModel: return String(localized: "Modele AI"); case .container: return String(localized: "Kontenery i maszyny wirtualne"); case .project: return String(localized: "Projekty i zależności")
        case .appData: return String(localized: "Dane aplikacji"); case .application: return String(localized: "Aplikacje")
        }
    }
}

/// Klasyfikator z buforem na FOLDER: kontekst zależy tylko od katalogu nadrzędnego, więc dla milionów plików liczymy go raz na folder.
public struct FileKindClassifier: Sendable {
    private var cache: [String: FileKind?] = [:]
    public init() {}

    static let aiDirs: Set<Substring> = [".ollama", ".lmstudio", "lm-studio", "huggingface", "gpt4all", ".gpt4all", "llama.cpp"]
    static let containerDirs: Set<Substring> = [".docker", "com.docker.docker", ".colima", ".lima", "OrbStack", "UTM", "Parallels", "Virtual Machines", "VirtualBox VMs", ".minikube"]
    static let projectDirs: Set<Substring> = ["node_modules", ".venv", "venv", "DerivedData", ".git", "Pods", ".gradle", ".build", ".npm", ".cargo", ".rustup",
                                              ".m2", "site-packages", "__pycache__", ".pnpm-store", ".yarn", ".bun", "Carthage", ".swiftpm", "bower_components", ".next", ".nuxt"]
    static let appDataDirs: Set<Substring> = ["Library", "Application Support", "Caches", "Containers", "Group Containers"]

    public mutating func kind(of path: String) -> FileKind {
        let dir = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        return kind(directory: dir, name: path)
    }

    /// Jak `kind(of:)`, bez sklejania ścieżki (szybki skaner zna katalog i nazwę osobno). `name` może być samą nazwą albo pełną ścieżką – liczy się rozszerzenie.
    public mutating func kind(directory dir: String, name: String) -> FileKind {
        let ctx: FileKind?
        if let hit = cache[dir] { ctx = hit } else { ctx = Self.contextKind(directory: dir); cache[dir] = .some(ctx) }
        return ctx ?? FileKind.byExtension(name)
    }

    /// Rodzaj wynikający wyłącznie z katalogu (nil = decyduje rozszerzenie). Kolejność: aplikacja → model AI → kontener/VM → projekt → dane aplikacji.
    static func contextKind(directory: String) -> FileKind? {
        let comps = directory.split(separator: "/")
        if comps.contains(where: { $0.hasSuffix(".app") }) { return .application }
        if comps.contains(where: { aiDirs.contains($0) }) { return .aiModel }
        if comps.contains(where: { containerDirs.contains($0) }) { return .container }
        if comps.contains(where: { projectDirs.contains($0) }) { return .project }
        if comps.contains(".Trash") { return nil }                                    // Kosz: decyduje rozszerzenie
        if comps.contains(where: { appDataDirs.contains($0) || ($0.hasPrefix(".") && $0.count > 1) }) { return .appData }
        return nil
    }
}

public struct FileFilter: Sendable {
    public var minSize: UInt64 = 0
    public var olderThanDays: Int?
    public var kinds: Set<FileKind>?
    public init(minSize: UInt64 = 0, olderThanDays: Int? = nil, kinds: Set<FileKind>? = nil) { self.minSize = minSize; self.olderThanDays = olderThanDays; self.kinds = kinds }
    public func matches(_ e: FileEntry, now: Date) -> Bool {
        if e.size < minSize { return false }
        if let d = olderThanDays, now.timeIntervalSince(max(e.modified, e.accessed)) < Double(d) * 86400 { return false }
        if let k = kinds, !k.contains(e.kind) { return false }
        return true
    }
}

/// Węzeł mapy dysku (wizualizacja hierarchiczna).
public final class DirectoryNode: @unchecked Sendable, Identifiable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public internal(set) var size: UInt64 = 0
    public internal(set) var children: [DirectoryNode] = []
    public internal(set) var fileCount = 0
    public var id: String { path }
    init(path: String, isDirectory: Bool) { self.path = path; self.name = (path as NSString).lastPathComponent; self.isDirectory = isDirectory }
}

public enum DiskAnalyzer {
    /// Przechodzi drzewo bez podążania za symlinkami, licząc każdy inode raz (twarde dowiązania).
    public static func enumerate(root: String, skip: Set<String> = [], deadline: Date? = nil,
                                 isCancelled: @Sendable () -> Bool = { false }, visit: (FileEntry) -> Void) {
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        var seen = Set<FileID>()
        forEachEntry(of: e) { rel in
            if isCancelled() { return false }
            if let d = deadline, Date() > d { return false }
            let p = root + "/" + rel
            guard let st = FileStat.of(p) else { return true }
            if st.isSymlink { return true }
            if st.isDirectory {
                if skip.contains(p) || p.hasSuffix(".photoslibrary") { e.skipDescendants() }
                return true
            }
            guard st.isRegular, seen.insert(st.fileID).inserted else { return true }
            visit(FileEntry(path: p, size: st.allocatedSize, modified: st.modified, accessed: st.accessed, kind: .of(p)))
            return true
        }
    }

    public static func largeFiles(root: String, filter: FileFilter, limit: Int = 100, skip: Set<String> = [],
                                  now: Date = Date(), deadline: Date? = nil) -> [FileEntry] {
        var out: [FileEntry] = []
        enumerate(root: root, skip: skip, deadline: deadline) { if filter.matches($0, now: now) { out.append($0) } }
        return Array(out.sorted { $0.size > $1.size }.prefix(limit))
    }

    /// Buduje drzewo do zadanej głębokości (głębsze poziomy agregowane do rodzica).
    public static func tree(root: String, maxDepth: Int = 3, deadline: Date? = nil) -> DirectoryNode {
        let node = DirectoryNode(path: root, isDirectory: true)
        var seen = Set<FileID>()
        build(node, depth: 0, maxDepth: maxDepth, deadline: deadline, seen: &seen)
        return node
    }

    private static func build(_ node: DirectoryNode, depth: Int, maxDepth: Int, deadline: Date?, seen: inout Set<FileID>) {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: node.path) else { return }   // try? świadomie: nieczytelny katalog ⇒ brak wpisów (tylko odczyt)
        for k in kids {
            if let d = deadline, Date() > d { break }
            let p = node.path + "/" + k
            guard let st = FileStat.of(p), !st.isSymlink else { continue }
            if st.isDirectory {
                let child = DirectoryNode(path: p, isDirectory: true)
                if depth + 1 < maxDepth { build(child, depth: depth + 1, maxDepth: maxDepth, deadline: deadline, seen: &seen) }
                else { let u = DiskUsage.measure(p, deadline: deadline, seen: &seen); child.size = u.allocated; child.fileCount = u.fileCount }
                node.size += child.size; node.fileCount += child.fileCount
                node.children.append(child)
            } else if st.isRegular, seen.insert(st.fileID).inserted {
                let f = DirectoryNode(path: p, isDirectory: false); f.size = st.allocatedSize; f.fileCount = 1
                node.size += f.size; node.fileCount += 1
                node.children.append(f)
            }
        }
        node.children.sort { $0.size > $1.size }
    }
}

// MARK: - Duplikaty

public struct DuplicateGroup: Codable, Sendable, Identifiable {
    public var id: String { hash }
    public var hash: String
    public var fileSize: UInt64
    public var paths: [String]
    /// Pary, które są już tym samym inode (twarde dowiązanie) – usunięcie nic nie da, pomijane.
    public var hardLinkedPaths: [String]
    /// Pliki z tej samej rodziny klonów APFS – dane już współdzielone, oszczędność ~0.
    public var clonedPaths: [String]
    /// Ostrożny szacunek: (n-1) kopii × rozmiar, z wyłączeniem dowiązań i klonów.
    public var reclaimableEstimate: UInt64
}

public enum DuplicateFinder {
    /// Etapy: rozmiar → skrót z pierwszych/ostatnich 64 KB → pełny SHA-256. Porównanie wyłącznie po treści.
    public static func find(files: [FileEntry], minSize: UInt64 = 1, clones: CloneInfoProvider = NoCloneInfo(),
                            isCancelled: @Sendable () -> Bool = { false }) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: files.filter { $0.size >= minSize }, by: { FileStat.of($0.path)?.logicalSize ?? 0 })
        var groups: [DuplicateGroup] = []
        for (size, same) in bySize where same.count > 1 && size > 0 {
            if isCancelled() { break }
            // Twarde dowiązania: ten sam inode = ten sam plik, nie duplikat.
            var byInode: [FileID: [String]] = [:]
            for f in same { if let st = FileStat.of(f.path) { byInode[st.fileID, default: []].append(f.path) } }
            let reps = byInode.values.map { $0[0] }
            // P3-7 (AUD-SCAN-5): dowiązania przypisane do SWOJEGO przedstawiciela – grupa dostaje tylko dowiązania własnych plików, nie całego koszyka rozmiaru
            var linksOf: [String: [String]] = [:]
            for v in byInode.values where v.count > 1 { linksOf[v[0]] = Array(v.dropFirst()) }
            guard reps.count > 1 else { continue }
            let byPartial = Dictionary(grouping: reps, by: { partialHash($0, size: size) ?? UUID().uuidString })
            for (_, cand) in byPartial where cand.count > 1 {
                let byFull = Dictionary(grouping: cand, by: { fullHash($0) ?? UUID().uuidString })
                for (h, paths) in byFull where paths.count > 1 {
                    var cloneFamilies: [UInt64: [String]] = [:]
                    var uncloned: [String] = []
                    for p in paths { if let c = clones.cloneID(path: p) { cloneFamilies[c, default: []].append(p) } else { uncloned.append(p) } }
                    let clonedExtra = cloneFamilies.values.filter { $0.count > 1 }.flatMap { $0.dropFirst() }
                    let distinctCopies = uncloned.count + cloneFamilies.count
                    let alloc = FileStat.of(paths[0])?.allocatedSize ?? size
                    groups.append(DuplicateGroup(hash: h, fileSize: size, paths: paths.sorted(), hardLinkedPaths: paths.flatMap { linksOf[$0] ?? [] }.sorted(),
                                                 clonedPaths: Array(clonedExtra), reclaimableEstimate: UInt64(max(0, distinctCopies - 1)) * alloc))
                }
            }
        }
        return groups.sorted { $0.reclaimableEstimate > $1.reclaimableEstimate }
    }

    /// Wynik przeszukania folderu: grupy, liczba porównanych plików i czy przejście było pełne (limit czasu/plików ⇒ `complete == false`).
    public struct ScanResult: Sendable {
        public var groups: [DuplicateGroup]
        public var candidateFiles: Int
        public var complete: Bool
    }

    /// Rodzaje pomijane przy szukaniu duplikatów: dane programów, zależności projektów, kontenery/VM, modele AI i wnętrza aplikacji – kopie są tam zamierzone,
    /// a ich usunięcie psułoby programy. Szukamy w plikach UŻYTKOWNIKA.
    public static let skippedKinds: Set<FileKind> = [.appData, .project, .container, .aiModel, .application]

    /// Przeszukuje `root` (tylko odczyt): pliki ≥ `minSize`, bez rodzajów z `skippedKinds`, potem `find` (rozmiar → skrót części → pełny SHA-256).
    public static func scan(root: String, minSize: UInt64 = 1_000_000, clones: CloneInfoProvider = NoCloneInfo(), timeLimit: TimeInterval = 180,
                            maxFiles: Int = 200_000, isCancelled: @Sendable () -> Bool = { false }) -> ScanResult {
        let deadline = Date().addingTimeInterval(timeLimit)
        var files: [FileEntry] = []
        var complete = true
        DiskAnalyzer.enumerate(root: root, deadline: deadline, isCancelled: isCancelled) { f in
            // Kosz pomijamy: proponowanie przeniesienia do Kosza czegoś, co już w nim jest, nie ma sensu
            guard f.size >= minSize, !skippedKinds.contains(f.kind), !f.path.contains("/.Trash/") else { return }
            if files.count < maxFiles { files.append(f) } else { complete = false }
        }
        if Date() > deadline || isCancelled() { complete = false }
        let hashDeadline = deadline.addingTimeInterval(timeLimit)                  // porównanie treści ma osobny limit tej samej długości
        let groups = find(files: files, minSize: minSize, clones: clones, isCancelled: { isCancelled() || Date() > hashDeadline })
        if Date() > hashDeadline { complete = false }
        return ScanResult(groups: groups, candidateFiles: files.count, complete: complete && !isCancelled())
    }

    static func partialHash(_ path: String, size: UInt64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }   // try? świadomie: zamknięcie uchwytu tylko do odczytu
        let chunk = 65_536
        var data = h.readData(ofLength: chunk)
        if size > UInt64(chunk * 2) { h.seek(toFileOffset: size - UInt64(chunk)); data.append(h.readData(ofLength: chunk)) }
        return SHA256Digest.hex(data)
    }

    static func fullHash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }   // try? świadomie: zamknięcie uchwytu tylko do odczytu
        var hasher = SHA256Digest()
        while true {
            let d = h.readData(ofLength: 1 << 20)
            if d.isEmpty { break }
            hasher.update(d)
        }
        return hasher.finalizeHex()
    }
}

// MARK: - Podobne zdjęcia (dHash)

public enum PerceptualHash {
    /// dHash 64-bit z macierzy jasności 9×8 (wiersze × kolumny = 8 × 9). Skalowanie obrazu robi warstwa macOS (ImageIO).
    public static func dHash(luminance9x8 px: [[Double]]) -> UInt64? {
        guard px.count == 8, px.allSatisfy({ $0.count == 9 }) else { return nil }
        var h: UInt64 = 0
        for r in 0..<8 { for c in 0..<8 { h <<= 1; if px[r][c] > px[r][c + 1] { h |= 1 } } }
        return h
    }
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Grupowanie: łączy obrazy o odległości Hamminga ≤ threshold (domyślnie 6/64).
    public static func groups(_ hashes: [(path: String, hash: UInt64)], threshold: Int = 6) -> [[String]] {
        var parent = Array(0..<hashes.count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in 0..<hashes.count { for j in (i + 1)..<max(i + 1, hashes.count) where distance(hashes[i].hash, hashes[j].hash) <= threshold { parent[find(i)] = find(j) } }
        let g = Dictionary(grouping: hashes.indices, by: find)
        return g.values.filter { $0.count > 1 }.map { $0.map { hashes[$0].path }.sorted() }
    }
}

// MARK: - SHA-256 (CryptoKit na macOS; czysta implementacja jako zapas na innych platformach)

public struct SHA256Digest {
    #if canImport(CryptoKit)
    private var h = SHA256()
    public init() {}
    public mutating func update(_ d: Data) { h.update(data: d) }
    public func finalizeHex() -> String { h.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
    public init() {}
    public mutating func update(_ d: Data) {
        length += UInt64(d.count); buffer.append(contentsOf: d)
        while buffer.count >= 64 { block(Array(buffer[0..<64])); buffer.removeFirst(64) }
    }
    private mutating func block(_ b: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { w[i] = UInt32(b[i*4]) << 24 | UInt32(b[i*4+1]) << 16 | UInt32(b[i*4+2]) << 8 | UInt32(b[i*4+3]) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for i in 16..<64 {
            let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
            let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
            w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
        }
        var a = state[0], bb = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ S1 &+ ch &+ Self.k[i] &+ w[i]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & bb) ^ (a & c) ^ (bb & c)
            let t2 = S0 &+ maj
            h = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d; state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
    public func finalizeHex() -> String {
        var copy = self
        var tail = copy.buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length * 8
        for i in (0..<8).reversed() { tail.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
        copy.buffer = []
        var i = 0
        while i < tail.count { copy.block(Array(tail[i..<i+64])); i += 64 }
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }
    #endif
    public static func hex(_ d: Data) -> String { var s = SHA256Digest(); s.update(d); return s.finalizeHex() }
}
