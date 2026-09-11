# 02 · Software Design Description (SDD)

## 1. 범위와 품질 속성

ZCR은 로컬 파일 도구 실행기다. 데이터 평면은 경로 해석, 읽기, 검색, 안전한 파일 교체이고 제어 평면은 권한, task/workspace registry, scheduling, memory budget이다. **정확성 → 격리 → bounded resource → 관측성 → 속도** 순서로 trade-off를 해결한다.

## 2. 프로세스 모델

### 2.1 Standalone

```text
Codex/Claude → MCP stdio → zcr process
                              ├ protocol / policy / workspace
                              ├ scheduler / budget
                              └ filesystem / search / edit
```

한 호스트 세션이 하나의 long-lived 자식 프로세스를 소유한다. 프로세스 시작 시 승인된 workspace와 task manifest를 바인딩한다. request가 root를 마음대로 바꾸지 못한다. 프로세스 종료 시 미커밋 임시 작업을 중단하고 journal을 남긴다. stdio가 끊어져도 rename 이후 상태를 거짓으로 실패 처리하지 않는다.

### 2.2 Broker

동일 사용자·동일 보안 도메인의 세션을 묶기 위해 운영자가 `zcr broker serve`를 명시적으로 시작한다. 여러 `zcr mcp --broker` bridge는 동일 바이너리의 별도 역할이다. broker가 workspace actor·cache·예산을 소유한다. 기본은 Unix domain socket, Windows 확장에서는 ACL로 제한한 named pipe다. TCP listener는 v1에 없다.

서로 다른 sandbox/policy를 쓰는 세션은 같은 broker라도 capability domain을 분리하며, 더 넓은 호스트 권한을 대리 제공하지 않는다. 이 보장이 불가능하면 standalone을 사용한다. MCP 연결만으로 기존 host 승인 경계가 자동 상속된다고 가정하지 않는다. [R12](../references/SOURCES.md#R12)[R13](../references/SOURCES.md#R13)

### 2.3 단일 예산 소유자

broker의 group budget은 broker+bridge+helper 전체를 포함한다. 외부 `rg`·parser helper·LSP를 실행하면 그 메모리도 별도로 집계한다. 여러 standalone 사이에는 중앙 enforcement가 없으므로 “전체 합계 보장”을 표시하지 않는다. 동시에 여러 standalone을 쓸 때는 사용자가 프로세스별 cap을 나누거나 broker를 선택한다.

## 3. 컴포넌트

| 컴포넌트 | 책임 | 소유 데이터 | 금지되는 의존성 |
|---|---|---|---|
| Transport | framing, handshake, timeout, output | connection buffer | 직접 파일 수정 |
| Dispatcher | tool→typed request, 응답 형식 | request envelope | repo 설정 실행 |
| Policy | root/task/operation 허용 검증 | immutable policy snapshot | 콘텐츠로 권한 변경 |
| Workspace Registry | root handle, git identity, epoch | workspace actor | process-wide chdir |
| Admission | 메모리·FD·CPU·output 예약 | global counters | blocking worker semaphore |
| Scheduler | per-task 공정성, chunk dispatch | bounded queues | 임의 thread 증설 |
| FS Engine | handle-relative read/create/replace | 단기 FD | 경로 문자열만 신뢰 |
| Search Engine | literal scan, context coalescing | chunk state | 무제한 result vector |
| Cache | immutable bytes/line index/outline | content-addressed entry | mutable worktree 공유 |
| Edit Coordinator | 검증·journal·단일파일 교체 | mutation ledger | 자동 merge/force overwrite |
| Watcher | 이벤트→dirty generation | event cursor | authoritative version 판정 |
| Telemetry | 지연·자원·오류 계수 | bounded ring | 기본 로그에 소스 원문 |

## 4. 핵심 불변조건

- **INV-01:** request에는 승인된 `SessionContext`가 붙고, `WorkspaceId`를 모델 인자만으로 선택하지 않는다.
- **INV-02:** mutable entry key에는 workspace incarnation과 generation이 포함된다.
- **INV-03:** allocator 예약 성공 전 대형 입력 decode·파일 buffer·parser tree를 만들지 않는다.
- **INV-04:** callback이 살아 있는 동안 그 context와 arena를 해제하지 않는다.
- **INV-05:** registry/global lock을 가진 채 파일 I/O, subprocess wait, 응답 flush를 하지 않는다.
- **INV-06:** commit point 전에 cancellation을 처리하고, commit 이후에는 applied 여부를 보고한다.
- **INV-07:** 반환 결과의 `complete`, `truncated`, `consistency`, `coverage`를 조작해 빠르게 보이지 않는다.
- **INV-08:** 정확한 reference와 구문상의 이름 출현 후보를 구분한다.
- **INV-09:** 실행 중 task가 바뀌면 새 authority·scope·epoch를 바인딩하며 기존 request를 재사용하지 않는다.
- **INV-10:** 사용자 미승인 dependency, 외부 프로세스, 네트워크를 hot path에 추가하지 않는다.

## 5. 상태와 lifetime

프로세스 → workspace actor → session → request → job의 계층을 사용한다. 프로세스는 장기 allocator와 control plane을, workspace는 index generation을, request는 결과 arena를 소유한다. 병렬 job은 각각 scratch를 가진다. 여러 worker가 같은 ArenaAllocator를 동시에 사용하는 설계는 금지한다.

request 종료는 `children drained → output lifetime complete → arena reset/deinit → reservation release` 순서다. `cancel requested`와 `cancel completed`를 다른 상태로 취급한다. arena reset으로 모든 메모리가 곧바로 OS에 반환된다고 가정하지 않는다. [R03](../references/SOURCES.md#R03)

## 6. 오류 모델

계약 오류, 권한 오류, 리소스 오류, 파일 변경 충돌, I/O 오류, 내부 무결성 오류를 구분한다. `OutOfMemory`는 정상적으로 전달할 수 있는 오류이며, write에서는 커밋 전 무변경 종료한다. 내부 invariant 실패는 해당 workspace를 quarantine하고 가용한 최소 오류만 반환한다. 안전하지 않은 데이터로 작업을 계속하지 않는다.

## 7. 확장 규칙

v1 protocol schema version은 `zcr/1`이다. 필수 필드의 의미 변경은 major version이다. 추가 기능은 capabilities로 노출하고 지원하지 않는 regex/parser/snapshot mode는 명확히 `E_UNSUPPORTED`를 낸다. 기존 tool과 이름을 같게 만들어 내장 Read를 몰래 가로채지 않는다.

## 8. 의존성 전략

Zig standard library + 운영체제 C API가 core다. Zig 0.16의 `std.Io`는 명시적으로 전달하되, `Io.Evented/Dispatch/Uring`을 안정 경로에 끌어오지 않는다. macOS GCD adapter는 public C ABI를 통해 별도로 구현할 수 있다. 시스템 라이브러리까지 없는 “무의존 바이너리”라고 부르지 않는다. [R02](../references/SOURCES.md#R02)

프로젝트 디렉터리 구조와 타입 계약은 [17번 문서](17-Data-Model-and-Interfaces.md)를 기준으로 한다.
