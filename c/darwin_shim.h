#ifndef ZCR_DARWIN_SHIM_H
#define ZCR_DARWIN_SHIM_H
#include <stdint.h>
/* Public libdispatch _f ABI; no Blocks, ObjC, private affinity, or UI QoS. */
typedef struct zcr_gcd_executor zcr_gcd_executor;
typedef void (*zcr_gcd_callback)(void *);
zcr_gcd_executor *zcr_gcd_create(void);
void zcr_gcd_submit(zcr_gcd_executor *, uint32_t lane, void *, zcr_gcd_callback);
/* Owner stops submission and drains its children before destroy. Barriers also
 * wait for the C callbacks themselves to return before queue storage is freed. */
void zcr_gcd_destroy(zcr_gcd_executor *);
uint32_t zcr_gcd_current_qos(void);
#endif
