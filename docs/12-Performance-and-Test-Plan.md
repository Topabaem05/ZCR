# 12 · 성능 목표 · 구현 테스트 · 증거 계약

## 1. 무엇을 빠르게 만드는가

최적화 대상은 model decode 속도 자체가 아니라 **동일한 정확한 변경을 완료하는 critical-path elapsed time**이다.

```text
T_task = model compute + critical-path tool wait + transport/dispatch
       + validation/build/test + conflict/retry + human approval
```

겹쳐 실행된 tool 시간을 단순 합해서 전체 시간이라고 하지 않는다. trace의 dependency edge로 critical path를 계산한다. `tok/s`만 빠른 모델이 기다리는 문제이므로 `model_blocked_on_tools_ms`, 모델에 전달된 tool bytes/tokens, 불필요한 후속 Read 수가 핵심이다.

설명용 계산: 전체 시간의 40%가 도구 대기이고 그 부분을 4배 가속하면 `1 / (0.6+0.4/4)=1.43배`다. 이는 Amdahl식 산술 예제이지 프로젝트 실측이 아니다. decode가 800 tok/s라고 해서 tool latency를 800분의 1초로 제한해야 하는 것은 아니다. 실제 dependent call 빈도와 출력 token 양이 기준이다.

## 2. 비교군

| ID | 구성 | 공정 비교 원칙 |
|---|---|---|
| B0 | 실제 host 내장 Read/Grep/Glob/Write | 구현 언어를 추정하지 않고 실제 trace 계측 |
| B1 | rg + fd 또는 git file list + 범위 read | 버전 고정, 동일 ignore/순서/범위/출력 |
| B2 | ZCR scalar, no cache, bounded threaded | 정확성 기준 구현 |
| B3 | ZCR GCD + immutable cache | B2 대비 scheduler/cache 효과 분리 |
| B4 | B3 + SIMD | kernel만 별도 비교 |
| B5 | broker 다중 세션 | bridge 포함 전체 메모리/energy |

비교군 코드를 일부러 느린 Python 전체-file wrapper로 만들지 않는다. Codex/Claude의 내장 도구가 항상 Python이라는 전제를 두지 않는다. backend-only, transport-inclusive, agent E2E를 별도 표로 보고한다. [R12](../references/SOURCES.md#R12)[R13](../references/SOURCES.md#R13)

## 3. 초기 합격 목표 — 아직 실측 아님

대표 성능 anchor는 **Apple M1급 8 GiB / local APFS / AC 전원**과 **x86-64 4 physical core 이상 / 16 GiB / local NVMe Linux**다. 실제 SKU/OS/파일시스템을 보고서에 적어야 비교가 유효하다.

| 지표 | 목표 또는 gate | 조건 |
|---|---|---|
| standalone idle footprint | ≤24 MiB 목표 | workspace/parser 미적재, system library 포함 |
| group memory | 선택 profile cap 안에서 안정화 | footprint 관측, system overhead는 소프트 목표 |
| warm process launch p95 | ≤25 ms 목표 | 이미 설치·승인된 로컬 바이너리, OS cache warm |
| direct stdio protocol overhead p95 | ≤2 ms 목표 | 4 KiB round trip, same host, no source I/O |
| read 200 lines p95 | ≤3 ms 목표 | ≤64 KiB 파일, OS cache warm, no index miss |
| batch 8×small read p95 | ≤8 ms 목표 | output ≤64 KiB, warm, concurrency cap 유지 |
| complete literal search | B1 rg 대비 p95 ≤1.20배 | 정확히 같은 결과·filter·sort·warmth |
| cache-on repeated workflow | B2 tool critical path ≥20% 감소 목표 | 같은 정답 결과와 출력 budget |
| agent E2E | paired median ≥10% 개선 목표 | task 정답·승인 범위·모델 설정 동일 |
| concurrent foreground fairness | 8-task p95가 isolated 대비 ≤3배 목표 | 같은 total core/메모리 예산, burst trace |
| cancellation acknowledgement p95 | ≤20 ms 목표 | CPU chunk/queue 경로, blocking syscall 제외 |
| local LLM decode 영향 | baseline 대비 ≤5% 저하 목표 | 동일 모델·context·sampler, 안정상태 |
| correctness/scope corruption | 0건 | 모든 지원 플랫폼 release gate |

고정 숫자 미달은 측정 결과를 숨길 사유가 아니다. 무엇이 병목인지 trace로 판단한다. 단, 권한 누출·잘못된 파일 수정·출력 거짓 completeness는 성능과 무관하게 출시 차단이다. empty idle footprint와 200k-file index footprint를 같은 항목으로 광고하지 않는다.

## 4. Corpus 행렬

| corpus | 형태 | 목적 |
|---|---|---|
| C-small | 2,000 files / 총 20 MiB / 작은 source 중심 | startup, metadata, tiny files |
| C-medium | 20,000 files / 200 MiB / 언어 혼합 | 표준 repository |
| C-large | 200,000 files / 2 GiB / nested ignore·generated files | streaming path budget |
| C-edge | giant line, CRLF/BOM, Unicode, symlink, hardlink, unreadable | 정확성·보안 |
| C-worktrees | 같은 repo의 4/8 worktrees + 서로 다른 dirty bytes | 공유cache 및 오염 방지 |
| C-llm | C-medium + 고정 local model decode/prefill trace | unified memory·bandwidth 공존 |

corpus 생성 seed, file size 분포, path 분포, 내용 hash를 manifest에 남긴다. 공개 repository를 사용할 때도 commit과 ignore policy를 고정한다. 2 GiB corpus 전부를 index buffer로 들고 있어야 하는 구현은 8 GiB profile에서 불합격이다.

## 5. 실험 절차

1. 환경 정보와 baseline manifest를 고정한다. machine, OS build, compiler flags, SDK, binary hash, corpus hash, power/thermal 상태를 기록한다.
2. 정답 oracle을 생성해 모든 candidate의 match byte spans·file set·patch 결과를 비교한다.
3. warm 실험은 dry-run 5회 이후 동일 조건 30회 이상 실행한다. cold 실험은 OS cache 상태를 통제할 수 있을 때만 cold로 부른다.
4. macOS에서 단순 cache file 삭제나 첫 실행을 “완전 cold page cache”라고 주장하지 않는다. 통제 못 하면 cache state=unknown으로 표기한다.
5. candidate 실행 순서를 AB/BA로 교차해 thermal/time bias를 줄인다. p50/p95/max, bootstrap CI, effect size를 보고한다.
6. 실제 모델 E2E는 최소 20개 독립 coding task, task별 paired runs 3회 이상을 초기 목표로 한다. 모델 nondeterminism 때문에 성공률/수정량/round trips도 같이 비교한다.
7. 성능 gate 미달 시 기능을 삭제하기 전에 trace를 분해한다. B0/B1보다 기능이 많아진 비용은 별도 표시한다.

## 6. 메모리·전력 측정

macOS에서는 physical footprint를 주 지표로, RSS·virtual size·allocator current/peak를 보조 지표로 기록한다. Linux는 RSS/PSS와 cgroup memory.current 및 child process 사용량을 함께 기록한다. ru_maxrss는 peak 성격과 플랫폼 단위 차이를 분리한다. VM mapping size만으로 “메모리 0”이라 하지 않는다.

power/energy는 Apple Instruments 등 실제 사용할 수 있는 장비·권한에 따라 가능 여부를 기록한다. 정확한 per-process joule가 없으면 CPU time/thermal/QoS/whole-device power를 proxy로 명시하고, 측정 안 한 energy 수치를 만들지 않는다. privileged 측정 명령은 사용자 동의 없이 요구하지 않는다.

## 7. 기능/실패 테스트

`tests/catalog.json`에 각 test의 Given/When/Then, owner task, 요구사항을 기록한다. 분류는 IO/FS/SR/BA/WR/MC/IS/BR/WA/OB/AS/SC/ME/PF/DV다. unit, property, fuzz, crash, integration, hardware tests를 구분한다.

핵심 property는 scalar/SIMD byte-span 동등성, patch identity, no-overwrite create, workspace identity non-aliasing, arena lifetime, hard budget accounting, cancellation drain이다. fault injector는 allocation N번째 실패, short read/write, EINTR, ENOSPC, watcher overflow, SIGKILL 가능한 환경을 제어한다.

## 8. 테스트 실행 계약

구현 후 CLI는 다음 명령을 제공한다. 현재 ZIP은 이 명령을 구현한 프로젝트가 아니므로 성공했다고 표시하지 않는다.

```sh
zig build test -Dtest-group=io -Doptimize=Debug
zig build test -Dtest-group=security -Doptimize=ReleaseSafe
zig build test -Dtest-id=WR-005 -Dfault-injection=true
zig build bench -Dcorpus=C-medium -Dvariant=scalar -Doptimize=ReleaseFast
zig build verify-contracts
```

T01은 위 옵션의 실제 build runner를 먼저 정의하고, 이후 task는 별도 runner 형식을 발명하지 않는다. 최소 unit group은 io,fs,search,batch,write,mcp,isolation,broker,watch,observe,ast,scheduler,memory,perf,dev,security다.

## 9. Stop / continue 기준

B2가 기능 정확성을 통과하지만 rg보다 느리면 SIMD에 바로 뛰어들지 말고 syscall·allocation·output 비용을 분해한다. 전체 task에서 tools가 5% 미만이면 저수준 최적화의 사업적 우선순위를 낮추되 Zig 실험 자체는 명시적인 연구 목표로 유지할 수 있다. E2E 개선 없이 microbenchmark만 좋아지면 기본 설정으로 승격하지 않는다.

## 10. 결과 보존

`bench/results-template.json`은 status=not_run이며 모든 실제 측정값은 null이다. test result에는 source commit, binary SHA-256, task/step, machine ID, configuration digest, timestamp, command, exit code, stdout/stderr artifact hash가 필수다. 다른 worktree의 binary로 시험한 결과를 현재 commit의 PASS로 재사용하지 않는다.

## 11. 모델 입력 비용

tool 결과뿐 아니라 discovery schema/description의 token 수와 첫 연결 비용도 기록한다. provider가 schema를 cache하는지, text와 structured content를 중복 주입하는지는 host trace로 확인한다. 작은 결과만 반환해도 schema overhead가 더 커질 수 있으므로 총 model-input cost를 함께 비교한다.
