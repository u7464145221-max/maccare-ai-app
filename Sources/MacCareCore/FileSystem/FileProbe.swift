import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Informacje o pliku z `lstat` (bez podążania za dowiązaniami symbolicznymi).
public struct FileStat: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public var linkCount: UInt64
    public var logicalSize: UInt64
    public var allocatedSize: UInt64
    public var isDirectory: Bool
    public var isRegular: Bool
    public var isSymlink: Bool
    public var modified: Date
    public var accessed: Date
    public var ownerUID: UInt32

    public static func of(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mode = UInt32(st.st_mode) & UInt32(S_IFMT)
        #if canImport(Darwin)
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let atime = Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1e9
        #else
        let mtime = Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
        let atime = Double(st.st_atim.tv_sec) + Double(st.st_atim.tv_nsec) / 1e9
        #endif
        return FileStat(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino), linkCount: UInt64(truncatingIfNeeded: st.st_nlink),
                        logicalSize: UInt64(max(0, st.st_size)), allocatedSize: UInt64(max(0, st.st_blocks)) * 512,
                        isDirectory: mode == UInt32(S_IFDIR), isRegular: mode == UInt32(S_IFREG), isSymlink: mode == UInt32(S_IFLNK),
                        modified: Date(timeIntervalSince1970: mtime), accessed: Date(timeIntervalSince1970: atime), ownerUID: UInt32(truncatingIfNeeded: st.st_uid))
    }

    public var fileID: FileID { FileID(device: device, inode: inode) }
}

public struct FileID: Hashable, Sendable { public var device: UInt64; public var inode: UInt64 }

/// Wspólny rejestr plików z kilkoma dowiązaniami twardymi dla pomiarów RODZEŃSTWA wykonywanych równolegle (mapa dysku): każdy taki plik liczy się raz –
/// u tego dziecka, które trafi na niego pierwsze (suma rodzica jak w `du`; np. magazyn pnpm w ~/Library i jego dowiązania w node_modules projektów).
/// Przydział do konkretnego dziecka zależy od kolejności przejścia, suma – nie. Dotyczy tylko plików z `nlink > 1`, więc blokada jest rzadko używana.
public final class HardLinkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<FileID>()
    public init() {}
    /// true = ten pomiar liczy plik (pierwszy go zobaczył).
    func claim(_ id: FileID) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.insert(id).inserted }
    /// Zwrot przydziałów przerwanego szybkiego przejścia (stara ścieżka policzy te pliki ponownie).
    func release<S: Sequence>(_ released: S) where S.Element == FileID { lock.lock(); defer { lock.unlock() }; for id in released { ids.remove(id) } }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
}

/// Opcjonalny dostawca informacji o klonach APFS (na macOS: getattrlist ATTR_CMNEXT_PRIVATESIZE / CLONEID).
/// Na innych platformach brak – wtedy szacunki są ostrożne (patrz `DiskUsage`).
public protocol CloneInfoProvider: Sendable {
    /// Bajty należące wyłącznie do tego pliku (nie współdzielone z klonami). nil = nieznane.
    func privateSize(path: String) -> UInt64?
    /// Identyfikator rodziny klonów. nil = nieznany lub brak.
    func cloneID(path: String) -> UInt64?
}

public struct NoCloneInfo: CloneInfoProvider {
    public init() {}
    public func privateSize(path: String) -> UInt64? { nil }
    public func cloneID(path: String) -> UInt64? { nil }
}

/// Liczenie zajętości z uwzględnieniem twardych dowiązań (każdy inode liczony raz) i bez podążania za symlinkami.
/// Przechodzi enumerator z pulą autorelease opróżnianą co `batch` wpisów (AUD-PERF-3): `nextObject()` zwraca autoreleased `NSString` dla każdego wpisu,
/// a bez własnej puli wszystkie czekają do końca skanu (≈ 1 KB/plik). `body` zwraca `false`, by zakończyć przejście; `skipDescendants` działa jak zwykle.
func forEachEntry(of e: FileManager.DirectoryEnumerator, batch: Int = 1000, _ body: (String) -> Bool) {
    var finished = false
    while !finished {
        autoreleasepoolIfAvailable {
            for _ in 0..<batch {
                guard let rel = e.nextObject() as? String, body(rel) else { finished = true; return }
            }
        }
    }
}

@inline(__always) private func autoreleasepoolIfAvailable(_ body: () -> Void) {
    #if canImport(ObjectiveC)
    autoreleasepool(invoking: body)
    #else
    body()
    #endif
}

public struct DiskUsage: Sendable {
    public var allocated: UInt64 = 0
    /// Ile realnie wróci po usunięciu: pliki z nlink>1, których inne dowiązania leżą poza usuwanym zbiorem,
    /// oraz klony APFS (część współdzielona) NIE są tu liczone.
    public var reclaimable: UInt64 = 0
    public var fileCount = 0
    public var hardLinkedFiles = 0
    public var unreadable = 0
    /// Próbka ścieżek bez dostępu (najwyżej `maxUnreadablePaths`) – do komunikatu „skan niepełny” (P1-4).
    public var unreadablePaths: [String] = []
    public static let maxUnreadablePaths = 20

    /// Czy katalog da się wylistować. `enumerator(atPath:)` po cichu pomija katalogi bez dostępu (POSIX albo odmowa TCC – EPERM), więc sprawdzamy to sami (P1-4).
    public static func canList(_ dir: String) -> Bool {
        guard let d = opendir(dir) else { return false }
        closedir(d)
        return true
    }

    mutating func noteUnreadable(_ path: String) {
        unreadable += 1
        if unreadablePaths.count < Self.maxUnreadablePaths { unreadablePaths.append(path) }
    }
    /// Zajętość według rodzaju pliku (tylko gdy `trackKinds: true`). Do kolorowania folderów na mapie dysku.
    public var bytesByKind: [FileKind: UInt64] = [:]
    var classifier = FileKindClassifier()
    /// Rodzaj o największej zajętości (z `.other` włącznie – szczerze: „nieznane” też bywa największe).
    public var dominantKind: FileKind? { bytesByKind.max { $0.value < $1.value }?.key }

    public static func measure(_ root: String, clones: CloneInfoProvider = NoCloneInfo(), deadline: Date? = nil,
                               trackKinds: Bool = false, seen: inout Set<FileID>) -> DiskUsage {
        var u = DiskUsage()
        guard let st = FileStat.of(root) else { u.unreadable = 1; return u }
        if st.isSymlink { return u }
        if !st.isDirectory {
            u.add(st, path: root, clones: clones, trackKinds: trackKinds, seen: &seen)
            return u
        }
        guard canList(root) else { u.noteUnreadable(root); return u }
        #if canImport(Darwin)
        if useBulkWalker, let fast = measureBulk(root, clones: clones, deadline: deadline, trackKinds: trackKinds, seen: &seen) { return fast }
        #endif
        return measureLegacy(root, clones: clones, deadline: deadline, trackKinds: trackKinds, seen: &seen)
    }

    /// Szybka ścieżka (`BulkWalker`) dla katalogów; `false` = zawsze stara ścieżka (testy porównawcze, diagnostyka).
    nonisolated(unsafe) static var useBulkWalker = true

    /// Stara ścieżka: `FileManager.enumerator` + `lstat` na wpis. Rezerwa, gdy system plików nie obsługuje `getattrlistbulk`, i punkt odniesienia w testach zgodności.
    static func measureLegacy(_ root: String, clones: CloneInfoProvider = NoCloneInfo(), deadline: Date? = nil,
                              trackKinds: Bool = false, seen: inout Set<FileID>) -> DiskUsage {
        var u = DiskUsage()
        guard canList(root), let e = FileManager.default.enumerator(atPath: root) else { u.noteUnreadable(root); return u }
        forEachEntry(of: e) { rel in
            if let d = deadline, Date() > d { return false }
            let p = root + "/" + rel
            guard let s = FileStat.of(p) else { u.noteUnreadable(p); return true }
            if s.isSymlink { if s.isDirectory { e.skipDescendants() }; return true }
            if s.isRegular { u.add(s, path: p, clones: clones, trackKinds: trackKinds, seen: &seen) }
            else if s.isDirectory {
                u.allocated += s.allocatedSize; u.reclaimable += s.allocatedSize
                if !canList(p) { u.noteUnreadable(p); e.skipDescendants() }
            }
            return true
        }
        u.classifier = FileKindClassifier()                       // bufor folderów nie ma opuszczać pomiaru
        return u
    }

    public static func measure(_ root: String, clones: CloneInfoProvider = NoCloneInfo(), trackKinds: Bool = false) -> DiskUsage {
        var seen = Set<FileID>()
        return measure(root, clones: clones, trackKinds: trackKinds, seen: &seen)
    }

    /// Wynik jednego przejścia po drzewie: suma dla korzenia oraz OSOBNE sumy dla jego dzieci pierwszego poziomu (klucz = nazwa dziecka).
    /// Dzięki temu skan folderu-rodzica daje od razu zawartość każdego z jego podfolderów (mapa dysku nie liczy tego samego poddrzewa drugi raz – W1).
    public struct Tree: Sendable {
        public struct Child: Sendable {
            public var usage: DiskUsage
            public var isDirectory: Bool
            public var modified: Date
        }
        public var total = DiskUsage()
        public var children: [String: Child] = [:]
    }

    /// Jak `measure`, ale z podziałem na dzieci pierwszego poziomu. Suma `total` jest taka sama jak z `measure`; suma dziecka = `measure(dziecko)`
    /// (własny wpis katalogu dziecka nie jest wliczany do jego sumy, tak samo jak w `measure`), z jednym wyjątkiem: twarde dowiązania są deduplikowane
    /// wspólnie w obrębie korzenia (przez `seen`), więc plik z dowiązaniem w dwóch dzieciach trafia tylko do pierwszego z nich.
    /// `shared` – rejestr dowiązań wspólny dla rodzeństwa mierzonego równolegle (wtedy `seen` zbiera tylko pliki przydzielone temu pomiarowi);
    /// `shouldStop` – przerwanie (np. użytkownik przeszedł do innego folderu): wynik jest wtedy częściowy i nie wolno go zapisać jako pełnego.
    public static func measureTree(_ root: String, clones: CloneInfoProvider = NoCloneInfo(), deadline: Date? = nil,
                                   trackKinds: Bool = false, sparseSeen: Bool = false, seen: inout Set<FileID>,
                                   shared: HardLinkRegistry? = nil, shouldStop: (() -> Bool)? = nil) -> Tree {
        var tree = Tree()
        guard let st = FileStat.of(root) else { tree.total.unreadable = 1; return tree }
        if st.isSymlink { return tree }
        if !st.isDirectory {
            tree.total.add(st, path: root, clones: clones, trackKinds: trackKinds, seen: &seen, sparseSeen: sparseSeen, shared: shared)
            return tree
        }
        guard canList(root) else { tree.total.noteUnreadable(root); return tree }
        #if canImport(Darwin)
        if useBulkWalker, let fast = measureTreeBulk(root, clones: clones, deadline: deadline, trackKinds: trackKinds, sparseSeen: sparseSeen, seen: &seen,
                                                     shared: shared, shouldStop: shouldStop) { return fast }
        #endif
        return measureTreeLegacy(root, clones: clones, deadline: deadline, trackKinds: trackKinds, sparseSeen: sparseSeen, seen: &seen, shared: shared, shouldStop: shouldStop)
    }

    static func measureTreeLegacy(_ root: String, clones: CloneInfoProvider = NoCloneInfo(), deadline: Date? = nil,
                                  trackKinds: Bool = false, sparseSeen: Bool = false, seen: inout Set<FileID>,
                                  shared: HardLinkRegistry? = nil, shouldStop: (() -> Bool)? = nil) -> Tree {
        var tree = Tree()
        guard canList(root), let e = FileManager.default.enumerator(atPath: root) else { tree.total.noteUnreadable(root); return tree }
        var buckets: [String: DiskUsage] = [:]
        var meta: [String: (isDirectory: Bool, modified: Date)] = [:]
        var own: (allocated: UInt64, reclaimable: UInt64) = (0, 0)
        forEachEntry(of: e) { rel in
            if let d = deadline, Date() > d { return false }
            if shouldStop?() == true { return false }
            let key = rel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? rel
            let p = root + "/" + rel
            guard let s = FileStat.of(p) else { buckets[key, default: DiskUsage()].noteUnreadable(p); return true }
            if rel == key { meta[key] = (s.isDirectory && !s.isSymlink, s.modified) }
            if s.isSymlink { if s.isDirectory { e.skipDescendants() }; return true }
            if s.isRegular { buckets[key, default: DiskUsage()].add(s, path: p, clones: clones, trackKinds: trackKinds, seen: &seen, sparseSeen: sparseSeen, shared: shared) }
            else if s.isDirectory {
                if rel == key { own.allocated += s.allocatedSize; own.reclaimable += s.allocatedSize; _ = buckets[key, default: DiskUsage()] }   // wpis katalogu dziecka: do sumy korzenia, nie do dziecka
                else { buckets[key, default: DiskUsage()].allocated += s.allocatedSize; buckets[key, default: DiskUsage()].reclaimable += s.allocatedSize }
                if !canList(p) { buckets[key, default: DiskUsage()].noteUnreadable(p); e.skipDescendants() }
            }
            return true
        }
        for (key, var u) in buckets {
            u.classifier = FileKindClassifier()                      // bufor folderów nie ma opuszczać pomiaru
            tree.total.merge(u)
            tree.children[key] = Tree.Child(usage: u, isDirectory: meta[key]?.isDirectory ?? false, modified: meta[key]?.modified ?? Date(timeIntervalSince1970: 0))
        }
        tree.total.allocated += own.allocated; tree.total.reclaimable += own.reclaimable
        return tree
    }

    /// Dodaje sumy innego pomiaru (liczniki, bajty wg rodzaju).
    public mutating func merge(_ o: DiskUsage) {
        allocated += o.allocated; reclaimable += o.reclaimable; fileCount += o.fileCount; hardLinkedFiles += o.hardLinkedFiles; unreadable += o.unreadable
        unreadablePaths.append(contentsOf: o.unreadablePaths.prefix(max(0, Self.maxUnreadablePaths - unreadablePaths.count)))
        for (k, v) in o.bytesByKind { bytesByKind[k, default: 0] += v }
    }

    /// `sparseSeen`: do `seen` trafiają tylko pliki z `nlink > 1` (AUD-PERF-3) – plik z jednym dowiązaniem nie może wystąpić drugi raz w jednym przejściu po drzewie,
    /// więc nie ma po co trzymać milionów identyfikatorów. Tylko dla pomiarów z WŁASNYM zbiorem `seen` i bez nakładających się korzeni (mapa dysku);
    /// współdzielony zbiór dla kilku, być może nakładających się katalogów (skaner porządków) wymaga pełnej deduplikacji.
    #if canImport(Darwin)
    /// Szybka ścieżka `measure` (getattrlistbulk + openat). nil = nie da się jej użyć – wywołujący liczy starą ścieżką (zbiór `seen` nietknięty).
    static func measureBulk(_ root: String, clones: CloneInfoProvider, deadline: Date?, trackKinds: Bool, seen: inout Set<FileID>) -> DiskUsage? {
        var u = DiskUsage()
        var local = seen
        let ok = BulkWalker.walk(root: root, shouldStop: { deadline.map { Date() > $0 } ?? false }) { event in
            switch event {
            case .file(let dir, _, let f):
                u.addEntry(f, dir: dir, clones: clones, trackKinds: trackKinds, seen: &local, sparseSeen: false)
            case .directory(_, _, _, let allocated, _):
                u.allocated += allocated; u.reclaimable += allocated
            case .unreadable(let path, _):
                u.noteUnreadable(path)
            }
        }
        guard ok else { return nil }
        seen = local
        u.classifier = FileKindClassifier()
        return u
    }

    /// Szybka ścieżka `measureTree`: te same reguły co stara (wpis katalogu dziecka liczy się do korzenia, pliki i podkatalogi – do swojego dziecka pierwszego poziomu).
    static func measureTreeBulk(_ root: String, clones: CloneInfoProvider, deadline: Date?, trackKinds: Bool, sparseSeen: Bool, seen: inout Set<FileID>,
                                shared: HardLinkRegistry? = nil, shouldStop: (() -> Bool)? = nil) -> Tree? {
        var buckets: [String: DiskUsage] = [:]
        var meta: [String: (isDirectory: Bool, modified: Date)] = [:]
        var own: UInt64 = 0
        var local = seen
        let rootPrefix = root + "/"
        let ok = BulkWalker.walk(root: root, shouldStop: { (deadline.map { Date() > $0 } ?? false) || (shouldStop?() ?? false) }) { event in
            switch event {
            case .file(let dir, let topKey, let f):
                let key = topKey ?? f.name
                if topKey == nil { meta[key] = (false, f.modified) }
                buckets[key, default: DiskUsage()].addEntry(f, dir: dir, clones: clones, trackKinds: trackKinds, seen: &local, sparseSeen: sparseSeen, shared: shared)
            case .directory(let path, let topKey, let name, let allocated, let modified):
                let key = topKey ?? name
                if path.count == rootPrefix.count + name.count, path.hasPrefix(rootPrefix) {        // dziecko pierwszego poziomu
                    meta[key] = (true, modified); own += allocated; _ = buckets[key, default: DiskUsage()]
                } else {
                    buckets[key, default: DiskUsage()].allocated += allocated; buckets[key, default: DiskUsage()].reclaimable += allocated
                }
            case .unreadable(let path, let topKey):
                let key = topKey ?? (path as NSString).lastPathComponent
                buckets[key, default: DiskUsage()].noteUnreadable(path)
            }
        }
        guard ok else { shared?.release(local.subtracting(seen)); return nil }      // przydziały przerwanego przejścia wracają do puli – stara ścieżka policzy je od nowa
        seen = local
        var tree = Tree()
        for (key, var u) in buckets {
            u.classifier = FileKindClassifier()
            tree.total.merge(u)
            tree.children[key] = Tree.Child(usage: u, isDirectory: meta[key]?.isDirectory ?? false, modified: meta[key]?.modified ?? Date(timeIntervalSince1970: 0))
        }
        tree.total.allocated += own; tree.total.reclaimable += own
        return tree
    }

    /// Jak `add`, ale bez sklejania ścieżki, gdy nie jest potrzebna (rodzaj pliku liczony z katalogu i nazwy; ścieżka tylko dla dostawcy klonów).
    mutating func addEntry(_ f: BulkWalker.File, dir: String, clones: CloneInfoProvider, trackKinds: Bool, seen: inout Set<FileID>, sparseSeen: Bool,
                                   shared: HardLinkRegistry? = nil) {
        if f.linkCount > 1, let shared {
            let id = FileID(device: f.device, inode: f.inode)
            guard !seen.contains(id), shared.claim(id) else { return }      // `seen` = tylko pliki przydzielone TEMU pomiarowi (do ewentualnego zwrotu)
            seen.insert(id)
        } else if !sparseSeen || f.linkCount > 1 { guard seen.insert(FileID(device: f.device, inode: f.inode)).inserted else { return } }
        fileCount += 1
        allocated += f.allocatedSize
        if trackKinds { bytesByKind[classifier.kind(directory: dir, name: f.name), default: 0] += f.allocatedSize }
        if f.linkCount > 1 { hardLinkedFiles += 1; return }
        if !(clones is NoCloneInfo), let priv = clones.privateSize(path: dir + "/" + f.name) { reclaimable += min(priv, f.allocatedSize) }
        else { reclaimable += f.allocatedSize }
    }
    #endif

    private mutating func add(_ s: FileStat, path: String, clones: CloneInfoProvider, trackKinds: Bool, seen: inout Set<FileID>, sparseSeen: Bool = false,
                              shared: HardLinkRegistry? = nil) {
        if s.linkCount > 1, let shared {
            guard !seen.contains(s.fileID), shared.claim(s.fileID) else { return }
            seen.insert(s.fileID)
        } else if !sparseSeen || s.linkCount > 1 { guard seen.insert(s.fileID).inserted else { return } }
        fileCount += 1
        allocated += s.allocatedSize
        if trackKinds { bytesByKind[classifier.kind(of: path), default: 0] += s.allocatedSize }
        if s.linkCount > 1 { hardLinkedFiles += 1; return }    // inne dowiązanie zachowa dane
        if let priv = clones.privateSize(path: path) { reclaimable += min(priv, s.allocatedSize) }
        else { reclaimable += s.allocatedSize }
    }
}

public enum PathTools {
    public static var home: String { NSHomeDirectory() }

    /// Rozwija „~”, standaryzuje i rozwiązuje dowiązania symboliczne.
    public static func canonical(_ path: String, home: String = PathTools.home) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        let url = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath()
        var s = url.path
        // macOS: /private/var ≡ /var, /private/tmp ≡ /tmp
        if s.hasPrefix("/private/var/") || s.hasPrefix("/private/tmp") { s = String(s.dropFirst("/private".count)) }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Jak `canonical`, ale rozwiązuje dowiązania w najdłuższym ISTNIEJĄCYM prefiksie także wtedy, gdy ogon ścieżki nie istnieje. Zwykłe
    /// `resolvingSymlinksInPath` zostawia wtedy całą ścieżkę nietkniętą, więc dowiązanie w środku (np. `~/x → ~/.ssh`, ścieżka `~/x/nowy/plik`) nie byłoby rozpoznane –
    /// a miejsce przywracania z kwarantanny z definicji jeszcze nie istnieje. Dowiązanie (także zerwane) liczy się jako istniejące (`lstat`).
    public static func canonicalLenient(_ path: String, home: String = PathTools.home) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        guard p.hasPrefix("/") else { return canonical(p, home: home) }
        var url = URL(fileURLWithPath: p).standardizedFileURL
        var tail: [String] = []
        while url.path != "/", FileStat.of(url.path) == nil {
            tail.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        let base = canonical(url.path, home: home)
        return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.joined(separator: "/")
    }

    /// Czy `path` leży w `root` (lub jest nim). Porównanie po komponentach – „/a/bc” nie leży w „/a/b”.
    public static func isWithin(_ path: String, _ root: String) -> Bool {
        if path == root { return true }
        let r = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(r)
    }
}
