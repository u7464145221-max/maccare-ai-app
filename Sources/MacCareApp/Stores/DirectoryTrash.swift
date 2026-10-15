import Foundation
import MacCareCore

/// Kosz zastępczy wyłącznie dla trybu demonstracyjnego (zrzuty ekranu, ręczne testy) na SYNTETYCZNYM katalogu domowym: przenosi elementy do wskazanego katalogu
/// zamiast do prawdziwego Kosza użytkownika. Włączany tylko, gdy ustawiono `MACCARE_TRASH_DIR` ORAZ `MACCARE_HOME` – nigdy dla prawdziwego HOME
/// (patrz `MacCareApp.init`). Jak `MacTrash` sam odmawia, gdy `ExecutionGuard` nie dopuszcza `.trashSelected`.
struct DirectoryTrash: TrashService {
    let dir: String

    func moveToTrash(_ path: String) throws -> String? {
        guard ExecutionGuard.allows(.trashSelected) else { throw ExecutionGuard.refusal(for: .trashSelected) }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ActionError(String(localized: "Ścieżka musi być bezwzględna")) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var dest = dir + "/" + (path as NSString).lastPathComponent
        var n = 1
        while FileStat.of(dest) != nil { n += 1; dest = dir + "/" + (path as NSString).lastPathComponent + " \(n)" }
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        return dest
    }
}
