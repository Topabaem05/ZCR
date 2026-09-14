# docs/18 follow-up after PR #5 and the T10 diagnosis

Documentation and status only, no runtime source changes. This follow-up:

- marks the MC-004 deadline-test observation point as done by PR #5 (`96c2666`), with evidence in `evidence/T08/deadline-20260914/README.md`;
- records the diagnosed cause of the runtime-cache `IoFailure` under local CPU load. Discovery git calls exceeded the 5000 ms timeout and were reported as `IoFailure`. The T10 change is under review in PR #6, with evidence on its branch in `evidence/T10/git-timeout-20260914/`;
- regenerates `DESIGNBOOK.html`, `verification/report.json` and `MANIFEST.sha256`.

The T01 task manifest, authorization and preflight in [task/](task/) were issued before any edit. The scope report is generated on the committed tree.
