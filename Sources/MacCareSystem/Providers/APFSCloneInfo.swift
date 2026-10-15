#if os(macOS)
import Foundation
import MacCareCore

/// Informacje o klonach APFS przez `getattrlist` z `FSOPT_ATTR_CMN_EXTENDED`:
/// `ATTR_CMNEXT_PRIVATESIZE` (bajty wyłączne dla pliku) i `ATTR_CMNEXT_CLONEID` (rodzina klonów).
/// Przy jakimkolwiek błędzie (inny system plików, katalog, brak uprawnień) zwraca nil – nigdy nie zgaduje.
public struct APFSCloneInfo: CloneInfoProvider {
    public init() {}

    // Stałe z <sys/attr.h> (rozszerzone atrybuty wspólne podaje się w polu `forkattr`).
    private static let cmnextPrivateSize: UInt32 = 0x0000_0008
    private static let cmnextCloneID: UInt32 = 0x0000_0100
    private static let optNoFollow: UInt32 = 0x0000_0001
    private static let optCmnExtended: UInt32 = 0x0000_0020

    private struct Attrs { var privateSize: UInt64; var cloneID: UInt64 }

    private func read(_ path: String) -> Attrs? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(Self.cmnextPrivateSize | Self.cmnextCloneID)
        var buf = [UInt8](repeating: 0, count: 64)
        let rc = buf.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, Self.optCmnExtended | Self.optNoFollow)
        }
        guard rc == 0 else { return nil }
        let length = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard length >= 4 + 8 + 8 else { return nil }
        // Kolejność w buforze = rosnąca wartość bitu: PRIVATESIZE (off_t), potem CLONEID (u_int64_t).
        let priv = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        let clone = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) }
        return Attrs(privateSize: UInt64(max(0, priv)), cloneID: clone)
    }

    public func privateSize(path: String) -> UInt64? { read(path)?.privateSize }
    public func cloneID(path: String) -> UInt64? { read(path)?.cloneID }
}
#endif
