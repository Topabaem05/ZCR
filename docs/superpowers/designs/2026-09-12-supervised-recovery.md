# Supervised recovery contract and remaining integration work

This records the continuation decisions for T12. Source `1f12553` has passed its local Linux write group (65 tests in each mode) and is under independent review. This document does not enable production writes or establish a platform support claim.

## Trusted restart continuity

A restart creates a fresh runtime workspace ID and boot nonce. Old capabilities and writer leases remain invalid. The trusted supervisor retains root, worktree Git directory, Git common directory and approved private journal-state directory handles across writer death. It verifies the current canonical paths, Git marker, base commit, policy and security domain against those retained objects before issuing the recovery grant through a protected channel.

The supervisor also retains each pending publication's parent, temporary file and original target handles, with an explicit absent target for create. These witnesses are bound to the exact prepared operation. Matching inode numbers, birth times or file contents alone cannot prove continuity after deletion and reuse. Missing or mismatched required witnesses quarantine pending recovery. No continuity grant, capability or token belongs in argv, general environment variables, source files or ordinary untrusted JSON from a client.

Cold restart without sufficient retained evidence remains quarantined. Implementing the production supervisor and its protected ownership/lifecycle is a required integration task. Current subprocess tests establish only the fixture supervisor that they execute.

## Historical outcomes and current files

A fully authenticated COMMITTED or ABORTED record is an immutable historical outcome. A later legitimate operation on the same path must not invalidate it. Historical replay verifies namespace, private-state, task, policy and domain bindings; it does not promise that the current file still has the old operation's bytes or identity.

Pending PREPARED/APPLIED and unresolved entries still require current filesystem reconciliation and the approved publication witnesses. Recovery never reapplies a patch, publishes a leftover temporary file, rolls back a target or grants a new writer lease. Every new operation separately validates current authority, version and fence.

Never infer publication order from directory iteration, key hashes or PREPARED generation plus one. An original APPLIED record retains its actual guard generation. A PREPARED-only publication reconciled under a trusted grant uses the separately identified recovered-generation convention in the fresh registry.

For a terminal prefix followed only by a bounded incomplete suffix, preserve the exact suffix with the required file/directory persistence barriers and normalize the valid prefix before reporting replayable success. If preservation cannot be established, report uncertainty and retain quarantine. Complete corrupt frames and complete UNCERTAIN records cannot be discarded as incomplete tails. Recovery reporting and receipt lookup must agree.

These decisions cost stricter supervisor requirements and separate current-file validation. They avoid treating a reused inode as authority or turning a historical successful write into a false failure after a later write.

## Capacity and evidence limits

The current store retains terminal receipts for its lifetime and does not evict them. Conservative worst-case journal and forensic-tail reservation allows at most 255 operations under the default 128 MiB storage bound, before the separate 10,000-entry ceiling. This is a bounded implementation, not evidence that 10,000 entries fit. Long-running service capacity/reclamation needs its own reviewed design preserving receipt retention and borrowed lifetimes.

Local evidence includes actual writer SIGKILL, fresh exec recovery twice, identity/corruption negatives, failed recovery persistence, sequential operation history and report/lookup agreement. SIGKILL proves process-crash behavior only. Genuine kernel ENOSPC, kernel short-count/fsync failure, Mac filesystem recovery, actual host supervisor integration and power-loss qualification remain open. Production write capability stays hard-disabled until the applicable gates pass.

The native CI collector preserves case JSON, child pipe transcripts, journal/forensic bytes and target/sentinel digests from executed fixtures. A successful capture does not establish a successful runtime test; command results, the exact source/binaries, full matrix and raw records must be checked together.
