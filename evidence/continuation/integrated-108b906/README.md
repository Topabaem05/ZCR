# Integrated source 108b906 — local restricted container

Exact tested source/tree, source/config/test-input manifests, driver/toolchain/Python and binary/log digests are in artifacts/report.json. Both modes build, contract validation, codec and actual CLI subprocess checks passed. The full registered suite remains FAIL: each mode reports 338 passed, 9 failed; all nine are broker AF_UNIX creation failures under this container policy. No failure is waived or converted to PASS. T12 has 24 passing cases alongside 41 T11 cases per mode. Native hosted Linux/macOS execution follows separately.

Captured storage archives preserve raw journal and fresh-child transcripts and history.json; capture is not an independent assertion of recovery correctness. Exact CLI fixture trees are archived, including local fixture Git state, to avoid nested repositories in the source tree. Test executables remain at the exact paths/hashes recorded in the report; they are not embedded in this package. Source was clean and unchanged over execution.

This checkpoint predates T16 admission integration. Production writes remain disabled; host supervisor, real kernel faults, macOS minimum-version/power-loss and actual client/model gates remain open.
