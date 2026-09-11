# 16 · 외부 근거 · 아직 통과하지 않은 게이트

## 1. 확인된 사실과 설계의 구분

2026-09-11에 열람한 Zig 공식 다운로드는 0.16.0을 stable release로 제시한다. 본 문서는 0.17 개발 버전을 추적하지 않는다. std.Io 변경과 experimental backend는 공식 release notes로 확인했다. [R01](../references/SOURCES.md#R01)[R02](../references/SOURCES.md#R02)

Apple의 M5 Pro/Max 발표는 18-core 구성에서 super 6개와 새로운 performance 12개를 설명한다. 따라서 기존 P/E 고정 모델이나 “super core는 없는 용어”라는 설명은 맞지 않는다. 제품 전체 lineup을 조사한 것은 아니므로 “모든 최신 Mac의 구성”으로 일반화하지 않는다. [R04](../references/SOURCES.md#R04)

Apple scheduling 자료는 QoS/GCD와 heterogeneous core 활용을 설명한다. 이는 특정 요청의 실제 실행 core를 증명하는 benchmark가 아니다. T00/T09에서 SDK와 실행 환경을 확인해야 한다. [R05](../references/SOURCES.md#R05)[R06](../references/SOURCES.md#R06)

## 2. Gate 등록부

| Gate | 확인할 내용 | owner | 통과 증거 | 미통과 시 결정 |
|---|---|---|---|---|
| G01 | Zig0.16 + 실제 Mac SDK compile/link/run | T00 | minimal executable, build log | toolchain blocker 해결 전 안정 API 추정 금지 |
| G02 | GCD C callbacks/QoS/lifetime | T09 | stress+cancel+teardown tests | bounded threaded baseline |
| G03 | memory-pressure/thermal/low-power API availability | T00,T16 | SDK declarations + runtime feature probe | unknown signal + static conservative caps |
| G04 | perflevel sysctl keys/meaning | T00,T09 | hardware capability dump | total CPU 기반 보수 정책 |
| G05 | APFS edit metadata/no-replace/durability | T11,T12 | ACL/xattr/crash tests | 해당 write capability off |
| G06 | Git worktree command flags/identity | T00,T10 | actual Git version fixture | no Git shared-cache optimization |
| G07 | MCP version negotiation and output profile | T08,T23 | raw transcript + host behavior | text-only supported version |
| G08 | Codex/Claude 실제 tool 선택 | T23 | actual tool trace | routing guidance 수정, 자동 대체 주장 금지 |
| G09 | memory caps and total process footprint | T03,T15,T16 | pressure/broker measurements | lower concurrency/cache, cap semantics 수정 |
| G10 | x86 SIMD portability | T17,T19 | baseline CPU + AVX runner results | scalar path |
| G11 | macOS11 legacy compatibility | T00,T24 | real Intel Mac run | unsupported 표시 |
| G12 | E2E improvement and model coexist | T21,T23 | paired run data/CI | experimental profile 유지 |
| G13 | host sandbox와 broker capability 교집합 | T15,T23 | denied-root/privilege tests | standalone-only |
| G14 | Windows filesystem/pipe semantics | T18 | actual Windows integration tests | Windows capability 미출시 |

## 3. 외부 API 검증 수준

Apple의 일부 API reference는 JavaScript 렌더링 문서로 API 존재만 확인할 수 있었다. `DispatchSourceMemoryPressure`, `ProcessInfo.thermalState`, `isLowPowerModeEnabled`의 **정확한 availability attribute와 Zig binding compile 여부는 이 문서 작성 과정에서 검사하지 않았다.** SDK gate를 통과하기 전 최소 OS에서 작동한다고 단정하지 않는다. [R09](../references/SOURCES.md#R09)[R10](../references/SOURCES.md#R10)[R11](../references/SOURCES.md#R11)

문서 작성 환경에는 Mac kernel/Apple Silicon/대상 Zig toolchain이 없다. 따라서 latency, RSS, core placement, physical energy, actual Codex/Claude registration, edit crash recovery는 **미실행**이다. 패키지 검증은 파일·schema·링크·task graph·정적 일관성에 한정된다.

## 4. 이전 대화에서 수정한 판단

Zig를 선택한다고 Rust보다 자동으로 빠르거나 memory-safe해지는 것은 아니다. Mac hardware scheduling은 언어가 아니라 OS/API/workload의 결과다. `std.Io.Dispatch` 존재와 안정성은 다른 주장이다. JSON/MCP를 선제적으로 binary로 바꾸는 것도 결정된 이득이 아니다.

arena reset, mmap, watcher, worktree, atomic rename 각각의 장점을 사용하되 잘못된 보장을 붙이지 않는다. 특히 arena reset은 OS 반환과 같지 않고, watcher는 snapshot이 아니며, worktree는 공용 Git metadata와 OS 권한까지 분리하지 않는다. [R03](../references/SOURCES.md#R03)[R08](../references/SOURCES.md#R08)[R16](../references/SOURCES.md#R16)
