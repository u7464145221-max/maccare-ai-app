#if os(macOS)
import Foundation
import MacCareCore
import CNVMeSMART

/// 18.10 (decyzja właściciela): kondycja wbudowanego dysku SSD z dziennika SMART NVMe – tylko odczyt przez IOKit, bez uprawnień administratora.
/// Numer seryjny i inne identyfikatory dysku nie są odczytywane. nil = brak danych (np. dysk bez NVMe SMART).
enum SSDHealthCollector {
    static func read() -> SSDHealth? {
        var raw = cnvme_smart_t()
        guard cnvme_smart_read(&raw) == 0 else { return nil }
        return SSDHealth(percentUsed: Int(raw.percentage_used), availableSpare: Int(raw.available_spare), availableSpareThreshold: Int(raw.available_spare_threshold),
                         temperatureC: SSDHealth.celsius(kelvin: Int(raw.temperature_kelvin)),
                         dataWrittenBytes: SSDHealth.bytes(dataUnits: raw.data_units_written), dataReadBytes: SSDHealth.bytes(dataUnits: raw.data_units_read),
                         powerOnHours: raw.power_on_hours, unsafeShutdowns: raw.unsafe_shutdowns, mediaErrors: raw.media_errors,
                         criticalWarning: Int(raw.critical_warning))
    }
}
#endif
