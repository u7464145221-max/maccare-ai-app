import SwiftUI
import AppKit
import MacCareCore
import MacCareSystem

struct MapNode: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let size: UInt64          // zajęte bloki (twarde dowiązania liczone raz)
    let isDirectory: Bool
    let items: Int
    /// Kolor/legenda: rodzaj pliku albo dominujący rodzaj zawartości folderu (wg zajętości).
    let category: MapCategory
    /// Rozkład zawartości według kategorii (od największej) – do podpowiedzi na wykresie.
    let breakdown: [CategoryShare]
}

struct CategoryShare: Hashable { let category: MapCategory; let bytes: UInt64 }

extension MapNode {
    /// Kopia z rozmiarem zmniejszonym o `bytes` (korekta pamięci wyników po przeniesieniu elementu z wnętrza folderu do Kosza).
    func reduced(by bytes: UInt64) -> MapNode {
        MapNode(path: path, name: name, size: size > bytes ? size - bytes : 0, isDirectory: isDirectory, items: items, category: category, breakdown: breakdown)
    }
}

/// Wiersz listy mapy: w trakcie skanu kolejność jest STAŁA (alfabetyczna), rozmiary dopisują się w miarę liczenia (`node == nil` = jeszcze liczony).
struct ScanRow: Identifiable, Equatable {
    let id: String            // ścieżka – ten sam identyfikator co `MapNode.id`, więc zmiana kolejności po skanie jest animowanym przesunięciem, a nie przebudową listy
    let name: String
    var node: MapNode?
}

/// Postęp pierwszego pomiaru folderu.
struct ScanProgress: Equatable { var done: Int; var total: Int; var latest: String? }

/// Rozkład zajętości według kategorii mapy (ta sama kategoria z kilku rodzajów plików jest sumowana).
func categoryBreakdown(_ bytesByKind: [FileKind: UInt64]) -> [CategoryShare] {
    var by: [MapCategory: UInt64] = [:]
    for (k, b) in bytesByKind { by[MapCategory(kind: k), default: 0] += b }
    return by.map { CategoryShare(category: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
}

/// Ile największych podfolderów dostaje od razu zawartość z przejścia rodzica oraz ile wpisów może mieć taka zawartość (reszta jest liczona przy wejściu).
private let childListingsKept = 40, childListingMaxEntries = 300

/// Mapa dysku: zawartość jednego folderu naraz, rozmiary liczone strumieniowo (wyniki pojawiają się na bieżąco). Tylko odczyt.
///
/// **Pamięć wyników (W1):** każdy zmierzony folder trafia do pamięci podręcznej na czas sesji (ścieżka → węzły + czas pomiaru + `mtime` katalogu, limit LRU).
/// Wejście w podfolder i powrót pokazują wynik NATYCHMIAST (synchronicznie, bez czyszczenia widoku); ponowny pomiar tylko na żądanie („Odśwież”)
/// albo gdy `mtime` katalogu się zmienił (wtedy odświeżenie w tle, a widok zostaje). Jedno przejście po drzewie (`DiskUsage.measureTree`) daje od razu
/// zawartość podfolderów (dzieci następnego poziomu), więc wejście w głąb nie liczy tego samego poddrzewa drugi raz.
/// Zaznaczenia są globalne (po ścieżce) i przetrwają nawigację; suma zaznaczonych obejmuje wszystkie poziomy.
@MainActor
final class DiskMapStore: ObservableObject {
    @Published private(set) var path: [String]
    @Published private(set) var nodes: [MapNode] = []
    /// Pierwszy pomiar folderu (widok pusty, rozmiary dopływają).
    @Published private(set) var scanning = false
    /// Odświeżanie w tle: widoczny jest wynik z pamięci.
    @Published private(set) var refreshing = false
    @Published private(set) var lastMeasuredAt: Date?
    /// W2: w trakcie pierwszego skanu – wiersze w stałej kolejności z rozmiarami dopisywanymi na bieżąco; poza skanem pusta.
    @Published private(set) var scanRows: [ScanRow] = []
    @Published private(set) var progress: ScanProgress?
    @Published var selected: Set<String> = []
    @Published var highlighted: String?
    /// Zakładka „Duże pliki”: wynik zachowany przy przełączaniu zakładek i nawigacji.
    @Published private(set) var largeFiles: [FileEntry]?
    @Published private(set) var largeLoading = false
    /// P1-4: elementy bieżącego folderu, których nie da się odczytać (brak uprawnień / Pełnego dostępu do dysku) – nie ma ich na mapie, ale nie znikają bez śladu.
    @Published private(set) var inaccessible: [String] = []
    /// P1-4: ile nieczytelnych miejsc jest GŁĘBIEJ w zmierzonych elementach (ich rozmiary są wtedy zaniżone).
    @Published private(set) var unreadableInside = 0
    /// Wynik bieżącego folderu jest niepełny.
    var isIncomplete: Bool { !inaccessible.isEmpty || unreadableInside > 0 }
    /// Komunikat „skan niepełny” dla bieżącego folderu (nil = pełny wynik).
    var incompleteMessage: String? {
        guard isIncomplete else { return nil }
        var parts: [String] = []
        if !inaccessible.isEmpty {
            let names = inaccessible.prefix(3).map { name in String(localized: "„\((name as NSString).lastPathComponent)”") }.joined(separator: ", ")
            let count = Plural.counted(inaccessible.count, one: "elementu", few: "elementów", many: "elementów"), more = inaccessible.count > 3 ? "…" : ""
            parts.append(String(localized: "brak dostępu do \(count) (\(names)\(more)) – nie ma ich na mapie"))
        }
        if unreadableInside > 0 {
            let places = Plural.counted(unreadableInside, one: "miejsce", few: "miejsca", many: "miejsc")
            parts.append(String(localized: "\(places) wewnątrz folderów bez dostępu – ich rozmiary są zaniżone"))
        }
        let list = parts.joined(separator: "; ")
        return String(localized: "Skan niepełny: \(list).")
    }

    private var generation = 0
    /// Przerwanie bieżącego skanu, gdy zaczyna się następny (wątki pomiaru starego folderu kończą pracę zamiast liczyć do końca).
    private var currentCancel: ScanCancellation?
    /// Dowód w testach: najwięcej folderów mierzonych naraz (nie więcej niż `ScanConcurrency.limit()`).
    nonisolated let gauge = ParallelGauge()
    private(set) var rootPath: String
    /// Liczba pomiarów poddrzew w tej sesji (do testów: powrót do folderu z pamięci nie może jej zwiększać).
    private(set) var measureCount = 0

    // MARK: pamięć wyników
    private struct Listing {
        var nodes: [MapNode]; var measuredAt: Date; var dirMTime: Date; var inaccessible: [String] = []; var unreadableInside = 0
        /// F8: punkt kontrolny dziennika zmian z CHWILI ROZPOCZĘCIA pomiaru i liczniki „bez dostępu” per dziecko (do przeliczania części dzieci).
        var checkpoint: ChangeCheckpoint? = nil
        var unreadableByChild: [String: Int] = [:]
        /// F11: rozmiary dzieci z wcześniejszego pomiaru (punkt odniesienia porównania) i jego czas – starszy o co najmniej `comparisonMinAge`.
        var previousSizes: [String: UInt64] = [:]
        var previousAt: Date? = nil
    }
    private var cache: [String: Listing] = [:]
    private var lru: [String] = []                       // najdawniej użyty pierwszy
    private let maxListings: Int
    private let maxCachedNodes: Int
    private var selectedSizes: [String: UInt64] = [:]
    /// Odciski zaznaczonych elementów z CHWILI ZAZNACZENIA (lstat) – narzędzie „Przenieś do Kosza” sprawdza je ponownie tuż przed operacją (W5).
    private var selectedFingerprints: [String: String] = [:]
    /// Zaznaczone elementy rozpoznane jako pliki w chmurze (iCloud/File Provider) – steruje osobnym przełącznikiem „Także pliki w chmurze”.
    @Published private(set) var cloudSelected: Set<String> = []
    /// Rozpoznawanie plików w chmurze (domyślne; testy podstawiają własne).
    var isCloud: @Sendable (String) -> Bool = TrashSelectedTool.defaultCloudProbe(home: NSHomeDirectory())
    /// Ile największych podfolderów dostaje od razu zawartość z przejścia rodzica oraz ile wpisów może mieć taka zawartość (reszta jest liczona przy wejściu).

    /// F4: plik z pamięcią wyników (nil = bez zapisu, np. w części testów). `home` – do zamiany na „~” w pliku.
    private let persistenceURL: URL?
    private let home: String
    private var saveGeneration = 0
    /// Zegar (testy podstawiają własny – wiek wyniku).
    var now: () -> Date = { Date() }
    /// Wynik starszy niż ten wiek jest odświeżany w tle przy wejściu do folderu (nawet gdy `mtime` katalogu się nie zmienił – zmiany głębiej go nie dotykają).
    static let maxResultAge: TimeInterval = 24 * 3600
    /// F8: z dziennikiem zmian (FSEvents) wynik bez zgłoszonych zmian uznajemy za aktualny do 7 dni; potem i tak pełny pomiar (siatka bezpieczeństwa).
    static let maxTrustedAge: TimeInterval = 7 * 24 * 3600
    /// F11: punkt odniesienia porównania jest starszy od bieżącego pomiaru co najmniej o tyle – częste odświeżenia nie zerują widocznej zmiany.
    static let comparisonMinAge: TimeInterval = 3600
    /// F8: przeliczanie tylko folderów zmienionych od ostatniego pomiaru (testy mogą wyłączyć, by sprawdzić stare reguły).
    var changeJournalEnabled = true
    var changeJournalTimeout: TimeInterval = 3
    /// Diagnostyka i testy: decyzja z ostatniego sprawdzenia dziennika zmian oraz nazwy dzieci zmierzone w ostatnim pomiarze.
    private(set) var lastPlan: ChangePlanner.Plan?
    private(set) var lastMeasuredNames: [String] = []
    /// Ile folderów wczytano z pliku przy starcie (diagnostyka i testy).
    private(set) var loadedListingCount = 0

    init(root: String, maxListings: Int = 200, maxCachedNodes: Int = 20_000, persistenceURL: URL? = nil, home: String = NSHomeDirectory()) {
        rootPath = root; path = [root]; self.maxListings = maxListings; self.maxCachedNodes = maxCachedNodes
        self.persistenceURL = persistenceURL; self.home = home
        if let url = persistenceURL, let data = try? Data(contentsOf: url), let entries = DiskMapPersistence.decode(data, home: home) {   // try? świadomie: brak lub uszkodzona pamięć mapy ⇒ zwykły skan
            for e in entries.sorted(by: { $0.measuredAt < $1.measuredAt }).suffix(maxListings) {
                cache[e.dir] = Listing(nodes: e.nodes, measuredAt: e.measuredAt, dirMTime: e.dirMTime, inaccessible: e.inaccessible, unreadableInside: e.unreadableInside,
                                       checkpoint: e.checkpoint, unreadableByChild: e.unreadableByChild, previousSizes: e.previousSizes, previousAt: e.previousAt)
                lru.append(e.dir)
            }
            loadedListingCount = cache.count
            if cache[root] != nil { present() }
        }
    }

    /// Zapis pamięci wyników (z opóźnieniem 2 s, kolejne zmiany w tym czasie łączą się w jeden zapis). Zapis poza wątkiem głównym, atomowy.
    private func scheduleSave() {
        guard persistenceURL != nil else { return }
        saveGeneration += 1
        let gen = saveGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // try? świadomie: anulowanie zadania przerywa czekanie – oczekiwane
            guard let self, gen == self.saveGeneration else { return }
            await self.saveNow()
        }
    }

    /// Natychmiastowy zapis (testy i zamykanie aplikacji).
    func saveNow() async {
        guard let url = persistenceURL else { return }
        let entries = lru.compactMap { d in cache[d].map { DiskMapPersistence.Entry(dir: d, nodes: $0.nodes, measuredAt: $0.measuredAt, dirMTime: $0.dirMTime,
                                                                                  inaccessible: $0.inaccessible, unreadableInside: $0.unreadableInside,
                                                                                  checkpoint: $0.checkpoint, unreadableByChild: $0.unreadableByChild,
                                                                                  previousSizes: $0.previousSizes, previousAt: $0.previousAt) } }
        let home = self.home
        await Task.detached(priority: .utility) {
            guard let data = try? DiskMapPersistence.encode(entries, home: home) else { return }   // try? świadomie: dane nieufne lub uszkodzone ⇒ traktowane jako brak danych
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)   // try? świadomie: brak katalogu ⇒ kolejny zapis sam zgłosi błąd
            try? data.write(to: url, options: .atomic)                                  // try? świadomie: pamięć wyników to tylko przyspieszenie – brak zapisu = skan przy następnym starcie
        }.value
    }

    /// Wiersze do wyświetlenia: w trakcie skanu stała kolejność alfabetyczna, po skanie wg rozmiaru (to samo `id` ⇒ jedno animowane przejście).
    var displayRows: [ScanRow] { scanning ? scanRows : nodes.map { ScanRow(id: $0.path, name: $0.name, node: $0) } }

    var cachedListingCount: Int { cache.count }
    func isCached(_ dir: String) -> Bool { cache[dir] != nil }

    /// Zmiana korzenia mapy (np. folder wybrany w panelu otwierania). Wynik z pamięci pokazywany od razu.
    func jump(to root: String) { rootPath = root; path = [root]; present() }

    var current: String { path.last ?? rootPath }
    var total: UInt64 { nodes.reduce(0) { $0 + $1.size } }
    var selectedTotal: UInt64 { selected.reduce(0) { $0 + (selectedSizes[$1] ?? 0) } }
    var selectedPaths: [String] { selected.sorted() }

    /// Synchronicznie pokazuje wynik z pamięci (albo pusty widok, gdy folderu jeszcze nie liczono).
    private func present() {
        highlighted = nil
        scanRows = []; progress = nil
        if let l = cache[current] {
            touch(current)
            nodes = l.nodes; lastMeasuredAt = l.measuredAt
            inaccessible = l.inaccessible; unreadableInside = l.unreadableInside
            for n in l.nodes where selected.contains(n.path) { selectedSizes[n.path] = n.size }
            scanning = false
        } else {
            if !nodes.isEmpty { nodes = [] }
            inaccessible = []; unreadableInside = 0
            lastMeasuredAt = nil; scanning = false
        }
    }

    private func touch(_ dir: String) { lru.removeAll { $0 == dir }; lru.append(dir) }

    private func store(_ dir: String, nodes: [MapNode], measuredAt: Date, dirMTime: Date, inaccessible: [String] = [], unreadableInside: Int = 0,
                       checkpoint: ChangeCheckpoint? = nil, unreadableByChild: [String: Int] = [:]) {
        let (previousSizes, previousAt) = baseline(for: dir, measuredAt: measuredAt)
        cache[dir] = Listing(nodes: nodes, measuredAt: measuredAt, dirMTime: dirMTime, inaccessible: inaccessible, unreadableInside: unreadableInside,
                             checkpoint: checkpoint, unreadableByChild: unreadableByChild, previousSizes: previousSizes, previousAt: previousAt)
        touch(dir)
        var cachedNodes = cache.values.reduce(0) { $0 + $1.nodes.count }
        while (cache.count > maxListings || cachedNodes > maxCachedNodes), let oldest = lru.first(where: { $0 != current }) {
            cachedNodes -= cache[oldest]?.nodes.count ?? 0
            cache[oldest] = nil; lru.removeAll { $0 == oldest }
        }
        scheduleSave()
    }

    /// F11: punkt odniesienia dla nowego wyniku – poprzedni wynik, gdy jest starszy o co najmniej godzinę; inaczej jego własny punkt odniesienia.
    private func baseline(for dir: String, measuredAt: Date) -> ([String: UInt64], Date?) {
        guard let old = cache[dir] else { return ([:], nil) }
        if measuredAt.timeIntervalSince(old.measuredAt) >= Self.comparisonMinAge {
            return (Dictionary(old.nodes.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a }), old.measuredAt)
        }
        return (old.previousSizes, old.previousAt)
    }

    /// F11: zmiana rozmiaru elementu od wcześniejszego pomiaru (nil – brak punktu odniesienia albo zmiana pomijalna: < 10 MB lub < 5%).
    struct SizeChange: Equatable { let delta: Int64; let isNew: Bool; let since: Date }
    static let minVisibleChange: UInt64 = 10_000_000
    func change(for n: MapNode) -> SizeChange? {
        guard let l = cache[current], let at = l.previousAt else { return nil }
        if let prev = l.previousSizes[n.name] {
            let d = Int64(clamping: n.size) - Int64(clamping: prev)
            return d.magnitude >= max(Self.minVisibleChange, prev / 20) ? SizeChange(delta: d, isNew: false, since: at) : nil
        }
        return n.size >= Self.minVisibleChange ? SizeChange(delta: Int64(clamping: n.size), isNew: true, since: at) : nil
    }

    /// F12: elementy obecne we wcześniejszym pomiarze, których już nie ma (i nie są „bez dostępu”) – od największych; pomijalne (< 10 MB) pominięte.
    struct Removed: Equatable { let name: String; let size: UInt64 }
    func removedSinceBaseline() -> (items: [Removed], since: Date)? {
        guard let l = cache[current], let at = l.previousAt else { return nil }
        let present = Set(l.nodes.map(\.name)).union(l.inaccessible.map { ($0 as NSString).lastPathComponent })
        let gone = l.previousSizes.filter { !present.contains($0.key) && $0.value >= Self.minVisibleChange }
            .map { Removed(name: $0.key, size: $0.value) }.sorted { $0.size > $1.size }
        return gone.isEmpty ? nil : (gone, at)
    }

    private func isStale(_ dir: String, _ l: Listing) -> Bool {
        guard let m = FileStat.of(dir)?.modified else { return true }
        if now().timeIntervalSince(l.measuredAt) > Self.maxResultAge { return true }       // F4: stary wynik (np. z poprzedniego dnia) – odśwież w tle
        return abs(m.timeIntervalSince(l.dirMTime)) > 0.000_001
    }

    /// Użytkownik prosi o świeży pomiar bieżącego folderu („Odśwież”).
    func refreshCurrent() { Task { await scan(force: true) } }

    /// Pomiar bieżącego folderu. Bez `force` wynik z pamięci wystarcza; odświeżany w tle tylko, gdy coś się zmieniło:
    /// F8 – wg dziennika zmian (FSEvents) i wtedy przeliczane są TYLKO zmienione dzieci; bez dziennika – wg daty zmiany katalogu i wieku wyniku.
    func scan(force: Bool = false) async {
        let dir = current
        guard let l = cache[dir] else { await measure(dir, keepVisible: false); return }
        present()
        if force { await measure(dir, keepVisible: true); return }
        if changeJournalEnabled, let since = l.checkpoint {
            let fresh = ChangeJournal.checkpoint(for: dir), timeout = changeJournalTimeout
            // audyt 16.10 (P2): odczyt dziennika czeka (do kilku sekund) – na wątku GCD, a nie na wątku ograniczonej puli Swift Concurrency
            let changes = await withCheckedContinuation { (c: CheckedContinuation<ChangeJournal.Changes?, Never>) in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: ChangeJournal.changes(under: dir, since: since, timeout: timeout)) }
            }
            guard dir == current else { return }                                        // użytkownik przeszedł gdzie indziej – tamten folder ma własny skan
            if let changes {
                let plan = ChangePlanner.plan(dir: dir, changed: changes.paths, mustRescan: changes.mustRescan)
                lastPlan = plan
                switch plan {
                case .unchanged:
                    if now().timeIntervalSince(l.measuredAt) > Self.maxTrustedAge { await measure(dir, keepVisible: true) }
                    else if let fresh, cache[dir]?.checkpoint == since { cache[dir]?.checkpoint = fresh; scheduleSave() }   // następne zapytanie krótsze
                case .children(let kids, let relist):
                    // „Bez dostępu” musi przetrwać częściowe przeliczenie: gdy nie wiadomo, którego dziecka dotyczy (wynik sprzed F8, lista wnuków) – pełny pomiar.
                    if l.unreadableInside != l.unreadableByChild.values.reduce(0, +) { await measure(dir, keepVisible: true) }
                    else { await measure(dir, keepVisible: true, only: Only(kids: kids, relist: relist)) }
                case .full:
                    await measure(dir, keepVisible: true)
                }
                return
            }
        }
        if isStale(dir, l) { await measure(dir, keepVisible: true) }
    }

    /// F8: przeliczenie części dzieci – te ze zmianami, nowe, a przy `relist` także pliki leżące bezpośrednio w folderze; usunięte znikają z wyniku.
    struct Only: Sendable { var kids: Set<String>; var relist: Bool }

    /// Wynik pomiaru jednego elementu folderu: węzeł (nil = pusty/pominięty), zawartość podfolderu (wnuki) i informacja o braku dostępu (P1-4).
    struct ChildResult: Sendable {
        var name: String; var node: MapNode? = nil; var grand: [MapNode]? = nil; var grandInaccessible: [String] = []; var grandUnreadable = 0
        var inaccessible = false; var unreadableInside = 0
    }
    private enum ScanEvent { case names([String], present: [String]); case done(ChildResult) }

    /// Pomiar jednego elementu folderu (wątek GCD). Przerwany skan zwraca pusty wynik – i tak jest odrzucany (inna generacja), nigdy zapisywany jako pełny.
    nonisolated static func measureChild(dir: String, name k: String, registry: HardLinkRegistry, cancel: ScanCancellation) -> ChildResult {
        guard !cancel.isCancelled else { return ChildResult(name: k) }
        let p = dir + "/" + k
        guard let st = FileStat.of(p), !st.isSymlink else { return ChildResult(name: k) }
        if st.isDirectory, !DiskUsage.canList(p) { return ChildResult(name: k, inaccessible: true) }
        var seen = Set<FileID>()
        let t = DiskUsage.measureTree(p, trackKinds: true, sparseSeen: true, seen: &seen, shared: registry, shouldStop: { cancel.isCancelled })
        return childResult(dir: dir, name: k, isDirectory: st.isDirectory, tree: t)
    }

    /// Wynik dziecka z drzewa pomiaru (wspólne dla pomiaru pojedynczego i puli równoległej).
    nonisolated static func childResult(dir: String, name k: String, isDirectory: Bool, tree t: DiskUsage.Tree) -> ChildResult {
        let p = dir + "/" + k
        let u = t.total
        guard u.allocated > 0 else { return ChildResult(name: k, unreadableInside: u.unreadable) }
        let cat = MapCategory(kind: u.dominantKind, isApp: k.hasSuffix(".app"))
        let node = MapNode(path: p, name: k, size: u.allocated, isDirectory: isDirectory, items: u.fileCount, category: cat, breakdown: categoryBreakdown(u.bytesByKind))
        guard isDirectory, t.children.count <= childListingMaxEntries else { return ChildResult(name: k, node: node, unreadableInside: u.unreadable) }
        let grand: [MapNode] = t.children.compactMap { name, c in
            guard c.usage.allocated > 0 else { return nil }
            return MapNode(path: p + "/" + name, name: name, size: c.usage.allocated, isDirectory: c.isDirectory, items: c.usage.fileCount,
                           category: MapCategory(kind: c.usage.dominantKind, isApp: name.hasSuffix(".app")), breakdown: categoryBreakdown(c.usage.bytesByKind))
        }.sorted { $0.size > $1.size }
        // wnuk bez dostępu: jego wiadro ma tylko licznik braku dostępu (wpis samego katalogu liczy się do rodzica)
        let grandInaccessible = t.children.filter { $0.value.isDirectory && $0.value.usage.allocated == 0 && $0.value.usage.unreadable > 0 }.map { p + "/" + $0.key }.sorted()
        let grandUnreadable = t.children.values.reduce(0) { $0 + $1.usage.unreadable } - grandInaccessible.count
        return ChildResult(name: k, node: node, grand: grand, grandInaccessible: grandInaccessible, grandUnreadable: max(0, grandUnreadable), unreadableInside: u.unreadable)
    }

    private func measure(_ dir: String, keepVisible: Bool, only: Only? = nil) async {
        generation += 1
        let gen = generation
        if keepVisible { refreshing = true } else { if !nodes.isEmpty { nodes = [] }; selectedSizesPrune(); highlighted = nil; scanning = true }
        let dirMTime = FileStat.of(dir)?.modified ?? Date()
        let checkpoint = changeJournalEnabled ? ChangeJournal.checkpoint(for: dir) : nil      // PRZED pomiarem: zmiany w trakcie zostaną zgłoszone następnym razem
        let base = only != nil ? cache[dir] : nil
        let cachedNames: Set<String> = Set((base?.nodes.map(\.name) ?? []) + (base?.inaccessible.map { ($0 as NSString).lastPathComponent } ?? [])
                                           + (base.map { Array($0.unreadableByChild.keys) } ?? []))
        currentCancel?.cancel()
        let cancel = ScanCancellation(); currentCancel = cancel
        let registry = HardLinkRegistry(), gauge = gauge, limit = ScanConcurrency.limit()
        // Radix: jedna pula wątków dla całego folderu (połowa rdzeni, 2–8, mniej przy oszczędzaniu energii i wysokiej temperaturze) na wątkach GCD,
        // nie w puli współbieżności Swifta (pomiar to blokujące I/O). Jednostką pracy jest katalog, więc duży podfolder liczy kilka wątków naraz (F7).
        // Wspólny rejestr dowiązań: plik z dowiązaniem w dwóch dzieciach liczy się raz (F6).
        let stream = AsyncStream<ScanEvent> { cont in
            DispatchQueue.global(qos: .utility).async {
                let present = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []   // try? świadomie: nieczytelny katalog ⇒ brak wpisów (tylko odczyt)
                var todo: [(name: String, stat: FileStat?)] = []
                for k in present {
                    let st = FileStat.of(dir + "/" + k)
                    if let only, cachedNames.contains(k), !only.kids.contains(k), !(only.relist && !(st?.isDirectory ?? false)) { continue }   // bez zmian – wynik z pamięci
                    todo.append((k, st))
                }
                cont.yield(.names(todo.map(\.name), present: present))
                var dirs: [String] = []
                for (k, st) in todo {
                    if cancel.isCancelled { break }
                    let p = dir + "/" + k
                    guard let st, !st.isSymlink else { cont.yield(.done(ChildResult(name: k))); continue }
                    if !st.isDirectory { cont.yield(.done(Self.measureChild(dir: dir, name: k, registry: registry, cancel: cancel))); continue }
                    if !DiskUsage.canList(p) { cont.yield(.done(ChildResult(name: k, inaccessible: true))); continue }
                    dirs.append(k)
                }
                if !cancel.isCancelled {
                    #if canImport(Darwin)
                    ParallelTreeMeasure.measureDirectories(in: dir, names: dirs, limit: limit, registry: registry, trackKinds: true,
                                                           shouldStop: { cancel.isCancelled }, gauge: gauge) { o in
                        cont.yield(.done(o.stopped ? ChildResult(name: o.name) : Self.childResult(dir: dir, name: o.name, isDirectory: true, tree: o.tree)))
                    }
                    #else
                    for k in dirs { cont.yield(.done(Self.measureChild(dir: dir, name: k, registry: registry, cancel: cancel))) }
                    #endif
                }
                cont.finish()
            }
        }
        measureCount += 1
        var collected: [MapNode] = []
        var grands: [String: [MapNode]] = [:]
        var grandsAccess: [String: (inaccessible: [String], unreadable: Int)] = [:]
        var noAccess: [String] = [], unreadableByChild: [String: Int] = [:], measuredNames: [String] = []
        var rows: [ScanRow] = [], rowIndex: [String: Int] = [:]
        var done = 0, total = 0, latest: String?
        var lastFlush = Date.distantPast
        for await ev in stream {
            guard gen == generation else { return }
            switch ev {
            case .names(let names, let present):
                total = names.count; measuredNames = names
                if let base {                                                           // część dzieci: reszta z pamięci (usunięte – pominięte)
                    let kept = Set(present).subtracting(names)
                    collected = base.nodes.filter { kept.contains($0.name) }
                    noAccess = base.inaccessible.filter { kept.contains(($0 as NSString).lastPathComponent) }
                    unreadableByChild = base.unreadableByChild.filter { kept.contains($0.key) }
                }
                if !keepVisible {
                    rows = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ScanRow(id: dir + "/" + $0, name: $0, node: nil) }
                    for (i, r) in rows.enumerated() { rowIndex[r.id] = i }
                    if dir == current { scanRows = rows }
                }
                if dir == current { progress = ScanProgress(done: 0, total: total, latest: nil) }
            case .done(let r):
                done += 1; latest = r.name
                if r.inaccessible { noAccess.append(dir + "/" + r.name) }
                if r.unreadableInside > 0 { unreadableByChild[r.name] = r.unreadableInside }
                if let node = r.node {
                    collected.append(node)
                    if let grand = r.grand { grands[node.path] = grand; grandsAccess[node.path] = (r.grandInaccessible, r.grandUnreadable) }
                    if !keepVisible, let i = rowIndex[node.path] { rows[i].node = node }
                }
                // publikacje ograniczone do ~7 na sekundę – wiersze i pasek postępu zmieniają się płynnie, a mapa (bąbelki) nie jest przeliczana w trakcie skanu
                if Date().timeIntervalSince(lastFlush) >= 0.15, dir == current {                // audyt 3.4: postęp tylko dla oglądanego folderu
                    lastFlush = Date()
                    if !keepVisible { scanRows = rows }
                    progress = ScanProgress(done: done, total: total, latest: latest)
                }
            }
        }
        guard gen == generation else { return }
        collected.sort { $0.size > $1.size }
        let now = Date()
        noAccess.sort()
        let unreadableIn = unreadableByChild.values.reduce(0, +)
        lastMeasuredNames = measuredNames
        store(dir, nodes: collected, measuredAt: now, dirMTime: dirMTime, inaccessible: noAccess, unreadableInside: unreadableIn,
              checkpoint: checkpoint, unreadableByChild: unreadableByChild)
        // zawartość największych podfolderów – wejście w głąb nie liczy ich drugi raz
        for n in collected.prefix(childListingsKept) where n.isDirectory {
            if let grand = grands[n.path], cache[n.path] == nil || keepVisible {
                store(n.path, nodes: grand, measuredAt: now, dirMTime: FileStat.of(n.path)?.modified ?? now,
                      inaccessible: grandsAccess[n.path]?.inaccessible ?? [], unreadableInside: grandsAccess[n.path]?.unreadable ?? 0, checkpoint: checkpoint)
            }
        }
        // Audyt 3.4: użytkownik mógł w trakcie pomiaru wrócić do folderu z pamięci – wynik zapisany wyżej w pamięci, ale NIE publikowany na cudzym widoku.
        guard dir == current else { return }
        nodes = collected; lastMeasuredAt = now                    // jedyna publikacja `nodes` w całym skanie
        inaccessible = noAccess; unreadableInside = unreadableIn
        for n in collected where selected.contains(n.path) { selectedSizes[n.path] = n.size }
        scanRows = []; progress = nil
        scanning = false; refreshing = false
    }

    private func selectedSizesPrune() { selectedSizes = selectedSizes.filter { selected.contains($0.key) } }

    func open(_ n: MapNode) {
        guard n.isDirectory else { return }
        path.append(n.path)
        present()
        Task { await scan() }
    }

    func go(to index: Int) {
        guard index < path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        present()
        Task { await scan() }
    }

    func toggle(_ n: MapNode) { toggle(path: n.path, size: n.size) }

    /// Zaznaczenie po ścieżce (mapa i lista duplikatów). Odcisk z chwili zaznaczenia – narzędzie Kosza sprawdzi go tuż przed operacją (W5).
    func toggle(path: String, size: UInt64) {
        if selected.contains(path) {
            selected.remove(path); selectedSizes[path] = nil; selectedFingerprints[path] = nil; cloudSelected.remove(path)
        } else {
            selected.insert(path); selectedSizes[path] = size
            selectedFingerprints[path] = FileFingerprint(path: path)?.encoded ?? ""
            if isCloud(path) { cloudSelected.insert(path) }
        }
    }

    // MARK: Duplikaty (P1-7 / część P2-13) – tylko odczyt; usuwanie wyłącznie przez „Przenieś do Kosza” dla zaznaczonych (W5)
    @Published private(set) var duplicates: DuplicateFinder.ScanResult?
    @Published private(set) var duplicatesLoading = false
    /// Folder, którego dotyczy wynik duplikatów.
    @Published private(set) var duplicatesRoot: String?
    static let duplicateMinSize: UInt64 = 1_000_000
    /// Porównanie klonów APFS (kopie współdzielące dane nie zwalniają miejsca). Testy podstawiają `NoCloneInfo`.
    var duplicateClones: CloneInfoProvider = NoCloneInfo()

    /// Szuka duplikatów w bieżącym korzeniu mapy. Bez `force` wynik z tej sesji dla tego samego folderu wystarcza.
    func findDuplicates(force: Bool = false) async {
        if duplicatesLoading { return }
        let root = rootPath
        if !force, duplicates != nil, duplicatesRoot == root { return }
        duplicatesLoading = true
        let clones = duplicateClones, min = Self.duplicateMinSize
        let r = await Task.detached(priority: .utility) { DuplicateFinder.scan(root: root, minSize: min, clones: clones) }.value
        duplicates = r; duplicatesRoot = root; duplicatesLoading = false
    }

    /// Ochrona przed usunięciem WSZYSTKICH kopii: ostatniej niezaznaczonej kopii w grupie nie da się zaznaczyć.
    func canToggle(_ path: String, in group: DuplicateGroup) -> Bool { canToggle(path, inGroup: group.paths) }

    func canToggle(_ path: String, inGroup paths: [String]) -> Bool {
        selected.contains(path) || paths.filter { !selected.contains($0) }.count > 1
    }

    // MARK: Podobne zdjęcia (P2-13, część) – tylko odczyt; usuwanie wyłącznie przez W5
    @Published private(set) var similar: ImageHasher.ScanResult?
    @Published private(set) var similarLoading = false
    @Published private(set) var similarRoot: String?

    func findSimilar(force: Bool = false) async {
        if similarLoading { return }
        let root = rootPath
        if !force, similar != nil, similarRoot == root { return }
        similarLoading = true
        let r = await Task.detached(priority: .utility) { ImageHasher.similar(root: root) }.value
        similar = r; similarRoot = root; similarLoading = false
    }

    /// Odciski zaznaczonych ścieżek (w tej samej kolejności); pusty napis = nie udało się odczytać w chwili zaznaczenia.
    func fingerprints(for paths: [String]) -> [String] { paths.map { selectedFingerprints[$0] ?? "" } }

    /// Po przeniesieniu do Kosza (W5): koryguje pamięć wyników BEZ pełnego skanu. Przeniesiony element znika z listingu rodzica, jego rozmiar jest odejmowany od wierszy
    /// wszystkich przodków, listingi przeniesionego folderu i jego podfolderów są wyrzucane z pamięci, a zaznaczenie i lista dużych plików są czyszczone.
    /// Rozkład kategorii przodków jest wtedy przybliżony – „Odśwież” liczy dokładnie.
    func itemsTrashed(_ moved: [(path: String, bytes: UInt64)]) {
        guard !moved.isEmpty else { return }
        let paths = Set(moved.map(\.path))
        for key in Array(cache.keys) where paths.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) { cache[key] = nil; lru.removeAll { $0 == key } }
        for (key, listing) in cache {
            var nodes = listing.nodes
            var changed = false
            var directParent = false
            for m in moved where m.path.hasPrefix(key + "/") {
                let rest = m.path.dropFirst(key.count + 1)
                guard let first = rest.split(separator: "/").first else { continue }
                let child = key + "/" + first
                guard let i = nodes.firstIndex(where: { $0.path == child }) else { continue }
                if child == m.path { nodes.remove(at: i); directParent = true }
                else { nodes[i] = nodes[i].reduced(by: m.bytes) }
                changed = true
            }
            if changed {
                cache[key]?.nodes = nodes
                if directParent, let mt = FileStat.of(key)?.modified { cache[key]?.dirMTime = mt }          // zmiana mtime rodzica pochodzi od nas – bez zbędnego odświeżania
            }
        }
        selected.subtract(paths)
        for p in paths { selectedSizes[p] = nil; selectedFingerprints[p] = nil; cloudSelected.remove(p) }
        if var l = largeFiles { l.removeAll { paths.contains($0.path) }; largeFiles = l }
        if var sim = similar {
            sim.groups = sim.groups.compactMap { g in let left = g.filter { !paths.contains($0.path) }; return left.count > 1 ? left : nil }
            similar = sim
        }
        if var d = duplicates {
            d.groups = d.groups.compactMap { g in
                var g = g; g.paths.removeAll { paths.contains($0) }
                return g.paths.count > 1 ? g : nil
            }
            duplicates = d
        }
        // bieżący folder mógł zniknąć razem z przeniesionym przodkiem – cofnij nawigację do najbliższego istniejącego
        while path.count > 1, !FileManager.default.fileExists(atPath: current) { path.removeLast() }
        present()
        scheduleSave()
    }

    /// Lista największych plików (zakładka „Duże pliki”) – liczona raz na sesję, ponownie tylko na żądanie.
    func loadLargeFiles(provider: DiagnosticsProvider, force: Bool = false) async {
        if largeLoading { return }
        if !force, largeFiles != nil { return }
        largeLoading = true
        largeFiles = await provider.largeFiles(minBytes: 500_000_000, olderThanDays: nil, limit: 50)
        largeLoading = false
    }

    /// Okręgi do narysowania: do `limit` największych + zbiorczy „Inne”.
    struct Bubble: Identifiable { let id: String; let node: MapNode?; let label: String; let size: UInt64; let category: MapCategory; let circle: PackedCircle
        /// Podpowiedź: nazwa, rozmiar i rozkład zawartości (top 4 kategorie).
        var tooltip: String {
            var lines = ["\(label)", "\(ByteFormat.string(size)) · \(category.label)"]
            if let n = node, n.breakdown.count > 1 || n.isDirectory {
                lines.append(n.breakdown.prefix(4).map { "\($0.category.label) \(ByteFormat.string($0.bytes))" }.joined(separator: " · "))
            }
            return lines.joined(separator: "\n")
        }
    }
    func bubbles(limit: Int = 24) -> [Bubble] {
        var items: [(MapNode?, String, UInt64, MapCategory)] = nodes.prefix(limit).map { ($0, $0.name, $0.size, $0.category) }
        let restNodes = nodes.dropFirst(limit)
        let rest = restNodes.reduce(UInt64(0)) { $0 + $1.size }
        if rest > 0 { items.append((nil, String(localized: "Pozostałe (\(restNodes.count))"), rest, .other)) }
        guard !items.isEmpty else { return [] }
        let packed = CirclePacking.pack(radii: CirclePacking.radii(forSizes: items.map { $0.2 }), gap: 0.03)
        return zip(items, packed).map { Bubble(id: $0.0.0?.path ?? "__other", node: $0.0.0, label: $0.0.1, size: $0.0.2, category: $0.0.3, circle: $0.1) }
    }

    /// Legenda: suma zajętości w każdej kategorii (tylko te, które występują), od największej.
    func legend() -> [(category: MapCategory, size: UInt64)] {
        var by: [MapCategory: UInt64] = [:]
        for n in nodes { by[n.category, default: 0] += n.size }
        return by.map { (category: $0.key, size: $0.value) }.sorted { $0.size > $1.size }
    }
}
