#if canImport(Darwin)
import Foundation
import Darwin

/// Szybkie przejście po drzewie katalogów (technika z Radixa, MIT – odtworzona, nie skopiowana): `getattrlistbulk(2)` zwraca w jednym wywołaniu jądra
/// porcję wpisów katalogu razem z typem, rozmiarem, liczbą dowiązań, inode i datą zmiany – bez osobnego `lstat` dla każdego pliku. Podkatalogi otwierane są
/// względem deskryptora rodzica (`openat` z `O_NOFOLLOW`), więc jądro nie rozwiązuje za każdym razem całej ścieżki, a dowiązanie podstawione w miejsce
/// katalogu nie zostanie wybrane. Tylko odczyt.
///
/// Gdy system plików nie obsługuje tego API (`EINVAL`/`ENOTSUP`/`ENOSYS`) albo zabraknie deskryptorów, `walk` zwraca `false`, a wywołujący wraca do starej ścieżki
/// (`FileManager.enumerator` + `lstat`), dającej te same wyniki.
enum BulkWalker {
    struct File {
        var name: String
        var device: UInt64
        var inode: UInt64
        var linkCount: UInt64
        var logicalSize: UInt64
        var allocatedSize: UInt64
        var modified: Date
    }

    enum Event {
        /// Zwykły plik w katalogu `dir`; `topKey` = nazwa elementu pierwszego poziomu pod korzeniem (nil – plik leży bezpośrednio w korzeniu).
        case file(dir: String, topKey: String?, File)
        /// Podkatalog (już otwarty): jego własna zajętość (`fstat`) i data zmiany.
        case directory(path: String, topKey: String?, name: String, allocated: UInt64, modified: Date)
        /// Wpis albo katalog bez dostępu (uprawnienia POSIX lub odmowa TCC).
        case unreadable(path: String, topKey: String?)
    }

    static let bufferSize = 64 * 1024
    private static let unsupportedErrors: Set<Int32> = [EINVAL, ENOTSUP, ENOSYS]

    private static var attributes: attrlist {
        var a = attrlist()
        a.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        a.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return a
    }

    /// Przechodzi drzewo pod `root`. Zwraca `false`, gdy szybkiej ścieżki nie da się użyć (wtedy żadne zdarzenie nie powinno być brane pod uwagę –
    /// wywołujący liczy od nowa starą metodą). `shouldStop` sprawdzane co 256 wpisów i przed każdym podkatalogiem (limit czasu, anulowanie).
    static func walk(root: String, shouldStop: () -> Bool, _ visit: (Event) -> Void) -> Bool {
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var stopped = false
        return walkDirectory(fd: fd, path: root, topKey: nil, buffer: buffer, stopped: &stopped, shouldStop: shouldStop, visit)
    }

    enum ListStatus { case ok, stopped, unsupported }

    /// Listuje JEDEN katalog (już otwarty `fd`): pliki i błędy wpisów idą do `visit`, podkatalogi wracają w wyniku (bez otwierania).
    /// Wspólne dla przejścia sekwencyjnego i równoległego (`ParallelTreeMeasure`) – te same reguły, te same zdarzenia.
    static func listDirectory(fd: Int32, path: String, topKey: String?, buffer: UnsafeMutableRawPointer, shouldStop: () -> Bool,
                              _ visit: (Event) -> Void) -> (status: ListStatus, subdirs: [(name: String, modified: Date)]) {
        var subdirs: [(name: String, modified: Date)] = []
        var attrs = attributes
        var seen = 0
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                let e = errno
                if unsupportedErrors.contains(e) { return (.unsupported, subdirs) }
                visit(.unreadable(path: path, topKey: topKey))                 // katalog otwarty, ale listowanie odmówione
                break
            }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            let bufferEnd = entry + bufferSize
            for _ in 0..<Int(count) {
                guard entry + 4 <= bufferEnd else { return (.unsupported, subdirs) }
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                guard length >= 4, entry + length <= bufferEnd, let parsed = parse(entry, end: entry + length) else { return (.unsupported, subdirs) }
                entry += length
                seen += 1
                if seen % 256 == 0, shouldStop() { return (.stopped, subdirs) }
                if parsed.error != 0 { visit(.unreadable(path: path + "/" + parsed.name, topKey: topKey ?? parsed.name)); continue }
                switch parsed.type {
                case VREG.rawValue:
                    visit(.file(dir: path, topKey: topKey, File(name: parsed.name, device: parsed.device, inode: parsed.inode, linkCount: parsed.linkCount,
                                                              logicalSize: parsed.logicalSize, allocatedSize: parsed.allocatedSize, modified: parsed.modified)))
                case VDIR.rawValue:
                    subdirs.append((parsed.name, parsed.modified))
                default:
                    break                                                          // dowiązania symboliczne i pliki specjalne – jak w starej ścieżce: pomijane
                }
            }
        }
        return (.ok, subdirs)
    }

    /// Otwiera podkatalog względem rodzica (`openat`, `O_NOFOLLOW`). nil + `outOfDescriptors` – zabrakło deskryptorów (wywołujący wraca do starej ścieżki).
    static func openChild(_ parent: Int32, _ name: String) -> (fd: Int32?, outOfDescriptors: Bool) {
        let cfd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if cfd >= 0 { return (cfd, false) }
        let e = errno
        return (nil, e == EMFILE || e == ENFILE)
    }

    /// Zajętość samego wpisu katalogu (`fstat`).
    static func ownAllocated(_ fd: Int32) -> UInt64 { var st = stat(); return fstat(fd, &st) == 0 ? UInt64(max(0, st.st_blocks)) * 512 : 0 }

    private static func walkDirectory(fd: Int32, path: String, topKey: String?, buffer: UnsafeMutableRawPointer, stopped: inout Bool,
                                      shouldStop: () -> Bool, _ visit: (Event) -> Void) -> Bool {
        if stopped { return true }
        let listing = listDirectory(fd: fd, path: path, topKey: topKey, buffer: buffer, shouldStop: shouldStop, visit)
        switch listing.status {
        case .unsupported: return false
        case .stopped: stopped = true; return true
        case .ok: break
        }
        for sub in listing.subdirs {
            if stopped || shouldStop() { stopped = true; return true }
            let childPath = path + "/" + sub.name
            let key = topKey ?? sub.name
            let opened = openChild(fd, sub.name)
            guard let cfd = opened.fd else {
                if opened.outOfDescriptors { return false }                        // brak deskryptorów – wracamy do starej ścieżki
                visit(.directory(path: childPath, topKey: key, name: sub.name, allocated: 0, modified: sub.modified))
                visit(.unreadable(path: childPath, topKey: key))
                continue
            }
            visit(.directory(path: childPath, topKey: key, name: sub.name, allocated: ownAllocated(cfd), modified: sub.modified))
            let ok = walkDirectory(fd: cfd, path: childPath, topKey: key, buffer: buffer, stopped: &stopped, shouldStop: shouldStop, visit)
            close(cfd)
            if !ok { return false }
        }
        return true
    }

    private struct Parsed {
        var name: String
        var error: UInt32
        var type: UInt32
        var device: UInt64
        var inode: UInt64
        var linkCount: UInt64
        var logicalSize: UInt64
        var allocatedSize: UInt64
        var modified: Date
    }

    /// Układ wpisu (z `FSOPT_PACK_INVAL_ATTRS` stały): długość, `attribute_set_t` (zawsze pierwszy), błąd (w trybie bulk zaraz po nim), potem atrybuty wspólne
    /// w kolejności bitów (nazwa, urządzenie, typ, data zmiany, inode), potem – gdy obecne – atrybuty pliku (liczba dowiązań, rozmiar logiczny, zajęty).
    private static func parse(_ start: UnsafeRawPointer, end: UnsafeRawPointer) -> Parsed? {
        var c = start + 4
        func read<T>(_: T.Type) -> T? {
            guard c + MemoryLayout<T>.size <= end else { return nil }
            let v = c.loadUnaligned(as: T.self)
            c += MemoryLayout<T>.size
            return v
        }
        guard let returned = read(attribute_set_t.self), let error = read(UInt32.self) else { return nil }
        let nameRefAddress = c
        guard let nameRef = read(attrreference_t.self) else { return nil }
        let nameStart = nameRefAddress + Int(nameRef.attr_dataoffset)
        let nameLength = Int(nameRef.attr_length)
        guard nameLength >= 1, nameStart >= start, nameStart + nameLength <= end else { return nil }
        let bytes = UnsafeBufferPointer(start: nameStart.assumingMemoryBound(to: UInt8.self), count: nameLength - 1)   // bez kończącego NUL
        let name = String(decoding: bytes, as: UTF8.self)
        guard let device = read(dev_t.self), let type = read(fsobj_type_t.self), let mtime = read(timespec.self), let inode = read(UInt64.self) else { return nil }
        var links: UInt32 = 1, logical: off_t = 0, allocated: off_t = 0
        if type == VREG.rawValue || returned.fileattr != 0 {
            guard let l = read(UInt32.self), let t = read(off_t.self), let a = read(off_t.self) else { return nil }
            links = l; logical = t; allocated = a
        }
        return Parsed(name: name, error: error, type: type, device: UInt64(truncatingIfNeeded: device), inode: inode, linkCount: UInt64(max(1, links)),
                      logicalSize: UInt64(max(0, logical)), allocatedSize: UInt64(max(0, allocated)),
                      modified: Date(timeIntervalSince1970: Double(mtime.tv_sec) + Double(mtime.tv_nsec) / 1e9))
    }
}
#endif
