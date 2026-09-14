# 18 · 메인 병합 점검과 남은 작업

**점검일:** 2026-09-13 · **목적:** 기존 구현 이력을 메인에 통합하고 다음 작업을 명확히 한다. **릴리스 상태: BLOCKED.**

## 브랜치 포함 관계

원격 브랜치 전체를 가져온 뒤 `git merge-base --is-ancestor <ref> a911bf8`로 검사했다. 아래 모든 ref가 후속 브랜치의 조상이다. 따라서 후속 브랜치를 merge commit으로 메인에 병합하면 원본 작업 commit을 모두 보존한다. 브랜치 삭제나 force push는 필요하지 않다.

| 브랜치 | 점검한 head | 후속 브랜치에 포함 |
|---|---|---|
| main | 7eeab60 | 예 |
| integration | 4bcf01d | 예 |
| task-t00 | ede012a | 예 |
| task-t01 | 35321ad | 예 |
| task-t02 | f8c0cb0 | 예 |
| task-t03 | f2fca29 | 예 |
| task-t04 | b933c3a | 예 |
| task-t05 | 91c1b62 | 예 |
| task-t06 | 13ee271 | 예 |
| task-t07 | 531cfc3 | 예 |
| codex/continue-runtime-20260912 | a911bf8 | 통합 기준 |

[PR #1](https://github.com/Topabaem05/ZCR/pull/1)의 base를 `integration`에서 `main`으로 변경한다. 최신 사용자 요청은 메인 병합을 명시적으로 승인했다. 이전 후속 계획의 미승인 설명은 작성 당시 상태로 보존하며 이번 요청을 제한하지 않는다.

## 현재 구현 경계

- `src/`에는 Zig 파일 45개가 있으며 `build.zig`로 빌드한다. Zig 0.16.0을 유지한다.
- T00–T14는 `IMPLEMENTED_WITH_OPEN_GATES`, T15–T16은 `IN_PROGRESS`다. 구현 파일의 존재와 Task 완료를 구분한다.
- 직접 stdio MCP는 읽기 도구 6개를 연결한다. 실행 정책에서 쓰기 및 broker 활성화를 요청하면 현재는 거부한다.
- T12 journal/recovery는 Linux와 Darwin에서 동작한다. PR #2(`9226555`)가 Darwin의 `fstat` 기반 metadata, `F_FULLFSYNC` 내구 동기화, store 파일의 extended ACL 거부를 넣었고, T11은 커널이 붙이는 `com.apple.provenance` 속성을 원본과 교체본의 값이 같을 때만 허용한다. 운영 쓰기는 여전히 비활성이다.
- `src/watch/linux.zig`가 존재해도 T17 전체 backend·자원 관측·플랫폼 게이트가 완료된 것은 아니다.

## 이번 점검에서 수정한 CI 오류

[이전 실행 34697951744](https://github.com/Topabaem05/ZCR/actions/runs/34697951744)는 세 플랫폼 모두 런타임 시험 전에 종료됐다. `native.py`가 `storage_capture`를 import하면서 `__pycache__`를 생성했고, clean-source 검사에서 이를 거부했다. 자식 프로세스에만 설정한 `PYTHONDONTWRITEBYTECODE`는 이미 실행 중인 부모 interpreter의 import에 적용되지 않았다.

로컬 source `169be18` / 원격 source `88546e8`은 동일 tree `54dba2efb586303f5b60e80bf3834c28519a223e`를 가진다. repository module import 전에 `sys.dont_write_bytecode = True`를 설정하고 workflow에도 환경변수를 지정했다. 소스 무결성 검사는 그대로 유지한다.

새 회귀 시험은 별도 임시 소스 복사본을 일반 Python으로 실행한다. 수정 전 `__pycache__` 생성으로 실패했고 수정 후 통과했다. 기존 storage capture 검사까지 5개가 통과했다. 이 결과는 CI 도구 검사이며 Zig 런타임 PASS를 뜻하지 않는다.

## 이번 소스의 검증 결과

로컬 Linux에서 `python -B tools/ci/native.py --source <clean-checkout> --state <fresh-external-state> --target x86_64-linux --runner local-linux`를 실행했다. [상세 보고서](../evidence/merge-20260913/local-native-report.json)는 command·exit code·source/tree·binary·config/contract/test-input digest와 source 전후 무변경 검사를 포함한다. 원본 로그와 복구 fixture는 [증거 압축본](../evidence/merge-20260913/local-native-evidence.tar.gz)에 보존했다.

| 검증 | Debug | ReleaseSafe |
|---|---|---|
| 빌드·계약 검사 | PASS | PASS |
| 등록된 시험 356개 | 346 PASS / 1 SKIP / 9 FAIL | 346 PASS / 1 SKIP / 9 FAIL |
| 별도 codec 시험 | 10 PASS | 10 PASS |
| 실제 CLI subprocess 검사 | 19 PASS | 19 PASS |
| capability probe | PASS | PASS |
| T12 복구 증거 수집 | PASS | PASS |

9개 실패는 `AF_UNIX` socket 생성 시 발생했다. 이 컨테이너에서 Python으로 별도 확인한 결과도 `errno=1 Operation not permitted`였다. 1개 SKIP은 Linux에서 실행할 수 없는 native GCD 시험이다. 로컬 전체 결과는 **FAIL**로 보존하며 제한된 환경의 실패를 통과로 바꾸지 않는다.

[GitHub native 실행 34705666351](https://github.com/Topabaem05/ZCR/actions/runs/34705666351)은 source `88546e8`을 검증한다. Linux job은 최종 **SUCCESS**, Apple Silicon job은 **FAILURE**로 확인했다. 이는 CI 시작 오류가 해결됐음을 보여주지만 Mac 지원 완료를 뜻하지 않는다. 문서만 바뀐 병합 commit에 이 실행의 source별 결과를 새 runtime PASS로 재사용하지 않는다.

Apple Silicon은 Debug **320 PASS / 12 SKIP / 24 FAIL**, ReleaseSafe **321 PASS / 12 SKIP / 23 FAIL**이다. 두 모드 모두 T12의 Linux 전용 `Store.init`/`metadata`가 `Unsupported`를 반환해 23개 시험이 실패했다. Debug에서는 fixture 초기화 실패 경로의 168개 allocation leak도 보고됐다. 추가 Debug 실패 1개는 T08 `MC-004 retiring tool id is detached before gated arena teardown`의 `entered and accepted_during_retirement` assertion이며 재현·원인 분석이 필요하다. 테스트 시간 제한만 늘려 통과 처리하지 않는다. [Mac 원본 로그](../evidence/merge-20260913/mac-registered-logs.tar.gz)와 [보고서](../evidence/merge-20260913/mac-native-report.json)를 보존했다. Intel Mac job은 이 문서의 점검 시점에 실행 중이므로 최종 결과를 단정하지 않는다.

이 절의 Mac 실패는 `88546e8` 시점의 기록이다. 아래 병합 후 실행에서 해소됐다.

## PR #2·#3 병합 후 native CI

[실행 34793696720](https://github.com/Topabaem05/ZCR/actions/runs/34793696720)은 PR #3 병합 commit인 `main` `a15b127`을 세 플랫폼에서 검증했다. 세 job 모두 **SUCCESS**다. 플랫폼별 보고서, 등록 시험 로그, artifact digest는 [증거 묶음](../evidence/continuation/native-ci-34793696720/README.md)에 보존했다.

| 플랫폼 | Debug | ReleaseSafe |
|---|---|---|
| x86_64 Linux | 356 PASS / 3 SKIP / 0 FAIL | 356 PASS / 3 SKIP / 0 FAIL |
| Apple Silicon (macOS 15) | 347 PASS / 12 SKIP / 0 FAIL | 347 PASS / 12 SKIP / 0 FAIL |
| Intel Mac (macOS 15) | 347 PASS / 12 SKIP / 0 FAIL | 347 PASS / 12 SKIP / 0 FAIL |

- **leak과 명령:** 세 플랫폼 모두 allocation leak이 없다. contracts, codec, 실제 CLI subprocess, capability 검사가 모두 exit 0이다.
- **Mac 시험:** 두 Mac에서 T08 27/27, T11 43/43, T12 25/25를 통과했다. Mac의 SKIP 12개는 T14 시험이다. Linux의 SKIP 3개는 T09, T11, T12의 플랫폼 전용 시험이다.
- **PR #2:** T12의 Linux 전용 guard와 fixture leak을 없앴다. 원인과 probe는 `evidence/mac-write-path-20260913/README.md`에 있다.
- **PR #3:** MC-004 retirement 실패의 원인을 찾아 고쳤다. 시험이 요청마다 두 번 오르는 authority 검증 카운터를 `== 2`로 읽어 서버 스레드와 경쟁했다. 증거는 `evidence/T08/mc004-retirement-20260913/README.md`에 있다.
- **아직 NOT_RUN인 외부 gate:** G05 APFS 전체 ACL/xattr/crash-durability 검증, G07/G08/G13 실제 host client·sandbox 연동, G11 macOS 11 Intel 실행, G12 모델 공존·E2E 성능. release 상태는 계속 **BLOCKED**다.
- **남은 발견:** 로컬에서 CPU 부하를 걸었을 때 runtime-cache 시험이 `IoFailure`로 실패한 원인을 확인했다. 과다 할당된 CPU에서 workspace discovery의 git 호출(`git worktree list`, `git rev-parse`)이 5000 ms timeout을 넘겼고(16 busy loop에서 6932 ms), `identity.zig`가 이를 `IoFailure`로 보고했다. timeout을 재시도 가능한 `Busy`로 보고하고 예산을 설정 가능하게 하는 T10 수정은 [PR #6](https://github.com/Topabaem05/ZCR/pull/6)에서 검토 중이다. 수정 전 `main` binary도 같은 부하에서 같은 경로로 실패해, 부하 경합으로 생기는 기존 현상이며 CI gate가 아니라 문서화된 한계로 둔다. MC-004 deadline 시험이 watcher의 취소를 관찰하지 못하던 문제는 PR #5(`96c2666`)로 해소됐다. 시험은 watcher의 취소 hook을 기다린 뒤 authority 검사가 정확히 1회인지 확인하며, 증거는 `evidence/T08/deadline-20260914/README.md`에 있다.

## 남은 작업과 완료 조건

| 순서 | 범위 | 다음 작업 | 완료 근거 |
|---|---|---|---|
| 1 | T08 / T12 / native CI | **대부분 완료**(PR #2·#3, 실행 34793696720): MC-004 원인 분석·수정, Darwin storage 이식, fixture 초기화 실패 시 자원 회수, Mac의 T12 SIGKILL 복구 시험과 storage 증거 수집. 남음: G05 APFS 파괴적 crash-durability 검증, G11 macOS 11 Intel. MC-004 deadline 시험 관찰 지점은 PR #5로 완료, 부하 시 runtime-cache `IoFailure`는 원인 확인·T10 수정 검토 중(PR #6) | Linux·Apple Silicon·Intel Mac에서 Debug/ReleaseSafe 결과와 raw 복구 증거(위 병합 후 native CI 절) |
| 2 | T12 / T15 | 신뢰된 supervisor, write/reconnect 수명 관리 및 broker CLI/bridge 연결 | 권한·fence·취소·느린 클라이언트·재접속 통합 시험; 승인 전 쓰기 비활성 유지 |
| 3 | T16 | pressure/thermal 신호 수집, governor 정책, 실제 runtime 연결 | admission·회수·공정성 및 모델 공존 시험 |
| 4 | T17 / T19 | Linux backend 완성, 필수 ARM64/x86 SIMD 경로 | 플랫폼 자원 관측 검증, scalar 차등·경계 시험 |
| 5 | T21 / T22 | 전체 벤치마크 하네스, bounded telemetry/health | 재현 가능한 corpus·config·raw trace, 예산·민감정보 검사 |
| 6 | T23 / T24 | 실제 Codex/Claude 라우팅, 패키징·지원 행렬 | 실제 클라이언트·호스트 sandbox 실행, 설치 및 지원 플랫폼 검증 |
| 7 | T25 | 최종 통합·격리·성능 릴리스 검토 | 모든 필수 요구사항의 source별 증거 및 미해결 게이트 해소 |

T18 Windows와 T20 Tree-sitter는 선택하지 않은 옵션이다. T19는 필수다. 실제 macOS 11, APFS ACL/xattr 및 crash durability, kernel fault/전원 손실, 실제 모델·클라이언트 E2E 게이트는 미완료 상태를 유지한다. 이 점검에서는 남은 대형 Task를 완료로 승격하지 않는다.
