# 17 · 모듈 경계 · 데이터 모델 · 인터페이스

## 1. 예정 source tree

```text
src/
  main.zig                       # CLI bootstrap (integrator)
  core/{types,limits,errors}.zig  # frozen public types
  protocol/{mcp,framing,codec}.zig
  policy/{capability,paths,scope}.zig
  memory/{budget,arena,accounting}.zig
  fs/{read,traverse,ignore,metadata,edit}.zig
  search/{literal,context,scalar,dispatch,simd_arm64,simd_x86}.zig
  batch/read.zig
  scheduler/{admission,queue,executor}.zig
  workspace/{registry,identity,lease}.zig
  storage/{journal,recovery,receipts}.zig
  cache/{content,lines,association}.zig
  watch/{core,darwin,linux}.zig
  broker/{server,bridge,auth}.zig
  governor/{controller,pressure}.zig
  platform/{interface,darwin,linux,windows}.zig
  parser/{outline,treesitter}.zig
  observe/{metrics,health,trace}.zig
  host/routing.zig
c/darwin_shim.{h,c}               # public C/Foundation/GCD boundary
```

위 파일은 **계획된 경로**이며 ZIP에 미구현 source scaffold를 넣어 실행 가능한 것처럼 꾸미지 않는다. task 문서에 존재하는 create/modify 경로가 이 경계를 구체화한다.

## 2. 안정 논리 타입

아래는 **언어 독립 인터페이스 표기**다. `Result<T,E>`/`Owned<T>`/`Borrow<T>`는 의미 설명이며 Zig에서 그대로 compile되는 generic 선언이 아니다. T01이 Zig 0.16의 error union/slice/allocator 패턴으로 단일 표현을 고정한다.

```text
WorkspaceId = { registry_uuid: UUID128, incarnation: UUID128 }
ContentHash = SHA256[32]
SessionContext = { session_id, security_domain, policy_digest,
                   bound_workspace, bound_task, capability_handle }
TaskContext = { task_id, base_commit?, scope_digest, fence:u64, expires_at }
FileVersion = { workspace_id, file_id, generation:u64,
                size:u64, mtime_ns:i128, sha256:optional<ContentHash> }
ByteSpan = { start:u64, end:u64 }           // [start,end)
LineRange = { first:u32, count:u32 }       // first >= 1
Reservation = move-only { budget_id, bytes:u64, fd:u16,
                          cpu:u8, output:u64, released:bool }
JobEnvelope = owned { request_id, context, cancel_ref,
                      scratch_reservation, callback, qos_intent }
Receipt = { id, op_digest, applied:bool, durable:bool,
            old_hash?, new_hash?, generation, error? }
```

수명 규칙: `Borrow`는 호출의 sync 범위만 유효하다. 비동기 callback에 전달하는 것은 `Owned JobEnvelope`이며 parent arena의 짧은 slice를 무보호로 보관하지 않는다. 모든 u64 size/offset 덧셈과 u32 index 변환은 overflow 검사한다.

`Cancel`은 공유 atomic 취소 flag와 선택적인 monotonic deadline을 가진다. `withTimeout(io, ms)`는 상위 deadline을 연장하지 않으며 `check()`는 명시 취소와 시간 초과를 각각 `Cancelled`·`DeadlineExceeded`로 구분한다. flag와 Io backend는 모든 callback이 끝날 때까지 유효해야 한다. 읽기 호출은 `ReadSpec.deadline_ms`를 이 deadline에 교차 적용한다. 파일 I/O 자체의 중단 가능성은 OS 경계에 따르며 각 chunk와 결과 공개 전에 확인한다.

## 3. Public function 계약

| ID | 논리 signature | 소유·오류 규칙 |
|---|---|---|
| I01 | authorize(SessionContext, Operation, RelativePath) → Capability | capability는 immutable, root 확대 불가 |
| I02 | reserve(SessionContext, ResourceCost) → Reservation | 성공 전 allocator allocation 금지 |
| I03 | readRange(Capability, ReadSpec, Reservation, Cancel) → Owned<ReadResult> | 결과 반환/취소 시 FD와 scratch 정리 |
| I04 | enumerate(Capability, FileSpec, Sink, Cancel) → Coverage | sink backpressure 존중 |
| I05 | searchLiteral(Capability, SearchSpec, Sink, Cancel) → Coverage | byte span scalar 정답과 동일 |
| I06 | batchRead(SessionContext, ReadSpec[], Reservation) → Owned<BatchResult> | 입력 순서, 항목별 오류 |
| I07 | submit(Owned<JobEnvelope>) → JobHandle | 성공 시 executor가 envelope 소유 |
| I08 | registerWorkspace(TrustedRoot, Policy) → WorkspaceId | incarnation 신규 생성/검증 |
| I09 | acquireWriter(TaskContext, WorkspaceId) → WriterLease | monotonic fence, active writer1 |
| I10 | applyPatch(Capability, WriterLease, PatchSpec) → Receipt | exact expected digest, single-file commit |
| I11 | createFile(Capability, WriterLease, CreateSpec) → Receipt | no-overwrite publish |
| I12 | recover(WorkspaceId, JournalStore) → RecoveryReport | ambiguous state write quarantine |
| I13 | cacheGet(ContentHash, Capability, PinBudget) → optional<PinnedEntry> | authorization first, immutable key, unpin mandatory |
| I14 | invalidate(WorkspaceId, WatchEvent) → IndexState | uncertain/dropped를 감춤 금지 |
| I15 | updatePolicy(ResourceSignals) → AdmissionLimits | hard caps 이상 확대 불가 |
| I16 | outline(Capability, ParserSpec) → Owned<OutlineCandidates> | syntax candidates; refs 아님 |
| I17 | health(SessionContext) → HealthSnapshot | 타 세션 소스·토큰 노출 금지 |
| I18 | serveFrame(Connection, BoundedBytes) → EncodedToolResult | request/output lifetime 분리 |
| I19 | JournalStore.prepare(PreparedRecord) / record(Receipt) / lookup(Key) → JournalResult | versioned record, checksummed persistence, idempotency digest 검사 |

I19의 native persistence 보완은 기존 세 signature를 유지한다. `PreparedRecord.publication`은 실제 workspace/root/parent/temp/old-file 정체성, temp basename, fence, durability, 미리 할당한 receipt ID를 담는다. 영속 store는 이를 필수로 검증하고 복사한다. 선택적 `transition(APPLIED receipt | ABORTED receipt)` vtable은 PREPARED 뒤의 상태를 영속화하며, 없는 구현은 `Unsupported`를 반환한다. 이전 fake-store 단위 시험만 필드를 생략할 수 있고 production write는 이 채널과 T12 crash/restart 증거를 모두 요구한다. `record(Receipt)`는 최종 결과를 기록하되 durability 실패나 복구 필요 상태를 성공으로 승격하지 않는다. 재시작의 새 registry incarnation은 신뢰된 호스트의 명시적 연속성 검증 없이 이전 journal namespace를 재사용하지 않는다.
```

구체 struct 필드 추가/오류 union 변경은 contract digest 변경이다. task는 동일 개념에 새로운 로컬 public type을 발명하지 않는다. private implementation struct는 모듈 안에서 자유롭게 바꿀 수 있다.

영속 store의 `lookup`/`prepare`가 반환하는 Busy·resource·contract admission 오류는 저장 상태를 바꾸지 않은 확정 거부여야 한다. 저장 여부가 불확실하거나 파일·무결성 오류이면 editor는 workspace를 격리하고 정확한 임시 파일·저널 증거를 복구 시점까지 보존한다. 공개 후 parent sync가 실패한 경우 최종 기록에 성공해도 적용 사실과 `E_DURABILITY`를 유지하며, commit guard를 놓기 전에 추가 쓰기를 격리한다.

## 4. Lock과 소유 순서

control-plane actor는 global budget reservation을 얻고 workspace 작업을 제출한 뒤 lock을 놓는다. cache shard lock은 lookup/pin count 수정만 수행하고 file read/parse/output 동안 유지하지 않는다. edit는 workspace writer lease와 path-specific coordinator만 사용한다.

교착 방지 원칙은 **blocking I/O 중 global/registry/cache lock 보유 금지**다. 두 workspace write를 하나의 transaction으로 묶지 않으므로 cross-workspace lock order 문제를 v1에서 만들지 않는다. cancellation은 atomic flag/message로 전파하고 callback completion을 drain한다.

## 5. Cache key

```text
ImmutableContentKey = security_domain + SHA256(bytes)
LineIndexKey = ImmutableContentKey + newline_policy_version
OutlineKey = ImmutableContentKey + parser_language + grammar_digest + options_digest
MutableAssociationKey = workspace_id + generation + filesystem_file_id + relative_path
```

content SHA가 같아도 authorization 없이 cache 존재 여부/bytes를 반환하지 않는다. path casefold만으로 alias를 병합하지 않는다. semantic graph를 나중에 추가하면 compiler flags, imports, lockfile/config digests, workspace context가 별도 key로 필요하다.

## 6. 메모리 비용 모델

`ResourceCost`는 input buffer, output budget, temporary decode, full-file old/new buffers, per-worker scratch, journal staging을 합산한다. patch8MiB는 old8MiB+new8MiB만으로 끝나지 않으므로 raw JSON/decoded replacements/output까지 더한다. 스트리밍 입출력으로 낮출 수 있는 비용과 commit 전에 반드시 필요한 bytes를 구분한다. budget 계산을 optimistic average만으로 수행하지 않는다.
