/* T00 Darwin public C ABI probes (G03 and GCD C ABI).
 * S02 RED stub: every probe reports "not implemented". */

#include <stdint.h>

#define ZCR_PROBE_NOT_IMPLEMENTED (-99)

typedef struct {
    int32_t status;
    int32_t callback_ran;
    uint32_t requested_qos;
    uint32_t observed_qos;
} zcr_gcd_probe;

int32_t zcr_probe_gcd(uint32_t qos_class, int64_t timeout_ns, zcr_gcd_probe *out) {
    (void)qos_class;
    (void)timeout_ns;
    out->status = ZCR_PROBE_NOT_IMPLEMENTED;
    return ZCR_PROBE_NOT_IMPLEMENTED;
}

int32_t zcr_probe_memory_pressure_source(void) { return ZCR_PROBE_NOT_IMPLEMENTED; }
int32_t zcr_probe_thermal_state(void) { return ZCR_PROBE_NOT_IMPLEMENTED; }
int32_t zcr_probe_low_power_mode(void) { return ZCR_PROBE_NOT_IMPLEMENTED; }
int32_t zcr_probe_power_source(void) { return ZCR_PROBE_NOT_IMPLEMENTED; }
int32_t zcr_probe_sdk_versions(int32_t *min_required, int32_t *max_allowed) {
    *min_required = ZCR_PROBE_NOT_IMPLEMENTED;
    *max_allowed = ZCR_PROBE_NOT_IMPLEMENTED;
    return ZCR_PROBE_NOT_IMPLEMENTED;
}
