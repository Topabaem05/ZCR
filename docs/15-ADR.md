# 15 · Architecture Decision Records

모든 항목은 설계상 **Accepted**이며 실제 구현/성능 검증 완료를 의미하지 않는다.

| ID | 결정 | 검토한 대안 | 이유·손실 | 재검토 조건 |
|---|---|---|---|---|
| ADR-001 | Zig 0.16.0 고정 | Rust, C++, Zig master | 사용자의 실험 목적·명시적 allocator; ecosystem/버전 이동 비용 부담 | compiler bug/OS 지원 blocker |
| ADR-002 | direct MCP stdio 기본 | per-call CLI, daemon 필수 | spawn/IPC 단계 최소화; 다중 process 예산은 따로 관리 | 여러 세션 자원 공유 필요 |
| ADR-003 | broker는 명시적 옵션 | 항상 background service | 권한/lifetime/관리 복잡도 최소화 | B5 E2E/resource 개선 증명 |
| ADR-004 | JSON 우선 | binary core protocol | 구현·debug·compatibility 비용 최소화 | JSON 비용 >총 tool 15% 실측 |
| ADR-005 | public GCD shim + bounded baseline | experimental Io.Dispatch 단독 | 안정 backend 확보, QoS 이용 | Zig backend 안정성/벤치 검증 |
| ADR-006 | QoS hints, affinity 미사용 | 코어별 hard pinning | OS thermal/power scheduler와 협력 | 공인 API·반복 실측 우위 |
| ADR-007 | request/worker별 allocator 소유 | shared arena, global general allocator만 | lifetime·accounting 명확; 예약/반납 코드 증가 | 유지보수 복잡도 실증 |
| ADR-008 | live mmap 기본 off | 모든 파일 mmap | truncate/fault와 VM 비용 회피 | immutable mapping benchmark 우위 |
| ADR-009 | workspace mutable state 분리 | repo당 path cache 공유 | worktree 오염 방지; metadata 일부 중복 | 안전한 identity 증명 가능한 최적화 |
| ADR-010 | strict single-writer 전용 worktree | 외부 editor와 완전 CAS 주장 | 실제 보장 경계 정직; 사용 제약 | OS/host 협력 transaction 기능 |
| ADR-011 | single-file atomic replace | multi-file transaction | 명확한 recovery/commit point | 별도 journal/rollback spec 승인 |
| ADR-012 | literal-first + rg baseline | 새 regex engine | 범위 제한·bounded 정답; 일부 기능 미제공 | 실제 workload regex 수요 |
| ADR-013 | watcher는 invalidation hint | index가 항상 최신 | 변경 유실 시 누락 성공 방지 | 더 강한 managed mutation contract |
| ADR-014 | syntax≠semantic references | tree-sitter를 LSP 대체로 홍보 | 잘못된 자동 edit 방지 | 검증된 LSP 선택 모듈 |
| ADR-015 | model E2E gate | native microbench만 최적화 | 사용자 목적에 직접 연결 | 연구용 성능 실험을 명시 분리 |
| ADR-016 | source tree 밖 cache/journal | repo 내부 hidden state | 작업 diff 오염·token leak 방지 | 별도 portable profile 승인 |
| ADR-017 | trusted policy + annotations 분리 | MCP tool name만 신뢰 | broker privilege escalation 방지 | host의 검증된 capability API |
| ADR-018 | default text-only result | structured+text 중복 항상 사용 | token duplication 피함; richer schema는 옵션 | client별 모델 입력 검증 |
| ADR-019 | 개발 task별 worktree·소유 파일 | 같은 checkout 여러 agent | 미완성 작업·test evidence 오염 방지 | 단일 개발자라도 scope guard 유지 |
| ADR-020 | 선택적 Windows/AST 단계 | 모두 v1 필수 | core 검증 집중 | Apple/Linux core gates 완료 |

변경할 때는 새 ADR에 기존 ID, 측정 evidence, schema migration, backward compatibility, task 영향, rollback을 기록한다. performance-only 제안도 security/consistency 불변조건을 완화하려면 별도 승인받는다.
