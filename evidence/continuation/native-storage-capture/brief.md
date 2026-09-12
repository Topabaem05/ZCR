# Native T12 raw evidence preservation

Integrator CI scope only: tools/ci/native.py, storage_capture.py, test_storage_capture.py. Existing native jobs discarded test-cache fixtures after runner shutdown. Preserve actual T12 case JSON, fresh-child transcripts and journal/forensic state in a bounded archive with file hashes and target/sentinel digests. Never archive fixture repository source or Git metadata; never follow fixture symlinks or block on special files. Preserve failure status and separate successful capture from runtime PASS. Missing fixtures must not claim execution. Existing T12 fixtures are read-only inputs for collector validation, not new tests of current runtime. No source/runtime/core/contract changes.

Validate real retained crash fixtures plus focused collector safety, bounded refusal, and missing-input cases. Native execution of the changed driver remains a later CI gate. No subagents; review read-only.
