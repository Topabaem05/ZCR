# ZCR · Zig Code Runtime
## Coding agent의 파일 도구 병목을 줄이는 설계 패키지

**문서 버전:** 1.0 · **기준일:** 2026-09-11 · **상태:** 구현 전 설계 기준선

`ZCR`은 이 문서에서 사용하는 작업명이다. 등록된 제품명·저장소명이라는 뜻은 아니다. 구현 언어는 **Zig 0.16.0으로 고정**한다. Apple Silicon을 우선하되 x86-64 Linux와 Intel Mac을 같은 코어 엔진으로 다룬다.

목표는 모델 자체의 decode tok/s를 올리는 것이 아니라 **유효한 코드 변경 한 건에 걸리는 전체 시간**을 줄이는 것이다. 파일 I/O, 도구 대기, 검색 결과의 과다 출력, 반복 Read, 잘못된 워크트리 편집 및 재시도를 함께 측정한다.

### 먼저 읽을 문서

| 순서 | 문서 | 결정하는 내용 |
|---|---|---|
| 1 | [요약](docs/00-Executive-Brief.md) | 목적, 채택·제외 범위, 이전 설명에서 바로잡은 사항 |
| 2 | [요구사항](docs/01-Requirements-and-Traceability.md) / [SDD](docs/02-SDD.md) | 제품 계약, 구성요소 및 불변조건 |
| 3 | [C4](docs/03-C4-Architecture.md) | 시스템·컨테이너·컴포넌트·코드 모델 |
| 4 | [Apple Silicon](docs/04-Apple-Silicon-Scheduling.md) / [메모리](docs/05-Memory-and-Pressure.md) | QoS, 코어 활용 의도, 작업·메모리 예산 |
| 5 | [워크트리](docs/06-Worktree-and-Task-Isolation.md) / [파이프라인](docs/07-Pipelines-and-Consistency.md) | 격리, 일관성, 읽기·검색·편집 실행 순서 |
| 6 | [구현 계획](docs/13-Implementation-Roadmap.md) / [개별 Task](tasks/INDEX.md) | 소유 파일, 의존성, Step, 테스트, 완료 게이트 |

**전체 열람:** `DESIGNBOOK.html`은 외부 스크립트·폰트·네트워크가 필요 없는 통합 열람본이다. Markdown이 수정 가능한 원본이며, `diagrams/`의 Mermaid와 DOT는 도식 원본이다.

### 패키지의 사용 경계

이 ZIP은 **실행 가능한 런타임을 구현한 결과물이 아니다.** API 계약, 구성 예시, 테스트 벡터, 구현 계획과 문서 자체의 검증 도구를 제공한다. `zcr ...` 및 `zig build ...` 명령은 앞으로 구현할 인터페이스의 계약이다. 실제 Mac 성능·코어 배치·에너지·클라이언트 연동 테스트는 수행하지 않았다.

설정·메모리·지연 수치는 **초기 설계값 또는 합격 목표**이지 실측 성능이 아니다. 계약 파일 검증 결과와 런타임 테스트 결과를 혼동하지 않는다.

### 프로젝트의 절대 규칙

1. 검색 속도를 이유로 권한, 워크트리 정체성, 콘텐츠 버전, 출력 제한을 생략하지 않는다.
2. QoS는 OS에 전달하는 의도다. 특정 슈퍼/P/E 코어에 반드시 배치된다고 약속하지 않는다.
3. 임의 쉘 실행·네트워크·자동 Git commit/merge는 도구 엔진의 권한에 포함하지 않는다.
4. 기본 MCP는 동일 Zig 바이너리의 **직접 stdio 모드**다. 추가 daemon·binary RPC는 필수가 아니다.
5. 여러 세션의 자원 통합이 필요할 때만 **명시적으로 승인한 broker 모드**를 사용한다.
6. 런타임 사용 중 업무 task 격리와, 런타임을 개발하는 implementation task 격리를 별도로 적용한다.

외부 사실의 근거는 [출처 목록](references/SOURCES.md)에 기록했다. SDK와 클라이언트 버전에 의존하는 사항은 [검증 게이트](docs/16-Evidence-and-Open-Gates.md)를 먼저 통과시킨다.
