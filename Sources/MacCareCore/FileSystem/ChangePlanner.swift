import Foundation

/// F8 (Radix): co przeliczyć w zapamiętanym folderze po zmianach zgłoszonych przez dziennik zmian systemu plików (FSEvents).
/// Zdarzenia są na poziomie katalogów: zmiana pliku w `X/a/b` daje zdarzenie dla `X/a/b`, więc wystarczy pierwszy składnik ścieżki pod folderem.
/// W razie wątpliwości (`mustRescan`: przepełnienie kolejki zdarzeń, zmieniony magazyn zdarzeń itp.) – pełny pomiar.
public enum ChangePlanner {
    public enum Plan: Equatable, Sendable {
        /// Nic pod folderem się nie zmieniło – wynik z pamięci jest aktualny.
        case unchanged
        /// Przeliczyć te dzieci; `relist` – zmieniła się zawartość samego folderu (nowe, usunięte lub zmienione pliki bezpośrednio w nim).
        case children(Set<String>, relist: Bool)
        /// Pełny pomiar folderu.
        case full
    }

    public static func plan(dir: String, changed: [String], mustRescan: Bool) -> Plan {
        if mustRescan { return .full }
        let d = normalize(dir)
        var kids = Set<String>(), relist = false
        for c in changed.lazy.map(normalize) {
            if c == d { relist = true; continue }
            guard c.hasPrefix(d == "/" ? "/" : d + "/") else { continue }
            let rest = c.dropFirst(d == "/" ? 1 : d.count + 1)
            if let first = rest.split(separator: "/", omittingEmptySubsequences: true).first { kids.insert(String(first)) }
        }
        return kids.isEmpty && !relist ? .unchanged : .children(kids, relist: relist)
    }

    /// Postać porównywalna: bez końcowego „/”, bez przedrostka „/private” dla /var, /tmp i /etc (FSEvents podaje ścieżki kanoniczne).
    public static func normalize(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        for alias in ["/var", "/tmp", "/etc"] where s == "/private" + alias || s.hasPrefix("/private" + alias + "/") { s.removeFirst("/private".count) }
        return s
    }
}
