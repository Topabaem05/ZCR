# docs/18 follow-up after PR #5 and the T10 diagnosis

Documentation and status only, no runtime source changes. This follow-up:

- marks the MC-004 deadline-test observation point as done by PR #5 (`96c2666`), with evidence in `evidence/T08/deadline-20260914/README.md`;
- records the diagnosed cause of the runtime-cache `IoFailure` under local CPU load. Discovery git calls exceeded the 5000 ms timeout and were reported as `IoFailure`. The T10 change is merged in PR #6 (`9c94517`), with evidence in `evidence/T10/git-timeout-20260914/`;
- keeps PR #5's Linux and Intel Mac runtime `NOT_RUN` in bundled evidence. That PR's native CI run 34796451231 reported success, but its artifacts are not bundled here;
- regenerates `DESIGNBOOK.html`, `verification/report.json` and `MANIFEST.sha256`.

The T01 task manifest, authorization and preflight in [task/](task/) were issued before any edit. Fence 1 (`manifest-fence1.json`, base `c5c3e80`) was audited by the scope report committed at `a4047ea`. After main (`9c94517`, PR #6) was merged into the branch at `53c1703`, fence 2 moved the base to `9c94517` with the same paths and limits. `task/merge-audit.json` records that the merge added nothing outside the write paths beyond main. The scope report is generated on the committed tree against the fence-2 base.
