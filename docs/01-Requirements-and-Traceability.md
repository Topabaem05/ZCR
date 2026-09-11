# 01 · 요구사항과 추적성

`MUST`는 출시 차단 조건, `SHOULD`는 근거 있는 예외가 필요한 기본값이다. 모든 성능값은 [시험 계획](12-Performance-and-Test-Plan.md)의 조건과 함께 판정한다.

| ID | 요구사항 | 설계 위치 | 구현 Task | 검증 |
|---|---|---|---|---|
| FR-01 | UTF-8 텍스트의 정확한 줄/바이트 범위 읽기 | SDD·I/O | T04 | IO-001~006 |
| FR-02 | ignore 규칙을 존중하는 파일 탐색 | 검색 | T05 | FS-001~006 |
| FR-03 | literal 검색 + 중복 제거한 주변 문맥 | 검색·파이프라인 | T06 | SR-001~006 |
| FR-04 | 최대 32개 항목의 batch read, 항목별 오류 | API | T07 | BA-001~003 |
| FR-05 | expected SHA-256 기반 한 파일 patch | 편집·복구 | T11,T12 | WR-001~008 |
| FR-06 | 덮어쓰지 않는 create | 편집 | T11 | WR-009~010 |
| FR-07 | Codex/Claude MCP stdio 직접 연결 | API·통합 | T08,T23 | MC-001~006 |
| FR-08 | workspace/task 정체성·쓰기 범위 분리 | 격리 | T02,T10 | IS-001~008 |
| FR-09 | broker로 여러 세션 예산 통합 | SDD | T15 | BR-001~005 |
| FR-10 | watch invalidation 및 유실 복구 | 일관성 | T14 | WA-001~006 |
| FR-11 | 현재 상태·자원·오류 진단 | 운영 | T00,T22 | OB-001~004 |
| FR-12 | 선택적 outline/구문 후보 반환 | 데이터 모델 | T20 | AS-001~004 |
| NFR-01 | runtime 핵심 경로에 Python/Node/JVM 불필요 | SDD | T01,T24 | 의존성 감사 |
| NFR-02 | macOS QoS + 유계 작업 분배 | Apple Silicon | T09,T16 | SC-001~006 |
| NFR-03 | RAM/압력에 따른 admission·eviction | 메모리 | T03,T16 | ME-001~008 |
| NFR-04 | 스레드·FD·출력·큐·parser 자원에 상한 | SDD | T03,T07,T09 | 한도 주입 |
| NFR-05 | x86-64 Linux·Intel Mac core 호환 | 이식성 | T17,T19,T24 | 플랫폼 행렬 |
| NFR-06 | ARM64/x86 SIMD는 scalar와 동일 의미 | 이식성 | T19 | 차등·경계 fuzz |
| NFR-07 | 성능 측정과 모델 E2E 비교 | 테스트 | T00,T21,T23 | PF-001~008 |
| SEC-01 | symlink/경로 탈출/.git 쓰기 거부 | 보안 | T02,T04,T11 | IS-003,004,007 |
| SEC-02 | 권한 확대 없는 MCP/broker 통합 | 보안 | T08,T15,T23 | MC-005,BR-004 |
| SEC-03 | 충돌·취소·크래시 시 조용한 덮어쓰기 금지 | 복구 | T11,T12 | WR-002~008 |
| DEV-01 | task·step별 파일 소유권·기준 commit 기록 | 구현 워크플로 | T01,T02 | DV-001~006 |
| DEV-02 | 병렬 개발에서 공유 파일 변경은 단일 통합자 | 구현 워크플로 | 모든 Task | preflight/merge gate |
| DEV-03 | 요구사항→Task→시험→증거로 연결 | 이 문서 | T21,T25 | 추적성 검사 |

## 공통 계약 수치

| 항목 | 값 | 분류 |
|---|---:|---|
| raw JSON 메시지 | 최대 16 MiB | 강제 상한 |
| tool 결과 내용 | 기본 256 KiB, 요청 상한 2 MiB | 강제 상한 |
| batch 항목 | 최대 32 | 강제 상한 |
| 요청 줄 수 | 기본 200, 최대 5,000 | 강제 상한 |
| 검색 매치 수 | 기본 100, 최대 1,000 | 강제 상한 |
| 검색 파일 크기 | 기본 32 MiB, 명시 승인 시 최대 1 GiB | 강제 상한 |
| patch/create 결과 파일 | 최대 8 MiB | 강제 상한 |
| path UTF-8 길이 | 최대 4,096 bytes 및 OS 실제 한도 중 작은 값 | 강제 상한 |
| CPU/I/O chunk | 기본 256 KiB, CPU 2 ms 목표에서 재분할 | 튜닝 초기값 |
| 전역 대기 요청 | 64, 세션별 16 | 강제 상한 |
| broker 세션 | 최대 16, 활발한 task 기본 8 이하 | 강제 상한/초기값 |
| client output backlog | 2 MiB, 그룹 전체 16 MiB 이내 | 강제 상한 |
| request deadline | 기본 5 s, 최대 60 s | 협력적 취소 한도 |
| lease 갱신 / TTL | 10 s / 30 s | 초기값 |
| source/toolchain 기준 | 2026-09-11 / Zig 0.16.0 | 기준선 |

상한을 키우는 요청도 workspace policy 및 남은 global budget을 넘을 수 없다. `max_*`는 모두 연산을 덜 하도록 제한할 수 있는 값이지 새로운 권한이 아니다. deadline은 중단 불가능한 kernel I/O의 종료 시간을 보장하지 않는다.

## 사용자 의도 보존

Zig를 선택한 이유는 명시적 자원 소유권·작은 배포물·플랫폼 제어를 실험하기 위해서다. Rust로 언어를 바꾸는 것은 구현자가 자체 결정할 수 없다. C ABI를 위한 작은 macOS shim 및 선택적 Tree-sitter C 라이브러리는 허용하지만 별도 ADR와 의존성 목록에 기록한다.
