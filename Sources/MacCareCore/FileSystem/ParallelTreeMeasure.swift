#if canImport(Darwin)
import Foundation
import Darwin

/// F7 (Radix): pomiar podfolderów jednego folderu z JEDNĄ pulą wątków dla całego folderu. Jednostką pracy jest katalog, nie całe dziecko,
/// więc duży podfolder (np. `Library`) liczy kilka wątków naraz zamiast jednego do końca. Wynik każdego dziecka = `DiskUsage.measureTree(dziecko)`
/// (te same zdarzenia z `BulkWalker.listDirectory`, te same reguły sumowania; test zgodności `ParallelTreeMeasureTests`). Tylko odczyt.
///
/// Bezpieczeństwo i zasoby: podkatalogi otwierane względem deskryptora rodzica (`openat` + `O_NOFOLLOW`); rodzic zostaje otwarty, dopóki czekają jego
/// podkatalogi (uchwyt z licznikiem referencji). Najpierw startują dzieci (małe kończą się od razu – wiersze mapy wypełniają się szybko), ale naraz
/// rozpoczętych jest najwyżej `maxActiveChildren`; potem pula schodzi w głąb (LIFO), więc otwartych deskryptorów jest mniej więcej tyle, ile wynosi
/// głębokość drzewa plus liczba wątków. Gdy zabraknie deskryptorów albo system plików nie obsługuje `getattrlistbulk`, to dziecko liczy się od nowa
/// starą, sekwencyjną ścieżką (po zwrocie przydziałów dowiązań).
public enum ParallelTreeMeasure {
    public struct Outcome: Sendable {
        public var name: String
        public var tree: DiskUsage.Tree
        /// Pomiar przerwany (`shouldStop`) – wynik częściowy, nie do zapisania jako pełny.
        public var stopped: Bool
        /// Policzone starą ścieżką (szybka niedostępna dla tego dziecka).
        public var usedFallback: Bool
    }

    static let maxActiveChildren = 64

    final class DirHandle: @unchecked Sendable {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { close(fd) }
    }

    /// Stan jednego dziecka; zmieniany tylko pod `lock` (raz na katalog, nie na plik).
    final class Job: @unchecked Sendable {
        let name: String, root: String
        let lock = NSLock()
        var buckets: [String: DiskUsage] = [:]
        var meta: [String: (isDirectory: Bool, modified: Date)] = [:]
        var own: UInt64 = 0
        var claimed = Set<FileID>()
        var pending = 1
        var failed = false
        /// Audyt 2 (4.2): klony APFS – Porządki liczą miejsce do odzyskania (mapa: bez klonów, jak dotąd).
        let clones: CloneInfoProvider
        init(name: String, root: String, clones: CloneInfoProvider = NoCloneInfo()) { self.name = name; self.root = root; self.clones = clones }

        /// Te same reguły co `DiskUsage.measureTreeBulk` (wpis katalogu dziecka pierwszego poziomu – do sumy korzenia, reszta – do swojego wiadra).
        func apply(_ ev: BulkWalker.Event, registry: HardLinkRegistry, trackKinds: Bool) {
            switch ev {
            case .file(let dir, let topKey, let f):
                let key = topKey ?? f.name
                if topKey == nil { meta[key] = (false, f.modified) }
                buckets[key, default: DiskUsage()].addEntry(f, dir: dir, clones: clones, trackKinds: trackKinds, seen: &claimed, sparseSeen: true, shared: registry)
            case .directory(let path, let topKey, let name, let allocated, let modified):
                let key = topKey ?? name
                if path == root + "/" + name {
                    meta[key] = (true, modified); own += allocated; _ = buckets[key, default: DiskUsage()]
                } else {
                    buckets[key, default: DiskUsage()].allocated += allocated; buckets[key, default: DiskUsage()].reclaimable += allocated
                }
            case .unreadable(let path, let topKey):
                let key = topKey ?? (path as NSString).lastPathComponent
                buckets[key, default: DiskUsage()].noteUnreadable(path)
            }
        }

        func tree() -> DiskUsage.Tree {
            var tree = DiskUsage.Tree()
            for (key, var u) in buckets {
                u.classifier = FileKindClassifier()
                tree.total.merge(u)
                tree.children[key] = DiskUsage.Tree.Child(usage: u, isDirectory: meta[key]?.isDirectory ?? false, modified: meta[key]?.modified ?? Date(timeIntervalSince1970: 0))
            }
            tree.total.allocated += own; tree.total.reclaimable += own
            return tree
        }
    }

    struct Item {
        let job: Job
        let parent: DirHandle
        let name: String
        let path: String
        let key: String?
        let modified: Date
        var isRoot: Bool { key == nil }
    }

    /// Kolejka pracy: korzenie dzieci (FIFO, z limitem rozpoczętych) i katalogi w głębi (LIFO).
    final class Pool: @unchecked Sendable {
        let cond = NSCondition()
        var roots: [Item] = []
        var rootIndex = 0
        var deep: [Item] = []
        var busy = 0
        var activeJobs = 0
        var stopped = false

        func next() -> Item? {
            cond.lock(); defer { cond.unlock() }
            while true {
                let rootsLeft = rootIndex < roots.count
                if !stopped, rootsLeft, activeJobs < ParallelTreeMeasure.maxActiveChildren || deep.isEmpty {
                    let it = roots[rootIndex]; rootIndex += 1; activeJobs += 1; busy += 1
                    return it
                }
                if let it = deep.popLast() { busy += 1; return it }
                if stopped, rootsLeft { let it = roots[rootIndex]; rootIndex += 1; activeJobs += 1; busy += 1; return it }   // dokończ (bez pracy)
                if busy == 0 && !rootsLeft { cond.broadcast(); return nil }
                cond.wait()
            }
        }

        func done(adding items: [Item], jobFinished: Bool) {
            cond.lock()
            deep.append(contentsOf: items.reversed())
            busy -= 1
            if jobFinished { activeJobs -= 1 }
            cond.broadcast()
            cond.unlock()
        }

        func stop() { cond.lock(); stopped = true; cond.broadcast(); cond.unlock() }
        var isStopped: Bool { cond.lock(); defer { cond.unlock() }; return stopped }
    }

    /// Mierzy katalogi `names` w folderze `dir` (wywołujący wcześniej odsiewa pliki, dowiązania i katalogi bez dostępu). Blokuje do końca;
    /// `onChild` – z wątku puli, dokładnie raz na każde dziecko. `limit` wątków (zwykle `ScanConcurrency.limit()`).
    public static func measureDirectories(in dir: String, names: [String], limit: Int, registry: HardLinkRegistry, trackKinds: Bool = true,
                                          clones: CloneInfoProvider = NoCloneInfo(),
                                          shouldStop: @escaping @Sendable () -> Bool = { false }, gauge: ParallelGauge? = nil,
                                          onChild: @escaping @Sendable (Outcome) -> Void) {
        let jobs = names.map { Job(name: $0, root: dir + "/" + $0, clones: clones) }
        let rootFD = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard DiskUsage.useBulkWalker, rootFD >= 0 else {
            if rootFD >= 0 { close(rootFD) }
            for job in jobs { onChild(fallback(job, registry: registry, trackKinds: trackKinds, shouldStop: shouldStop)) }
            return
        }
        let rootHandle = DirHandle(rootFD)
        let pool = Pool()
        pool.roots = jobs.map { Item(job: $0, parent: rootHandle, name: $0.name, path: $0.root, key: nil, modified: Date(timeIntervalSince1970: 0)) }
        DispatchQueue.concurrentPerform(iterations: max(1, limit)) { _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: BulkWalker.bufferSize, alignment: 16)
            defer { buffer.deallocate() }
            while let item = pool.next() {
                gauge?.enter()
                let children = process(item, buffer: buffer, pool: pool, registry: registry, trackKinds: trackKinds, shouldStop: shouldStop)
                gauge?.leave()
                let job = item.job
                job.lock.lock()
                job.pending += children.count - 1
                let finished = job.pending == 0
                job.lock.unlock()
                pool.done(adding: children, jobFinished: finished)
                if finished { onChild(finish(job, stopped: pool.isStopped, registry: registry, trackKinds: trackKinds, shouldStop: shouldStop)) }
            }
        }
    }

    /// Jeden katalog: otwarcie, zdarzenia, podkatalogi do kolejki. Zwraca nowe pozycje pracy (puste, gdy dziecko porzucone albo skan przerwany).
    static func process(_ item: Item, buffer: UnsafeMutableRawPointer, pool: Pool, registry: HardLinkRegistry, trackKinds: Bool,
                        shouldStop: () -> Bool) -> [Item] {
        let job = item.job
        job.lock.lock(); let abandoned = job.failed; job.lock.unlock()
        if abandoned || pool.isStopped { return [] }
        if shouldStop() { pool.stop(); return [] }
        var events: [BulkWalker.Event] = []
        let opened = BulkWalker.openChild(item.parent.fd, item.name)
        guard let cfd = opened.fd else {
            if opened.outOfDescriptors || item.isRoot { markFailed(job); return [] }   // korzeń nie do otwarcia (zmiana w trakcie) – stara ścieżka rozstrzygnie
            events.append(.directory(path: item.path, topKey: item.key, name: item.name, allocated: 0, modified: item.modified))
            events.append(.unreadable(path: item.path, topKey: item.key))
            apply(events, to: job, registry: registry, trackKinds: trackKinds)
            return []
        }
        let handle = DirHandle(cfd)
        if !item.isRoot {
            events.append(.directory(path: item.path, topKey: item.key, name: item.name, allocated: BulkWalker.ownAllocated(cfd), modified: item.modified))
        }
        let listing = BulkWalker.listDirectory(fd: cfd, path: item.path, topKey: item.key, buffer: buffer, shouldStop: shouldStop) { events.append($0) }
        switch listing.status {
        case .unsupported: markFailed(job); return []
        case .stopped: pool.stop()
        case .ok: break
        }
        apply(events, to: job, registry: registry, trackKinds: trackKinds)
        if listing.status == .stopped { return [] }
        return listing.subdirs.map { sub in
            Item(job: job, parent: handle, name: sub.name, path: item.path + "/" + sub.name, key: item.key ?? sub.name, modified: sub.modified)
        }
    }

    static func apply(_ events: [BulkWalker.Event], to job: Job, registry: HardLinkRegistry, trackKinds: Bool) {
        job.lock.lock(); defer { job.lock.unlock() }
        guard !job.failed else { return }
        for ev in events { job.apply(ev, registry: registry, trackKinds: trackKinds) }
    }

    static func markFailed(_ job: Job) { job.lock.lock(); job.failed = true; job.lock.unlock() }

    static func finish(_ job: Job, stopped: Bool, registry: HardLinkRegistry, trackKinds: Bool, shouldStop: @escaping () -> Bool) -> Outcome {
        job.lock.lock(); let failed = job.failed; job.lock.unlock()
        if failed && !stopped {
            registry.release(job.claimed)                                           // przydziały porzuconego przejścia wracają – stara ścieżka policzy je od nowa
            return fallback(job, registry: registry, trackKinds: trackKinds, shouldStop: shouldStop)
        }
        return Outcome(name: job.name, tree: job.tree(), stopped: stopped, usedFallback: false)
    }

    static func fallback(_ job: Job, registry: HardLinkRegistry, trackKinds: Bool, shouldStop: @escaping () -> Bool) -> Outcome {
        var seen = Set<FileID>()
        let t = DiskUsage.measureTreeLegacy(job.root, clones: job.clones, trackKinds: trackKinds, sparseSeen: true, seen: &seen, shared: registry, shouldStop: shouldStop)
        return Outcome(name: job.name, tree: t, stopped: shouldStop(), usedFallback: true)
    }
}
#endif
