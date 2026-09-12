#include "darwin_shim.h"
#include <dispatch/dispatch.h>
#include <sys/qos.h>
#include <stdlib.h>

struct zcr_gcd_executor { dispatch_queue_t queues[3]; };
static void barrier_noop(void *context) { (void)context; }
zcr_gcd_executor *zcr_gcd_create(void) {
    static const qos_class_t qos[3] = { QOS_CLASS_USER_INITIATED, QOS_CLASS_UTILITY, QOS_CLASS_BACKGROUND };
    static const char *labels[3] = { "dev.zcr.foreground", "dev.zcr.maintenance", "dev.zcr.idle" };
    zcr_gcd_executor *executor = calloc(1, sizeof(*executor));
    if (executor == NULL) return NULL;
    for (unsigned i = 0; i < 3; ++i) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, qos[i], 0);
        if (attr != NULL) executor->queues[i] = dispatch_queue_create(labels[i], attr);
        if (executor->queues[i] == NULL) {
            for (unsigned j = 0; j < i; ++j) dispatch_release(executor->queues[j]);
            free(executor);
            return NULL;
        }
    }
    return executor;
}
void zcr_gcd_submit(zcr_gcd_executor *executor, uint32_t lane, void *context, zcr_gcd_callback callback) {
    if (lane >= 3) abort();
    dispatch_async_f(executor->queues[lane], context, callback);
}
void zcr_gcd_destroy(zcr_gcd_executor *executor) {
    for (unsigned i = 0; i < 3; ++i) {
        dispatch_barrier_sync_f(executor->queues[i], NULL, barrier_noop);
        dispatch_release(executor->queues[i]);
    }
    free(executor);
}
uint32_t zcr_gcd_current_qos(void) { return (uint32_t)qos_class_self(); }
