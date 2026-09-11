# 11 · 보안 · 실패 · 복구

## 1. 위협 모델

보호 대상은 승인된 workspace 밖 파일, 다른 task의 미완성 변경, 공용 Git metadata, capability token, 소스 기밀성, 정상 클라이언트의 자원이다. 저장소 소스·README·주석·검색 결과는 **untrusted data**이며 tool 실행 지시나 정책 변경 권한이 아니다.

신뢰 가정은 host가 올바른 root/policy를 승인하고 OS 계정/프로세스 실행 환경을 통제한다는 것이다. 악의적인 same-UID 프로세스, root권한 공격자, 취약한 kernel까지 ZCR만으로 격리한다는 보장은 없다. Git worktree와 path-prefix 검사는 보안 sandbox의 대체물이 아니다.

## 2. 경로와 파일 접근

절대 경로, `..`, NUL, UNC/device path, forbidden drive prefix를 입력에서 거부한다. 단순 `startsWith(root)`가 아니라 승인 root handle 아래 component별 검증을 적용한다. `.git` 파일/디렉터리와 resolved common git dir는 쓰기 금지다. symlink는 v1 read/write 모두 기본 거부한다. future follow-symlink mode는 별도 capability와 최종 target 경계 검증이 필요하다.

open 전에 type를 보고 open 후에도 regular file인지 검증한다. device/FIFO/socket 읽기는 금지한다. 악성 동일 UID가 검사 사이 파일을 바꾸는 조건은 전용 directory/sandbox로 제한해야 한다. descriptor-relative API는 TOCTOU 위험을 줄이지 모든 외부 race를 제거하지는 않는다.

## 3. Policy 전달

standalone은 trusted launch arguments의 read-only policy 파일을 검증한다. broker는 current-user socket mode 0600과 peer credential 확인에 더해 난수 capability token을 요구한다. token을 argv나 소스 로그에 남기지 않고 inherited handle 또는 protected file로 전달한다. 인증 전에는 root 존재 여부도 공개하지 않는다.

MCP tool annotations는 host UI 힌트다. `readOnlyHint=true`가 filesystem 접근권한을 부여하지 않는다. roots/list는 후보 경로 정보이며 기존 trusted policy와 교집합을 취한다. root가 추가됐다는 notification만으로 권한을 확대하지 않는다. [R15](../references/SOURCES.md#R15)

## 4. 자원 공격

깊은 JSON, 거대한 string, 재귀 directory, 극단적으로 긴 줄, 반복 match, 높은 inode 수, path alias, ignore 폭탄, unreadable tree, slow stdout, dropped watcher storm을 시험한다. regex가 없는 v1에서도 glob의 병적 패턴을 linear/bounded-state 구현으로 제한한다. default directory depth 최대 128, ignore file 최대 1 MiB·규칙 10,000개/워크스페이스다. 한도를 넘으면 explicit incomplete 또는 unsupported이지 조용한 누락 성공이 아니다.

FD budget은 OS soft limit에서 control reserve 32를 빼고 전체 최대 128로 제한한다. soft limit이 너무 작으면 동시성부터 줄인다. 닫기/deinit 실패는 기록하고 recurring leak이면 신규 요청을 줄인다. 별도 memory emergency reserve는 오류 응답용이며 일반 검색이 빌려 쓰지 못한다.

## 5. Journal 상태 기계

| 상태 | on-disk 의미 | 재시작 동작 |
|---|---|---|
| RECEIVED | 요청 식별자만 존재 | source 미변경; 재검증 가능 |
| PREPARED | old/new digest와 temp identity 기록 | source/temp bytes 비교 후 판정 |
| APPLIED | replace 관측, durability 미완료 가능 | resulting hash 확인, applied receipt 복원 |
| COMMITTED | 요청한 persistence 결과와 receipt 기록 | 같은 key는 receipt 재반환 |
| ABORTED | commit 전에 중단 | temp만 policy-checked cleanup |
| UNCERTAIN | 파일 상태가 예상 old/new 어느 쪽도 아님 | 해당 경로 쓰기 quarantine |

journal record는 version, workspace incarnation, task/fence, op digest, old/new content hash, relative path, temp name, sequence, checksum을 가진다. 민감한 source 원문은 기본 저장하지 않는다. journal의 임의 temp path를 그대로 삭제하지 않고 root/parent/temp pattern/inode identity를 재검증한다.

## 6. 복구 판정

PREPARED에서 target hash가 old hash이고 temp가 new hash면 미커밋으로 판정하고 자동 재적용하지 않는다. target이 new hash면 applied로 복구하되 요청한 durable 수준을 재검증한다. 둘 다 아니면 external change 또는 손상으로 보고 UNCERTAIN이다. 동일 해시라는 이유로 workspace incarnation mismatch를 무시하지 않는다.

create의 경우 old는 ABSENT sentinel이다. 이미 존재하는 target이 new hash와 같아도 동일 요청의 publish를 확실히 관측하지 못한 shared-editor 환경에서는 소유권을 추정하지 않는다. strict 전용 worktree와 journal sequence 아래에서만 자동 receipt 복원을 허용한다.

## 7. Crash injection 지점

journal 쓰기 전/중/후, temp content 쓰기 중, metadata 복제 중, final fence 확인 후, rename 직전/직후, parent fsync 전/후, receipt flush 전/후를 강제 종료한다. 각 지점에서 원본 또는 완성 새 파일만 관측해야 하며 부분 파일을 target으로 노출해서는 안 된다. disk-full, permissions, temp name collision, stale lease, open target, unsupported filesystem을 포함한다.

## 8. 로그와 민감정보

default log에는 request ID, operation, duration, byte count, error code, hashed workspace label만 담는다. query/source/content/path 전체, capability token, env는 제외한다. 사용자가 local-debug 모드를 승인한 경우에만 relative path·query를 제한적으로 기록하고 만료/삭제 정책을 표시한다. 원격 telemetry는 없다.

## 9. Fail closed와 가용성

권한/identity/fence 불일치는 즉시 거부한다. watcher 불확실성은 live read fallback으로 가용성을 보존한다. memory pressure는 신규 bulk admission을 줄이지 이미 완료한 쓰기 결과를 지워서는 안 된다. recovery uncertainty는 해당 workspace/path의 쓰기를 막고 다른 승인된 workspace의 read는 계속한다.
