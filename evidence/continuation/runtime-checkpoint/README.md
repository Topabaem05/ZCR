# Integrated read-only runtime checkpoint

Source b5face3: Debug and ReleaseSafe each pass 25 batch, 19 MCP/launcher and 15 scheduler tests; native CLI fixtures each pass18 checks including JSON schemas, exact UTF-8 byte counts, trusted info/global excludes, atomic replacement invalidation, and live session expiry.

Three native expired-token tests first failed with cancellation instead of deadline, then pass with the complete module suites. Initial batch fixture compilation correction is not counted as a behavioral RED.

`provenance.json` pins source/tree, every build input, toolchain, test/CLI binaries and logs. CLI manifests/transcripts are synthetic fixture data. The source review is separate from execution evidence. Actual host/Mac/model gates remain NOT_RUN.
