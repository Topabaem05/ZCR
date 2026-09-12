# T16 pressure-admission budget prerequisite review

Reviewed 2026-09-12. Bounded source range: `6864418..40dd152` in `/workspace/scratch/3f4ab65dfb82/ZCR-work`; final source commit `40dd152685bbb3bc74a78776fb801c0f3037e44a`, tree `3db55d5c12ce1e1efb3e2836bf844b0d4081ded9`; RED commit `c62c416558cf5121866f2cde013b62cceaaaa45a`. No repository source was edited and no test suite was rerun by this reviewer.

**Spec verdict: REQUEST CHANGES.** The prerequisite correctly narrows future byte/FD/CPU admission under the Budget lock, retains already-owned credit until release, refuses cap values above every immutable hard-cap dimension, and makes aggregate checks overflow-safe. R1 misclassifies a temporary pressure refusal for output credit, contrary to the Budget contract and docs/05 admission semantics.

**Quality verdict: REQUEST CHANGES.** R1 is a user-visible error and retry-policy defect. No other blocking implementation or evidence-provenance finding was found in the finite scope.

## R1 — P2: temporary output pressure is reported as a permanent output-shape error

Location: `src/memory/budget.zig:139` at reviewed source `40dd152`, with the method contract at lines 127-129 and wire retry policy in `src/core/errors.zig:67-89`.

After `setAdmissionCaps` lowers only `output_bytes`, `reserve` returns `OutputBudgetExceeded` whenever a request exceeds that temporary admission value, even when the request remains within the immutable hard output cap. The method contract reserves `OutputBudgetExceeded` for output larger than the whole output share. A request that does not fit *right now* must return `ResourceExhausted`. The distinction reaches clients: `E_OUTPUT_BUDGET` is nonretryable and tells the caller to narrow the result, while `E_RESOURCE` is retryable and can succeed after pressure recovery.

Concrete case: construct hard caps with `output_bytes = 32`, set admission caps with `output_bytes = 16`, then reserve a cost with `output_bytes = 17`. Current line 139 returns `OutputBudgetExceeded`; restoring admission caps to the hard caps would make the identical request admissible. This is temporary capacity refusal, not a request whose output can never fit.

Remove the admission-cap-specific `OutputBudgetExceeded` branch and let the locked remaining-credit comparison return `ResourceExhausted`; retain the pre-lock hard-cap check for true whole-share violations. Add one focused regression that checks the temporary refusal is `ResourceExhausted` and that the same request succeeds after restoring admission caps.

## Verified source behavior

- `setAdmissionCaps` rejects any requested byte, FD, CPU, or output dimension above `self.caps` and publishes the accepted composite cap while holding the same lock used by `reserve` and `admissionCaps`. Runtime hard caps are documented immutable; the only direct hard-cap mutations found are quiescent test-fixture controls.
- Lowering admission caps below live usage does not alter `used` or the owned reservation. Saturating remaining-credit subtraction rejects positive new demand until release brings usage within the lower cap. Release continues to debit the original reservation values, so existing ownership is not revoked.
- Replacing `used + cost > cap` with `cost > cap -| used` prevents byte/output overflow and also keeps FD/CPU accumulation within their native integer maxima. `ResourceCost.totalBytes` already rejects overflow among byte fields.
- The implementation and tests are confined to `src/memory/budget.zig` and `tests/t03_test.zig`; `git diff --check` passes. No governor/controller, host signal watcher, thermal/LLM policy, hysteresis, or runtime wiring is present or claimed. Those remain T16 work and are outside this prerequisite verdict.

## Evidence verification

The provenance source commit and tree match Git. All 59 recorded source/build/config SHA-256 values match the current bytes and the two changed-file hashes also match the exact blobs at `40dd152`. The RED log hash matches and shows the expected missing-`setAdmissionCaps` compile failure at `c62c416`, while T13 still passes 14/14.

Both final combined-log hashes, all four installed-binary hashes, and the Zig toolchain hash match `provenance.json`. The Debug and ReleaseSafe logs each record T03 16/16 plus T13 14/14, 30/30 total, with exit 0. These are inspected implementer runs, not reviewer reruns. Their evidence supports the tested byte/live-credit/CPU/overflow cases, but the tests do not cover R1's temporary-output error classification.
