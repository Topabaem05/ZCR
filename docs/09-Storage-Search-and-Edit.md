# 09 · 파일 엔진 · 검색 · 편집 저장 계약

## 1. 파일 읽기의 실제 fast path

Read의 기준 구현은 descriptor-relative `open → fstat → bounded read/pread → fstat → close`다. 작은 파일은 worker scratch에 읽고, 큰 파일의 뒤쪽 줄은 검증된 sparse line index가 있을 때 checkpoint에서 시작한다. index가 없으면 앞부분을 stream하며 줄바꿈을 세는 비용을 숨기지 않는다.

live source mmap은 기본 비활성이다. 파일 truncate와 mapping 수명의 충돌은 프로세스 fault를 일으킬 수 있고 mapping도 resident working set을 사용한다. immutable snapshot만 선택적 후보로 둔다. [R26](../references/SOURCES.md#R26) mmap threshold는 고정된 “32 KiB면 빠름” 규칙이 아니라 T00/T21의 small-file/APFS/NVMe 반복 실험에서 결정한다.

검증된 checkpoint의 의미를 엄격히 유지한다. `checked_live`에서 과거 line index가 현재 bytes와 같다는 근거가 없다면 앞에서부터 다시 scan한다. `mtime+size`만 같다고 오래된 byte offset으로 바로 점프하지 않는다. 전체 content hash를 확인해서 재사용한다면 그 hash 비용도 benchmark에 포함한다. 모든 writer가 관리되는 `managed_generation` 또는 immutable snapshot에서만 generation/content key로 이 확인 비용을 줄인다.

## 2. 탐색·ignore 의미

기본은 `.git` 내부 제외, 숨김 파일 제외, `.gitignore`·`.git/info/exclude`·명시 설정된 global exclude 적용이다. v1 repository config를 실행하거나 arbitrary ignore helper를 호출하지 않는다. 추가 root-local `.zcrignore`는 높은 우선순위의 **명시적 제품 규칙**이며 Git 자체 기능인 것처럼 설명하지 않는다.

nested ignore는 가까운 directory가 우선한다. escape된 `#`/`!`, trailing space, slash anchoring, `**`, directory-only rule을 시험한다. 제외된 parent의 child를 negation만으로 되살리는 Git-ignore 제약을 유지한다. [R17](../references/SOURCES.md#R17)

`.gitignore`를 포함한 hidden config를 편집하려면 exact path 허용 목록과 host의 별도 승인이 필요하다. 숨김을 검색에서 제외하는 것과 source를 읽을 권한이 없는 것은 서로 다른 판정이다. path 출력은 relative `/` 구분자로 통일하되 OS 호출은 native representation을 사용한다.

일관된 결과가 필요한 benchmark는 `order=path_then_offset`로 정렬한다. lazy default는 발견 순서를 사용할 수 있지만 반드시 `order=discovery`로 표시한다. cap이 있는 결과를 순서 차이로 유리하게 비교하지 않는다. 명시된 limit까지의 정렬이 전체 첫 N개를 뜻하려면 전체 candidate 집합을 확인해야 하므로 비용을 측정한다.

## 3. Literal scan

scalar scanner를 정답 기준으로 먼저 만든다. search chunk는 256 KiB이며 길이 m인 패턴의 boundary match를 위해 최대 m-1 bytes overlap을 유지한다. overlap에 속한 match는 global offset으로 deduplicate한다. 빈 pattern 금지. binary detection은 NUL을 발견한 파일을 기본 제외하며 결과 coverage에 기록한다.

context는 같은 파일의 `[line-context,line+context]` 범위를 union한다. 같은 줄에 match가 여러 개면 line bytes는 한 번 반환하고 match spans만 여러 개 제공한다. index 없이 결과만 찾은 경우 줄 번호 계산은 동일 pass에서 진행한다. 검색 후 문맥을 다시 읽을 때 version이 바뀌면 재시도 1회 또는 changed 오류를 반환하며 다른 버전의 snippet을 섞지 않는다.

## 4. 편집 알고리즘

1. 요청의 task/policy/fence/expected version을 검증한다.
2. root directory handle 아래 대상 parent를 안전하게 연다. final component가 symlink·directory·special file이면 거부한다.
3. 원본 전체 bytes와 metadata를 얻고 SHA-256을 확인한다.
4. 오름차순 non-overlapping spans를 적용해 새 bytes를 만든다. 결과 크기 8 MiB 상한과 allocator credit을 확인한다.
5. 같은 parent에 무작위 이름의 O_EXCL temp를 생성한다. temp 이름은 `.zcr-tmp-<random>` 형식이며 model-controlled 값이 아니다.
6. 원본의 지원되는 mode·ACL·xattr 보존을 준비한다. 보존이 불가능하면 **원본 교체 전 실패**한다. setuid/setgid와 특수 보안 attribute는 정책상 금지한다.
7. PREPARED journal을 기록하고 마지막 fence/version을 확인한다.
8. 같은 filesystem 내 원자적 replace를 수행한다. 이 순간이 commit point다.
9. 요청 durability를 수행하고 결과 receipt/journal 상태를 확정한다.

파일 descriptor를 읽은 뒤 rename 직전 hash를 다시 검사하는 것은 협력 writer 사이 충돌 방지다. 임의의 외부 writer와의 atomic CAS는 아니다. 최종 검사와 rename 사이에 외부 변경이 들어올 수 있으므로 strict policy는 **전용 worktree의 모든 writer를 동일 coordinator로 제한**한다.

## 5. Create와 alias

create는 존재하는 경로를 덮어쓰지 않는 kernel primitive를 사용한다. temp 완성 후 no-replace rename 또는 동등한 publish primitive를 플랫폼별로 확인한다. Linux `renameat2(RENAME_NOREPLACE)`, Darwin `renameatx_np(RENAME_EXCL)` 등은 **SDK/FS 검증 게이트**이며 사용 가능성을 가정하지 않는다. 같은 directory 내 `linkat` 기반 publish는 regular temp에 한해 지원·metadata·cleanup 시험 후 fallback 후보로 둔다. 안전한 no-replace publish가 없으면 create capability를 비활성화한다.

v1 edit는 `st_nlink > 1` 파일을 기본 거부한다. rename replacement는 다른 hardlink alias에 새 bytes를 반영하지 않으므로 사용자의 “같은 파일” 기대와 다를 수 있기 때문이다. hardlink read의 출처를 path 검사만으로 증명할 수 없으며 sandbox 정책은 별도로 필요하다.

## 6. Durability 등급

| 등급 | 성공의 의미 | 기본 |
|---|---|---|
| process | atomic visibility와 process crash 후 journal reconciliation 목표; 전원 손실 내구성 미약속 | 일반 코드 편집 |
| durable | temp/journal/file/parent persistence를 플랫폼에서 검증한 순서로 수행 | 명시 요청 |
| strongest_available | macOS F_FULLFSYNC 등 지원 기능 추가, 비용 측정 | 실험 옵션 |

`fsync`와 macOS `F_FULLFSYNC`의 의미는 동일하지 않으며 저장 장치 전체 실패까지 보장하지 않는다. [R25](../references/SOURCES.md#R25) durable 요청인데 필요한 directory persistence를 검증하지 못한 플랫폼은 `E_UNSUPPORTED`로 커밋 전에 거부한다. 커밋 후 persistence가 실패하면 `applied=true,durable=false,error=E_DURABILITY`로 보고한다.

## 7. 저장공간과 GC

cache/state는 source tree 밖 사용자 전용 directory 아래 둔다. default disk cache는 disabled이며 enabled profile은 최대 1 GiB, 전체 대상 filesystem 가용 공간 10% 미만일 때 새 persistent cache 쓰기를 중단한다. journal은 source recovery에 필요하므로 일반 cache GC와 분리한다.

다른 workspace가 pin한 immutable content는 cache GC가 제거하지 않는다. parse tree binary serialization은 Tree-sitter ABI/version 안전성이 별도 검증되지 않으면 저장하지 않는다. persistent line index는 versioned header·content hash·offset bound·checksum을 검증하고 손상 시 재생성한다.

## 8. 파일명·내용 예외

v1 path는 valid UTF-8만 지원한다. Linux의 임의 non-UTF8 filename은 count와 오류로 표시하고 조용히 문자열을 변조하지 않는다. 내용은 UTF-8 text만 수정하며 binary read는 capability 없는 한 `E_UNSUPPORTED`다. CRLF/LF 혼합, BOM, 마지막 newline 유무는 bytes 그대로 유지한다. case-insensitive volume에서도 lowercasing 경로를 identity로 삼지 않는다.
