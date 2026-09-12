T13 immutable cache implementation and native verification are complete; independent source review APPROVE.

Source: `8a4d74fe6f87a1f5427c6d0f94dd0b01fe082efd`; base: `98c722ebc906321b94bc3e9c8b60522f3305faa7`; initial behavioral RED: `29c732a4ccab3971ad371f87a0e7da0f0dbfd17f`. The evidence commit changes no source.

The cache separates domain/content-hash immutable storage from workspace/generation/file/path associations, reauthorizes and rehashes the current rooted file before every pin, admits on second touch, bypasses bulk scans, and indexes every 128 lines. Shared content is charged once per group; pins retain storage across eviction/invalidation. Shared verification credits and all control/content allocations are reserved and released.

Native Linux x86_64: memory Debug, ReleaseSafe and fault-debug each 26/26 (14 T13 + 12 T03); I/O regression 12/12; isolation regression 37/37. Contract verification and three clean-source standard evidence verifications passed. A non-test ReleaseSafe object confirms race/cancel hooks have no runtime storage.

The handoff records exact commands, source/config/corpus/binary/log digests, state byte counts, APIs and integration preconditions. Root must supply shared budgets and a thread-safe allocator, retain dependencies and pin storage, and join all operations before exclusive Store teardown. Native macOS/Windows and actual runtime integration remain NOT_RUN. Full-file verification is intentional; no cache performance gain is claimed.
