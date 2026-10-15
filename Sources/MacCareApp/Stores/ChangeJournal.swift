import Foundation
import CoreServices
import MacCareCore

/// F8: punkt kontrolny dziennika zmian systemu plików (FSEvents) – numer ostatniego zdarzenia i identyfikator magazynu zdarzeń wolumenu.
struct ChangeCheckpoint: Codable, Equatable, Sendable {
    var eventID: UInt64
    var storeUUID: String
}

/// F8 (Radix): dziennik zmian systemu plików – TYLKO ODCZYT historii zdarzeń FSEvents (bez nasłuchu w tle, bez zapisu).
/// Pozwala po ponownym uruchomieniu przeliczyć wyłącznie foldery zmienione od ostatniego pomiaru. Gdy historia jest niedostępna albo niepewna,
/// wywołujący wraca do dotychczasowych reguł (data zmiany katalogu, wiek wyniku).
enum ChangeJournal {
    static func checkpoint(for path: String) -> ChangeCheckpoint? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return ChangeCheckpoint(eventID: FSEventsGetCurrentEventId(), storeUUID: CFUUIDCreateString(nil, uuid) as String)
    }

    struct Changes: Sendable {
        var paths: [String]
        /// Historia niepewna (przepełnienie, inny magazyn zdarzeń, zawinięcie numerów) – trzeba policzyć wszystko.
        var mustRescan: Bool
    }

    /// Katalogi pod `root` zmienione od `since`. nil = historia niedostępna (brak odpowiedzi w `timeout`) – wywołujący stosuje stare reguły.
    static let graceAfterHistory: TimeInterval = 0.15

    static func changes(under root: String, since: ChangeCheckpoint, timeout: TimeInterval = 3, maxPaths: Int = 50_000) -> Changes? {
        guard let now = checkpoint(for: root) else { return nil }
        if now.storeUUID != since.storeUUID || now.eventID < since.eventID { return Changes(paths: [], mustRescan: true) }
        // Bez skrótu „ten sam numer zdarzenia ⇒ brak zmian”: zdarzenie świeżej zmiany może jeszcze czekać w kolejce jądra bez numeru –
        // wypycha je dopiero `FSEventStreamFlushSync` (test `onlyTheChangedChildIsRemeasured` złapał przeoczoną zmianę).
        let box = Box(maxPaths: maxPaths)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let b = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            b.lock.lock(); defer { b.lock.unlock() }
            for i in 0..<count {
                if flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { b.done = true; continue }
                if flags[i] & Box.rescanFlags != 0 { b.mustRescan = true }
                if b.paths.count < b.maxPaths, let p = list[i] as? String { b.paths.append(p) } else { b.mustRescan = true }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, FSEventStreamEventId(since.eventID), 0.05, flags) else { return nil }
        let queue = DispatchQueue(label: "io.github.u7464145221-max.maccare.changejournal", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        FSEventStreamFlushSync(stream)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            box.lock.lock(); let done = box.done; box.lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Jądro przekazuje zdarzenia do fseventsd asynchronicznie: zmiana sprzed kilku ms może dotrzeć już po historii. Krótka karencja i ponowne
        // wypchnięcie zmniejszają to okno; zdarzenie spóźnione mimo to dostaje numer PÓŹNIEJSZY niż punkt kontrolny wzięty przed zapytaniem,
        // więc wykryje je następne sprawdzenie – zmiana nie ginie, najwyżej przychodzi o jedno sprawdzenie później.
        Thread.sleep(forTimeInterval: graceAfterHistory)
        FSEventStreamFlushSync(stream)
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        queue.sync {}                                                                  // ostatnie wywołania zwrotne zakończone
        box.lock.lock(); defer { box.lock.unlock() }
        return box.done ? Changes(paths: box.paths, mustRescan: box.mustRescan) : nil
    }

    /// Stan zbierany przez wywołanie zwrotne (funkcja C – bez przechwytywania zmiennych, dostęp przez wskaźnik `info`).
    final class Box: @unchecked Sendable {
        static let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                                        | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        let lock = NSLock(); let maxPaths: Int
        var paths: [String] = []; var mustRescan = false; var done = false
        init(maxPaths: Int) { self.maxPaths = maxPaths }
    }
}
