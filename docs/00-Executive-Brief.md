# 00 · 설계 요약과 판단 기준

## 1. 해결하려는 병목

모델이 빠르게 다음 행동을 결정해도 `search → read → search → read → edit`가 직렬로 지연되면 개발 작업의 완료 시간은 크게 줄지 않는다. 그러나 기존 도구가 모두 Python이거나 파일 읽기가 실제 주된 병목이라는 전제는 채택하지 않는다. **첫 구현 task는 병목 분해 측정**이다.

전체 시간을 다음처럼 분리한다.

```text
T_task = T_model_prefill + T_model_decode + T_tool_critical_path
       + T_host_orchestration + T_approval + T_retry + T_build_test
T_tool = T_queue + T_auth + T_discovery + T_io + T_scan_parse
       + T_projection + T_serialize + T_transport
```

병렬 tool의 시간은 단순 합이 아니라 의존성 그래프의 critical path로 계산한다. decode tok/s와 `정답 작업 수/분`은 서로 다른 지표다. 예를 들어 모델·기타 시간이 2초, 도구가 8초인 가상 작업에서 도구를 2초로 줄이면 총 10→4초지만, 도구가 0.2초인 작업에서는 같은 최적화의 이득이 작다. 이 숫자는 산술 예시다.

## 2. 선택한 구조

**A안: 직접 stdio + Zig 엔진**을 기본으로 채택한다. `read/search/files/batch_read/patch/create/status/health`를 제공하고, tool-call 한 번에 필요한 문맥을 반환한다. 한 세션 동안 프로세스가 유지되므로 매 Read마다 Python 또는 CLI를 새로 띄우는 구조를 전제하지 않는다.

**B안: 공유 broker + 매우 얇은 stdio bridge**는 다중 worktree·다중 세션의 자원 경쟁이 확인된 경우에 활성화한다. OS별 IPC를 쓰되 내부 메시지도 우선 JSON을 쓴다. 바이너리 프로토콜은 전체 도구 시간의 15% 이상이 직렬화/파싱이라는 측정이 있을 때만 ADR을 변경해 도입한다.

**C안: 매 요청마다 단발 CLI만 실행**은 호환성과 비교 baseline으로 남긴다. 설치가 간단하지만 프로세스 시작·캐시 재사용에서 불리할 수 있으므로 기본 데이터 경로로 삼지 않는다.

## 3. 이전 논의에서 보정한 사항

| 기존 가정 | 이번 설계의 처리 |
|---|---|
| Zig라면 Rust보다 자동으로 빠르다 | 가정하지 않는다. 동일 의미·동일 출력으로 비교한다. |
| 모든 Mac에 슈퍼·성능·효율 코어가 각각 있다 | 잘못된 일반화다. 코어 계층을 실행 시 탐지한다. |
| Apple의 에너지 코어라는 별도 제4 유형 | 이 문서에서는 효율 코어(E)의 비공식 표현으로 해석한다. |
| `std.Io.Dispatch`가 있으므로 바로 기반으로 사용 | Zig 0.16의 evented 계열은 실험적이다. 프로덕션 경로와 분리한다. [R02](../references/SOURCES.md#R02) |
| MCP/JSON이 주된 오버헤드다 | trace로 확인하기 전에는 추가 프로세스·binary RPC를 만들지 않는다. |
| mmap은 복사도 메모리 사용도 없다 | resident page·page fault 비용이 있다. 수정 가능한 원본의 mmap은 기본 금지한다. [R26](../references/SOURCES.md#R26) |
| watcher만 있으면 항상 최신 검색 결과다 | watcher는 무효화 힌트다. 현재성 검증과 재탐색이 필요하다. [R08](../references/SOURCES.md#R08) |
| 모든 파일에 원자적 다중 편집을 제공한다 | v1은 **파일 하나의 교체**만 원자적 가시성을 다룬다. 다중 파일 트랜잭션은 제공하지 않는다. |

Apple은 M5 Pro/Max의 18코어 구성을 슈퍼 6개·새 성능 코어 12개로 설명한다. 이 사실을 과거 P/E 체계나 모든 SKU에 그대로 대입하지 않는다. [R04](../references/SOURCES.md#R04)

## 4. 단계별 범위

**R0 관측·계약:** tool latency 측정, 형식·권한·task manifest, 플랫폼 spike.

**R1 안전한 core:** read/files/literal search, 문맥 반환, batch, single-file patch/create, stdio MCP, 제한된 메모리.

**R2 다중 작업:** global broker, workspace actor, scoped lease, immutable content cache, watcher와 복구, macOS QoS 조정, x86 Linux.

**R3 선택 확장:** ARM64 NEON/x86 AVX2, Tree-sitter outline/구문 검색, Windows 네이티브 및 배포 하드닝. 정확한 언어 서버 기반 reference는 별도 프로파일이며 기본 footprint 목표에서 제외한다.

## 5. 하지 않는 일

자체 LLM inference, GPU/ANE 코드 검색, 임베딩 서버, 범용 shell, 자동 Git push/merge, 무제한 전체 레포 packing, arbitrary plugin 실행은 제외한다. 대형 regex 엔진 재구현도 R1의 목적이 아니다. Regex 요청은 명시적 호환 모드에서 검증된 `rg` 외부 adapter를 사용할 수 있으나 기본 Zig 단독 모드에는 포함하지 않는다. [R24](../references/SOURCES.md#R24)

## 6. 최종 판정

출시 판단은 `isolated-task success`, p95 도구 대기, aggregate footprint, 에너지/정답 작업, 실제 모델 선택률로 한다. `grep 한 번이 5% 빠르다`만으로 성공이라고 하지 않는다.
