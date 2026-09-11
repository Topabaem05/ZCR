# 10 · x86 및 다른 운영체제의 작동 구성

## 1. OS와 CPU ISA를 분리한다

Apple Silicon의 GCD는 CPU 명령어 세트가 아니라 macOS 플랫폼의 scheduler다. **Intel Mac에서도 같은 public GCD adapter를 사용**하며 NEON scanner만 scalar/x86 SIMD로 바뀐다. Linux x86의 I/O, watcher, QoS 정책은 별도 backend다. Rust/Python으로 코어를 다시 구현하지 않는다.

| 대상 | v1 지위 | scheduler | watcher | ISA baseline |
|---|---|---|---|---|
| macOS arm64, macOS 13+ | 우선 release 후보 | bounded threaded → 검증된 GCD | FSEvents | AArch64 scalar/NEON |
| macOS x86_64, macOS 13+ | v1 release 후보 | same Darwin adapter | FSEvents | x86-64 baseline |
| Linux x86_64, Ubuntu 24.04 계열 | v1 release 후보 | bounded threads + blocking read | inotify | x86-64 baseline |
| Linux arm64 | 후속 portability 확인 | same Linux adapter | inotify | scalar/NEON |
| macOS 11 Intel / 8 GiB 구형 Mac | 별도 compatibility spike | available API subset | probe | baseline, optional SIMD |
| Windows 11 x86_64 | T18 선택 단계 | bounded thread pool | ReadDirectoryChangesW | baseline + feature dispatch |

이 표는 **설계상 지원 목표**이지 CI를 통과한 현재 지원 목록이 아니다. Zig 0.16 compiler와 SDK가 각 minimum deployment target에서 실제 linking/running하는지 T00/T24가 확인한다. 구형 macOS 11은 Foundation API 부재와 SDK deployment 문제를 통과하기 전까지 지원한다고 표시하지 않는다.

## 2. 공통 platform interface

`PlatformFs`, `TaskExecutor`, `PressureSource`, `WatchSource`, `Clock`, `PeerIdentity`의 typed interface를 사용한다. Linux 문자를 Apple 모듈에서 import하거나 public types에 Darwin/Windows 구조체를 넣지 않는다. filesystem handle은 opaque tagged union이며 호출자가 fd 숫자를 권한처럼 조작하지 않는다.

## 3. x86 scanner

baseline 배포물은 SSE2를 사용할 수 있는 x86-64 범위를 기준으로 하되 첫 정답 경로는 scalar다. AVX2/AVX-512는 optional dispatch이며 CPUID뿐 아니라 OSXSAVE/XGETBV 등 OS 상태 지원을 확인한 후 활성화한다. 실제 요구 feature bits는 구현한 intrinsic/명령 집합 기준으로 T19에서 고정한다. `-mcpu=native` 바이너리를 일반 배포물로 배포하지 않는다.

AVX-512를 사용할 수 있어도 항상 선택하지 않는다. 짧은 입력, downclock, 메모리 bandwidth 및 혼합 workload에서는 이점이 없을 수 있으므로 benchmark 정책으로 선택한다. vector load는 할당 경계를 넘어 읽지 않으며 last partial block을 scalar/masked safe path로 처리한다. page-guard fuzz로 증명한다.

## 4. Linux resource policy

usable concurrency는 visible physical/logical CPU, `sched_getaffinity` 가능한 mask, cgroup cpu quota를 함께 고려한다. quota는 exclusive core 수가 아니므로 CPU permits의 보수적 초기값에 반영한다. memory limit은 host physical RAM과 cgroup `memory.max` 중 유효한 작은 값을 사용하고 `memory.current/high`, PSI availability를 감지한다. [R18](../references/SOURCES.md#R18)[R19](../references/SOURCES.md#R19)

foreground workers는 기본 scheduling class를 유지한다. 유지보수는 허용된 nice 값/idle policy를 선택적으로 적용하며 root권한을 요구하거나 real-time scheduling을 사용하지 않는다. Linux heterogeneous Intel CPU에서도 CPU 이름을 보고 E-core mask를 추측해 고정 pin하지 않는다. 시스템 scheduler와 workload-specific measurement가 우선이다.

v1은 blocking read + bounded workers가 정답 backend다. `io_uring`은 기능이 필요할 때 별도 실험 backend로 추가하며 Zig 0.16의 PoC Uring 구현을 안정성 근거로 삼지 않는다. [R02](../references/SOURCES.md#R02)

## 5. Linux 경로 보호

지원되는 kernel에서는 `openat2`의 beneath/no-symlink/no-magiclink resolution을 검증해 사용한다. 부재 시 directory descriptor walk와 `O_NOFOLLOW`를 사용한다. filesystem boundary를 넘는 read가 필요한지 policy로 분리한다. [R20](../references/SOURCES.md#R20)

어떤 backend도 악의적인 동일 UID 프로세스가 parent directory를 동시에 이동시키는 모든 상황까지 path 문자열 policy만으로 막는다고 주장하지 않는다. 엄밀한 공격자 격리는 host sandbox/권한 분리·전용 writable directory를 필요로 한다.

## 6. Windows 후속 범위

UTF-8 API path를 UTF-16로 변환하되 drive/UNC/ADS/device path를 별도로 차단한다. case folding만으로 identity를 만들지 않고 volume/file ID를 사용한다. reparse point 정책을 검사하고 named pipe의 current-user ACL과 peer 인증을 검증한다. 동일 사용자라 해도 임의 프로세스가 쓰기 capability를 얻지 못하도록 host-issued token을 요구한다.

EcoQoS는 배경 작업의 전력/스케줄링 의도를 전달하는 선택지다. thread priority와 동일한 개념도 아니고 특정 E-core 배치 보장도 아니다. API availability 및 foreground 복원 시험을 통과한 뒤 사용한다. [R21](../references/SOURCES.md#R21) macOS FSEvents, POSIX rename, unix permissions를 그대로 번역한 척하지 않는다.

## 7. 배포와 테스트

최소 산출물은 `aarch64-macos`, `x86_64-macos`, `x86_64-linux` release candidates이며 각각 실제 OS 실행 시험이 필요하다. cross-compile 성공만으로 런타임 지원이라고 표시하지 않는다. 빌드 mode별 Debug/ReleaseSafe 정답 시험과 ReleaseFast 성능 시험을 분리한다. ReleaseFast에서 안전 검사 제거로만 얻은 가속은 fuzz/차등검증 실패 시 채택하지 않는다.

OS 지원이 없는 기능은 capability=false와 fallback 이유를 health에 내보낸다. watcher/thermal signal 하나가 없다고 기본 read/search를 중단하지 않는다. 단, 안전한 write publish/durability primitive가 없으면 해당 쓰기 기능만 비활성화한다.

## 8. Zig 0.16 codegen 검증

0.16 release notes는 LLVM 회귀 회피를 위해 loop vectorization을 비활성화했다고 설명한다. scalar loop가 자동으로 NEON/AVX로 바뀔 것이라고 가정하지 않는다. T00은 compiler/backend/flags를 고정하고 T19는 emitted assembly와 차등 시험으로 실제 SIMD 경로를 검증한다. 특정 차기 버전에서 해결될 것이라는 예상은 현재 지원 조건으로 사용하지 않는다. [R02](../references/SOURCES.md#R02)

같은 release에서 std.Thread.Pool이 제거됐다. 본 문서의 bounded worker/executor는 제품의 추상화 이름이지 제거된 표준 API 사용 지시가 아니다. std.Io를 쓰는 경로의 synchronization primitive는 동일 Io 계약과 맞추고, native GCD 경로와 섞을 때 lifetime·blocking 경계를 G02에서 시험한다. [R02](../references/SOURCES.md#R02)
