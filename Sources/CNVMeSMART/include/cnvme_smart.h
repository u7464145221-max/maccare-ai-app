#ifndef CNVME_SMART_H
#define CNVME_SMART_H
#include <stdint.h>

/// Kondycja wbudowanego dysku NVMe z dziennika SMART (NVMe 1.0c, 5.10.1.2). Tylko odczyt – interfejs IOKit `IONVMeSMARTInterface`
/// (ten sam, którego używają narzędzia diagnostyczne), bez uprawnień administratora. Bez numeru seryjnego i innych identyfikatorów.
typedef struct {
    uint8_t  critical_warning;
    uint16_t temperature_kelvin;
    uint8_t  available_spare;
    uint8_t  available_spare_threshold;
    uint8_t  percentage_used;
    uint64_t data_units_read;       // jednostki po 1000 × 512 B
    uint64_t data_units_written;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
} cnvme_smart_t;

/// 0 = odczytano; inna wartość = brak danych (brak dysku NVMe z obsługą SMART albo błąd odczytu).
int cnvme_smart_read(cnvme_smart_t *out);

#endif
