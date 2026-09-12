# T00 · 측정 기준선과 플랫폼 spike 결과

**Task:** T00 · **시험:** PF-001 · **Gate:** G01/G03/G04/G06 · **기록일:** 2026-09-11
**source commit:** `4dbd5e9` (구현) · **RED commit:** `6406fa7` · **base:** `7eeab60`

이 문서는 T00 probe가 한 대의 Mac에서 실제로 관찰한 값만 적는다. ZCR runtime은 아직 없으므로 성능 수치는 없다. 원본 기록은 [`evidence/T00/`](../evidence/T00/)에 있다.

## 1. 측정 환경

| 항목 | 값 | 출처 |
|---|---|---|
| 기종 | Mac14,2 · Apple M2 · aarch64 | `hw.model`, `machdep.cpu.brand_string` |
| CPU | ncpu 8 · physical 8 · logical 8 | `hw.ncpu/physicalcpu/logicalcpu` |
| 성능 계층 | perflevel0 `Performance` 4/4 · perflevel1 `Efficiency` 4/4 | `hw.nperflevels`, `hw.perflevelN.*` |
| RAM · page | 8 GiB (8,589,934,592 bytes) · 16 KiB | `hw.memsize`, `hw.pagesize` |
| OS | macOS 26.6.2 (build 25G83) · Darwin 25.6.0 | `kern.osproductversion`, `kern.osversion`, `uname` |
| Zig | 0.16.0 공식 tarball · binary SHA-256 `e6cd688d…d13a4ec` | `builtin.zig_version_string`, 파일 digest |
| C 컴파일 SDK 매크로 | `__MAC_OS_X_VERSION_MIN_REQUIRED=260602`, `MAX_ALLOWED=260500` | darwin_abi.c |
| Foundation | `NSFoundationVersionNumber=5026.6` | darwin_abi.c |
| Git | 2.47.0 (`/opt/homebrew/bin/git`) | `git --version` |
| B1 도구 | ripgrep 15.1.0 · fd 없음(absent) | PATH 탐색 + `--version` |
| B0 host | Claude Code 2.1.268 · codex-cli 0.153.4 | `--version` (버전만) |
| 캡처 시각 | 2026-09-11T09:31:25Z | `Io.Clock.real` |

캡처 시점 상태: 전원 AC, Low Power Mode 꺼짐, thermal `nominal`, `kern.memorystatus_vm_pressure_level=2`(warn). 8 GiB 장비가 이미 메모리 경고 상태였으므로 이 조건에서 얻은 수치를 다른 상태와 섞어 비교하지 않는다.

**Cache:** page cache 상태는 통제하지 않았으므로 `unknown`이다. Zig cache와 TMPDIR은 `$STATE/tasks/T00/` 아래 task 전용 경로를 사용했다.

**Corpus:** `zcr-design-package@7eeab60` — `git archive 7eeab60`을 푼 디렉터리. 정규 파일 120개, 1,099,130 bytes, digest `539e0917…77edbe1f`. digest는 정렬된 `"<sha256>  <경로>\n"` 줄의 SHA-256이며, `find | sort | shasum` 파이프라인으로 따로 계산한 값과 일치했다. 이 corpus는 T21의 C-small/C-medium을 대체하지 않는다.

## 2. Gate 판정

| Gate | 판정 | 근거 |
|---|---|---|
| G01 Zig0.16 + Mac SDK compile/link/run | **PASS** | `zig test`/`build-exe`가 C 파일과 Foundation·IOKit·CoreFoundation을 링크했고, 실행 중 GCD callback이 돌았다. |
| G03 pressure/thermal/low-power | **PASS** | `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source 생성·활성화 성공, `NSProcessInfo.thermalState`와 `isLowPowerModeEnabled`가 응답했다. |
| G04 perflevel sysctl | **PASS** | 조회한 sysctl key 중 누락 0. 계층별 physical/logical 합이 전체 CPU 수와 같다. |
| G06 Git worktree identity | **PASS** | `rev-parse --show-toplevel/--absolute-git-dir/--path-format=absolute --git-common-dir/HEAD`, `worktree list --porcelain -z`, `status --porcelain=v2 -z`가 모두 exit 0. linked worktree에서 `.git`은 파일, git-dir과 common-dir이 서로 다르다. |

판정은 이 한 대의 장비·OS·SDK 조합에 대한 것이다. G03 PASS는 신호를 **읽을 수 있다**는 뜻이며 pressure 이벤트 전달이나 thermal 변화 대응은 시험하지 않았다(T16 범위). GCD probe는 `USER_INITIATED` queue에서 callback이 `qos_class_self()=user_initiated`를 관찰했다. 실제 core 배치는 확인하지 않았다.

## 3. 설계에 영향을 주는 관찰

1. **thermal C API:** `OSThermalNotificationCurrentLevel`은 macOS SDK 헤더에서 `__OSX_AVAILABLE_STARTING(__MAC_NA, __IPHONE_2_0)`이다. macOS thermal 상태는 Objective-C runtime으로 `NSProcessInfo`를 읽어야 한다.
2. **deployment target이 SDK보다 높다:** native 빌드의 C 매크로가 min 26.6.2, max(SDK) 26.5로 나왔다. 배포 바이너리(T24)는 deployment target을 명시적으로 고정해야 한다.
3. **바이너리 digest가 재현되지 않는다:** 같은 source와 같은 출력 경로로 두 번 빌드해도 `LC_UUID`와 ad-hoc 서명 영역(약 128 bytes)이 달라 SHA-256이 바뀐다. 따라서 binary digest는 "그 빌드 산출물"을 식별할 뿐 source를 식별하지 않는다. 시험한 바이너리는 `$STATE/tasks/T00/bin/`에 보존했다. 원인은 추적하지 않았다.
4. **Zig 0.16 `std.process.run`은 기본으로 PATH를 검색하지 않는다**(`expand_arg0 = .no_expand`). T00 코드는 PATH를 직접 해석해 절대 경로로 실행한다.
5. **`std.testing.tmpDir`은 현재 작업 디렉터리에 `.zig-cache/tmp`를 만든다.** worktree 오염을 막기 위해 테스트 바이너리를 `$STATE/tasks/T00/tmp`에서 실행한다.
6. **fd가 설치되어 있지 않다.** B1 파일 목록은 `git ls-files` 또는 ZCR 자체 탐색과 비교해야 한다.

## 4. 명령

T01의 build runner가 아직 없으므로 `zig test`를 직접 사용한다. `$STATE=/Users/guribbong/code/ZCR-state/tasks/T00`, `ZIG=$HOME/.local/share/zig/0.16.0/zig`. 환경 변수 `ZIG_GLOBAL_CACHE_DIR=$STATE/zig-global-cache`, `ZIG_LOCAL_CACHE_DIR=$STATE/zig-local-cache`, `TMPDIR=$STATE/tmp`를 설정한다. 명령은 task worktree 루트에서 실행한다.

시험(Debug/ReleaseSafe 각각):

```sh
$ZIG test --test-no-exec -femit-bin=$STATE/bin/t00_test-green-debug -ODebug \
  --dep caps -Mroot=tests/t00_test.zig \
  -lc -framework Foundation -framework IOKit -framework CoreFoundation \
  -ODebug bench/spikes/darwin_abi.c -Mcaps=bench/spikes/caps.zig
(cd $STATE/tmp && $STATE/bin/t00_test-green-debug)
```

C 파일은 뒤따르는 `-M` 모듈에 붙으므로 `-Mcaps` 앞에 둔다.

기준선 캡처:

```sh
$ZIG build-exe -OReleaseSafe -femit-bin=$STATE/bin/caps-4dbd5e9 \
  -lc -framework Foundation -framework IOKit -framework CoreFoundation \
  bench/spikes/darwin_abi.c bench/spikes/caps.zig
(cd $STATE/tmp && $STATE/bin/caps-4dbd5e9 --repo <task-t00 worktree> \
  --corpus $STATE/corpus/zcr-design-package-7eeab60 --corpus-id zcr-design-package@7eeab60 \
  --zig $ZIG --host-tools --out $STATE/baseline.json)
```

`caps`는 validate 실패 시 exit 2, 인자 오류 시 exit 64를 반환한다.

## 5. 시험 결과

| 실행 | source | 결과 | test binary SHA-256 |
|---|---|---|---|
| RED Debug | `6406fa7` | 0 passed · 11 failed · exit 1 | `05f0a46d…068cb89e` |
| GREEN Debug | `4dbd5e9` | 11 passed · exit 0 | `bbb8c4dd…01eeb732` |
| GREEN ReleaseSafe | `4dbd5e9` | 11 passed · exit 0 | `9c5aa1d1…50236f76` |
| 기준선 캡처 ReleaseSafe | `4dbd5e9` | exit 0 · 4 gates PASS | caps `2c7a637a…d94dfe10` |

RED에서 11개 시험은 모두 `NotImplemented` 또는 미구현 상태 값으로 실패했다. 준비 코드 오류 두 건(PATH 미검색, argv 첫 인자 누락)은 RED 기록 전에 고쳤다. 시험은 정상 경로 외에 corpus 경로 없음(I/O), 파일 수·byte 한도 초과(예산), cold cache 무근거 주장, gate 누락, 컴파일러 버전 불일치 거부를 포함한다.

## 6. 미실행과 남은 gate

- **B0 host 내장 도구 latency trace:** 미수집. Claude Code·Codex 버전만 기록했다. host transcript의 timestamp는 승인 대기 시간을 포함하므로 T21/T23에서 계측 방법을 정한 뒤 수집한다.
- **cancellation:** GCD probe의 timeout 경로(callback 메모리 유지)는 결정적으로 재현할 수 없어 시험하지 않았다.
- **NOT_RUN:** Intel Mac, x86-64 Linux, Windows, G11(macOS 11), 물리 에너지 측정, 통제된 cold cache.
- **설계 문서 불일치:** `tasks/T00.md`는 `tests/t00_test.zig`를 요구하지만 `tasks/tasks.json`의 T00 `owns`에는 없다. `tests/catalog.json`의 PF-001 `execution_status`는 T00 소유가 아니라 갱신하지 않았다. 둘 다 통합자 결정이 필요하다.
