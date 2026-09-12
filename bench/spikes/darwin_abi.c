/* T00 Darwin public C ABI probes (gate G03 and the GCD C ABI).
 *
 * Only public SDK interfaces are used: libdispatch `_f` variants (no Blocks
 * ABI), sys/qos.h, the Objective-C runtime to read NSProcessInfo, and IOKit
 * power sources. OSThermalNotificationCurrentLevel is not used because the
 * macOS SDK marks it __MAC_NA.
 *
 * Return convention: >= 0 is a value, negative values are ZCR_PROBE_* codes. */

#include <stdint.h>
#include <stdlib.h>

#include <Availability.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <sys/qos.h>

#define ZCR_PROBE_OK 0
#define ZCR_PROBE_UNSUPPORTED (-1)
#define ZCR_PROBE_TIMEOUT (-2)
#define ZCR_PROBE_FAILED (-3)

/* Public Foundation export. Referencing it also keeps Foundation loaded so the
 * NSProcessInfo class lookup below is meaningful. */
extern double NSFoundationVersionNumber;

typedef struct {
    int32_t status;
    int32_t callback_ran;
    uint32_t requested_qos;
    uint32_t observed_qos;
} zcr_gcd_probe;

typedef struct {
    int32_t ran;
    uint32_t observed_qos;
} gcd_job;

static void gcd_job_run(void *context) {
    gcd_job *job = context;
    job->observed_qos = (uint32_t)qos_class_self();
    job->ran = 1;
}

int32_t zcr_probe_gcd(uint32_t qos_class, int64_t timeout_ns, zcr_gcd_probe *out) {
    out->status = ZCR_PROBE_FAILED;
    out->callback_ran = 0;
    out->requested_qos = qos_class;
    out->observed_qos = 0;

    dispatch_queue_attr_t attr =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, (qos_class_t)qos_class, 0);
    if (attr == NULL) return out->status = ZCR_PROBE_UNSUPPORTED;

    dispatch_queue_t queue = dispatch_queue_create("dev.zcr.t00.gcd-probe", attr);
    if (queue == NULL) return out->status;

    gcd_job *job = calloc(1, sizeof *job);
    if (job == NULL) {
        dispatch_release(queue);
        return out->status;
    }

    dispatch_group_t group = dispatch_group_create();
    if (group == NULL) {
        free(job);
        dispatch_release(queue);
        return out->status;
    }

    dispatch_group_async_f(group, queue, job, gcd_job_run);
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, timeout_ns)) != 0) {
        /* The callback may still run later. Keep job, group and queue alive
         * instead of freeing memory the callback can touch. */
        return out->status = ZCR_PROBE_TIMEOUT;
    }

    out->callback_ran = job->ran;
    out->observed_qos = job->observed_qos;
    free(job);
    dispatch_release(group);
    dispatch_release(queue);
    return out->status = ZCR_PROBE_OK;
}

/* 1 when a memory-pressure dispatch source can be created and activated. */
int32_t zcr_probe_memory_pressure_source(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        queue);
    if (source == NULL) return ZCR_PROBE_UNSUPPORTED;
    dispatch_activate(source);
    dispatch_source_cancel(source);
    dispatch_release(source);
    return 1;
}

static id msg_id(id receiver, const char *selector) {
    return ((id(*)(id, SEL))objc_msgSend)(receiver, sel_registerName(selector));
}

static int responds(id receiver, const char *selector) {
    return class_respondsToSelector(object_getClass(receiver), sel_registerName(selector));
}

/* Runs `read` with the shared NSProcessInfo inside an autorelease pool. */
static int32_t with_process_info(int32_t (*read)(id)) {
    Class pool_class = objc_getClass("NSAutoreleasePool");
    Class info_class = objc_getClass("NSProcessInfo");
    if (pool_class == Nil || info_class == Nil) return ZCR_PROBE_UNSUPPORTED;

    id pool = msg_id(msg_id((id)pool_class, "alloc"), "init");
    id info = msg_id((id)info_class, "processInfo");
    int32_t result = info == nil ? ZCR_PROBE_UNSUPPORTED : read(info);
    ((void (*)(id, SEL))objc_msgSend)(pool, sel_registerName("drain"));
    return result;
}

static int32_t read_thermal_state(id info) {
    if (!responds(info, "thermalState")) return ZCR_PROBE_UNSUPPORTED;
    long state = ((long (*)(id, SEL))objc_msgSend)(info, sel_registerName("thermalState"));
    return state >= 0 && state <= 3 ? (int32_t)state : ZCR_PROBE_FAILED;
}

static int32_t read_low_power_mode(id info) {
    if (!responds(info, "isLowPowerModeEnabled")) return ZCR_PROBE_UNSUPPORTED;
    BOOL enabled = ((BOOL(*)(id, SEL))objc_msgSend)(info, sel_registerName("isLowPowerModeEnabled"));
    return enabled ? 1 : 0;
}

/* NSProcessInfoThermalState: 0 nominal, 1 fair, 2 serious, 3 critical. */
int32_t zcr_probe_thermal_state(void) { return with_process_info(read_thermal_state); }

/* 1 enabled, 0 disabled. */
int32_t zcr_probe_low_power_mode(void) { return with_process_info(read_low_power_mode); }

/* 0 unknown type, 1 AC, 2 battery, 3 UPS. */
int32_t zcr_probe_power_source(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (info == NULL) return ZCR_PROBE_UNSUPPORTED;

    int32_t result = 0;
    CFStringRef type = IOPSGetProvidingPowerSourceType(info);
    if (type != NULL) {
        if (CFStringCompare(type, CFSTR(kIOPMACPowerKey), 0) == kCFCompareEqualTo) result = 1;
        else if (CFStringCompare(type, CFSTR(kIOPMBatteryPowerKey), 0) == kCFCompareEqualTo) result = 2;
        else if (CFStringCompare(type, CFSTR(kIOPMUPSPowerKey), 0) == kCFCompareEqualTo) result = 3;
    }
    CFRelease(info);
    return result;
}

/* Availability macros the C compiler saw for this translation unit. */
int32_t zcr_probe_sdk_versions(int32_t *min_required, int32_t *max_allowed) {
#if defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && defined(__MAC_OS_X_VERSION_MAX_ALLOWED)
    *min_required = __MAC_OS_X_VERSION_MIN_REQUIRED;
    *max_allowed = __MAC_OS_X_VERSION_MAX_ALLOWED;
    return ZCR_PROBE_OK;
#else
    *min_required = ZCR_PROBE_UNSUPPORTED;
    *max_allowed = ZCR_PROBE_UNSUPPORTED;
    return ZCR_PROBE_UNSUPPORTED;
#endif
}

double zcr_probe_foundation_version(void) { return NSFoundationVersionNumber; }
