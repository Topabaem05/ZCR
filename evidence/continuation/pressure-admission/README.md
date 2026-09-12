# T16 shared admission prerequisite

Source40dd152 adds mutex-protected admission caps within immutable hard caps. Pressure only limits future reservations; existing owners retain credit until release. Aggregate subtraction prevents overflow and handles usage above a lowered cap. No governor, signal watcher or runtime pressure wiring is claimed by this prerequisite.

Two new tests plus the current T03/T13 regressions pass30/30 in Debug and ReleaseSafe. Required-API RED was observed at c62c416. Provenance records exact source/build/config, binaries, commands and logs. Independent review requests one correction: temporary output-credit pressure must return retryable ResourceExhausted, not the immutable output-limit error. This prerequisite is not approved yet.
