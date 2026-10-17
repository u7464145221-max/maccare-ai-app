#include "cnvme_smart.h"
#include <string.h>
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

int cnvme_smart_read(cnvme_smart_t *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEmbeddedNVMeBlockDevice"), &it) != KERN_SUCCESS) return -2;
    int result = -3;
    io_service_t s;
    while (result != 0 && (s = IOIteratorNext(it))) {
        CFTypeRef cap = IORegistryEntryCreateCFProperty(s, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        Boolean capable = cap == kCFBooleanTrue;
        if (cap) CFRelease(cap);
        if (capable) {
            IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
            if (IOCreatePlugInInterfaceForService(s, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score) == KERN_SUCCESS && plug) {
                IONVMeSMARTInterface **sm = NULL;
                if ((*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&sm) == S_OK && sm) {
                    NVMeSMARTData d; memset(&d, 0, sizeof(d));
                    if ((*sm)->SMARTReadData(sm, &d) == kIOReturnSuccess) {
                        out->critical_warning = d.CRITICAL_WARNING;
                        out->temperature_kelvin = d.TEMPERATURE;
                        out->available_spare = d.AVAILABLE_SPARE;
                        out->available_spare_threshold = d.AVAILABLE_SPARE_THRESHOLD;
                        out->percentage_used = d.PERCENTAGE_USED;
                        out->data_units_read = d.DATA_UNITS_READ[0];
                        out->data_units_written = d.DATA_UNITS_WRITTEN[0];
                        out->power_cycles = d.POWER_CYCLES[0];
                        out->power_on_hours = d.POWER_ON_HOURS[0];
                        out->unsafe_shutdowns = d.UNSAFE_SHUTDOWNS[0];
                        out->media_errors = d.MEDIA_ERRORS[0];
                        result = 0;
                    }
                    (*sm)->Release(sm);
                }
                IODestroyPlugInInterface(plug);
            }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return result;
}
#else
int cnvme_smart_read(cnvme_smart_t *out) { (void)out; return -1; }
#endif
