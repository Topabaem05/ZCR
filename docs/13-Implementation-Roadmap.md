# 13 · 구현 로드맵 · task/step 격리

## 1. 단계와 중간 제품

| 단계 | Task | 독립 검증 가능한 결과 | 다음 단계 gate |
|---|---|---|---|
| A. 기준선/계약 | T00–T03 | 계측 결과, 고정 schema, scope guard, budget allocator | toolchain/SDK spike + contracts freeze |
| B. 정확한 읽기 | T04–T08 | scalar read/files/search/batch + direct MCP | read-only correctness + real host 호출 |
| C. Mac/격리/쓰기 | T09–T12 | bounded GCD, worktree registry, single-file edit/recovery | cancellation/crash/fence 시험 |
| D. 재사용/다중작업 | T13–T16 | cache, watcher, explicit broker, adaptive governor | pressure/fairness/no cross-worktree leak |
| E. 이식/선택 가속 | T17–T20 | Linux, optional Windows/SIMD/outline | baseline 의미 동일 |
| F. 증거/출시 | T21–T25 | harness, telemetry, host routing, packaging, release review | correctness/security/perf evidence |

단계는 관리상 묶음이며 병렬 가능 여부는 `tasks/INDEX.md`의 실제 dependency DAG를 따른다. T21 시험 하네스는 초기부터 일부를 만들고 T21 통합 시 baseline/hardware 행렬을 완성한다. Windows T18, parser T20는 optional이며 지원하지 않는 기능은 광고하지 않는다.

## 2. 구현자에게 주는 고정 규칙

`AGENTS.md`와 각 task의 owns/consumes/produces가 작업 범위다. task당 전용 branch/worktree를 사용한다. task가 다른 task의 interface를 바꾸고 싶다면 source를 바로 수정하지 말고 `handoffs/interface-change.json` 제안을 남겨 통합자 승인을 받는다.

`build.zig`, `build.zig.zon`, `src/core/types.zig`, `contracts/*`, CI runner, 최상위 policy는 **통합자 소유**다. 병렬 작업자는 자기 모듈과 자기 tests만 변경하고 module export를 handoff한다. 같은 파일의 다른 줄이라는 이유로 동시 소유를 허용하지 않는다.

## 3. 모든 task의 Step 규약

- **S01 Scope:** base/head, clean 상태, allowed paths, schema digest, dependency evidence 확인.
- **S02 RED:** task-specific fixture/test를 작성하고 의도한 assertion 또는 미구현 symbol로 실패함을 확인.
- **S03 Implement:** 자신의 모듈만 최소 구현. placeholder success/skip test로 통과시키지 않는다.
- **S04 GREEN:** unit·fault·property test를 실행하고 결과와 binary provenance 저장.
- **S05 Integrate:** contract/ownership guard, 인접 모듈 regression, Debug/ReleaseSafe 확인.
- **S06 Handoff:** changed files·test evidence·remaining gates를 기록하고 리뷰 가능한 commit 생성.

한 Step가 끝나면 `state/task-step.json`에 결과를 기록한다. 다음 모델 세션은 이전 모델의 기억이 아니라 그 파일과 승인된 source commit을 읽고 이어간다. check box를 체크했어도 테스트 증거가 없으면 완료로 간주하지 않는다.

## 4. 병렬 개발 허용 예

T01 계약이 고정된 후 T02 policy와 T03 budget은 서로 다른 모듈에서 병렬 가능하다. T04 fs engine은 둘 모두의 공개 interface를 소비한다. T09 scheduler와 T10 registry는 T01/T03 또는 T02 후 독립적으로 진행할 수 있으나 build integration은 단일 통합자만 수행한다.

T11 edit와 T12 recovery는 계약상 이어지므로 recovery를 추정 구현해 별도 storage 형식을 만들지 않는다. T13 cache는 T10 workspace identity가 고정된 뒤에만 mutable association key를 설계한다. T15 broker는 T08 framing과 T09 scheduler, T10 registry, T13 shared accounting을 소비한다.

## 5. Merge 절차

통합자는 먼저 task baseline과 current integration branch 차이를 확인한다. 자동 stash/reset 없이 새로운 integration worktree에서 후보 commit을 적용한다. source·contracts hash를 갱신한 뒤 dependent tests를 다시 실행한다. conflict는 소유자가 해결한 새 commit으로 받고, 통합 과정에서 의미 변경한 patch를 원래 task PASS로 대체하지 않는다.

허용 파일 밖 수정, 테스트 삭제/skip, generated artifact를 통한 우회, worktree 외부 write, 의존성 무단 추가는 즉시 reject다. 이름만 바뀐 rename/delete와 untracked file도 검사한다.

## 6. 완료 정의

각 task는 구현 파일 + 테스트 파일 + 증거 + interface handoff + scope 검사 결과가 있어야 COMPLETE다. 미실행 platform test는 NOT_RUN으로 남기며 “compile 성공”을 “지원 완료”로 승격하지 않는다. T25는 optional task 미선택 상태를 허용하되 final capabilities와 support matrix에 정확하게 반영한다.
