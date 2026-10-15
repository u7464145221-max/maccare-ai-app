import Foundation

/// Przełączniki i zakładki, których etykietą jest `rawValue` (polski tekst = klucz lokalizacji). Kompilator nie widzi tych kluczy
/// (nie są literałami w `String(localized:)`), dlatego leżą w `Localization/keys-dynamic.txt`, który `Scripts/l10n_extract.sh` dołącza do `keys.txt`.
/// Test `LocalizationTests.everyDisplayedRawValueIsAKey` pilnuje, żeby żadna wartość nie została pominięta. `rawValue` zostaje polskie (zapis ustawień, testy).
protocol LocalizedRawTitle: RawRepresentable where RawValue == String {}

extension LocalizedRawTitle {
    var title: String { Bundle.main.localizedString(forKey: rawValue, value: rawValue, table: nil) }
}

extension HistoryTab: LocalizedRawTitle {}
extension ExecutionChoice: LocalizedRawTitle {}
extension FilesView.Tab: LocalizedRawTitle {}
extension AppsView.Tab: LocalizedRawTitle {}
extension ProtectionView.Tab: LocalizedRawTitle {}
extension CleanupDetail.Sort: LocalizedRawTitle {}
extension AppsStore.Sort: LocalizedRawTitle {}
extension AppsStore.Filter: LocalizedRawTitle {}

/// Wszystkie wyświetlane wartości (dla testu kompletności i dla `keys-dynamic.txt`).
enum LocalizedRawTitles {
    static var all: [String] {
        var out: [String] = []
        out += HistoryTab.allCases.map(\.rawValue)
        out += ExecutionChoice.allCases.map(\.rawValue)
        out += FilesView.Tab.allCases.map(\.rawValue)
        out += AppsView.Tab.allCases.map(\.rawValue)
        out += ProtectionView.Tab.allCases.map(\.rawValue)
        out += CleanupDetail.Sort.allCases.map(\.rawValue)
        out += AppsStore.Sort.allCases.map(\.rawValue)
        out += AppsStore.Filter.allCases.map(\.rawValue)
        return out
    }
}
