#if os(macOS)
import Foundation
import MacCareCore

/// Kosz systemowy przez `FileManager.trashItem` (zwraca ścieżkę w Koszu, więc można przywrócić).
/// Warstwa ostatniej obrony: odrzuca lokalizacje chronione przez `PathPolicy`, niezależnie od wywołującego.
public struct MacTrash: TrashService {
    public struct Refused: Error, LocalizedError {
        public var path: String; public var reason: String
        public var errorDescription: String? { "Odmowa przeniesienia do Kosza (\(path)): \(reason)" }
    }

    let policy: PathPolicy
    public init(home: String = NSHomeDirectory()) { policy = PathPolicy(home: home) }

    public func moveToTrash(_ path: String) throws -> String? {
        guard ExecutionGuard.allows(.trashSelected) else { throw Refused(path: path, reason: ExecutionGuard.refusalMessage(for: .trashSelected)) }
        guard !path.isEmpty, !path.contains("\0"), path.hasPrefix("/") else { throw Refused(path: path, reason: String(localized: "ścieżka musi być bezwzględna")) }
        let target = policy.resolvedTarget(path)
        for d in policy.hardDenied where target == PathTools.canonical(d, home: policy.home) { throw Refused(path: path, reason: String(localized: "chroniona lokalizacja")) }
        for d in policy.protectedSubtrees where PathTools.isWithin(target, PathTools.canonical(d, home: policy.home)) { throw Refused(path: path, reason: String(localized: "chroniony obszar")) }
        var result: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: &result)
        return (result as URL?)?.path
    }
}
#endif
