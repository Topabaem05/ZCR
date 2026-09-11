# 14 · Codex/Claude 통합 · 운영

## 1. 내장 tool 대체의 실제 의미

MCP server를 등록하면 새로운 tool이 사용 가능해질 뿐 기존 Read/Grep/Write가 자동으로 교체되는 것은 아니다. host 정책·tool descriptions·agent instructions가 사용을 유도해야 한다. **MCP 등록 성공, 실제 호출 성공, 반복 workflow에서 선택됨, E2E 개선**을 별개의 gate로 둔다. [R12](../references/SOURCES.md#R12)[R13](../references/SOURCES.md#R13)

기본 tool description은 무엇을 언제 써야 하는지 짧게 안내한다. “모든 읽기는 무조건 빠르다” 같은 미검증 우월성 문구를 넣지 않는다. 네임스페이스 `zcr_*`로 구분하고 host 내장 tool을 가로채지 않는다.

## 2. 설치 예시

Codex의 MCP는 사용자 `~/.codex/config.toml` 또는 신뢰한 프로젝트 설정에서 stdio command를 등록한다. 아래 command와 paths는 **예시**이며 사용자 설정을 자동 수정한 것이 아니다. [R12](../references/SOURCES.md#R12)

```toml
[mcp_servers.zcr]
command = "/absolute/path/to/zcr"
args = ["mcp", "--standalone", "--policy", "/absolute/path/to/approved-policy.json"]
```

Claude Code는 `.mcp.json`의 stdio 서버 또는 CLI 등록을 사용한다. 저장소에 policy token을 commit하지 않는다. [R13](../references/SOURCES.md#R13)

```json
{"mcpServers":{"zcr":{"type":"stdio","command":"/absolute/path/to/zcr","args":["mcp","--standalone","--policy","/absolute/path/to/approved-policy.json"]}}}
```

policy의 state=planned 예시는 실행 불가다. host가 실제 workspace identity·task scope를 바인딩하고 승인해야 active가 된다. 외부 docs의 최신 CLI 옵션과 대상 host 설치 버전이 다를 수 있으므로 T23에서 `--help`와 실제 handshake로 검증한다.

## 3. Agent 사용 지침 예시

> 코드 위치를 모르면 zcr_search에서 literal과 좁은 glob을 먼저 사용한다. 반환된 context가 충분하면 같은 파일을 전체 Read하지 않는다. 독립 파일 여러 개는 zcr_batch_read로 묶는다. 수정 전에는 write_intent read로 whole-file digest를 얻는다. patch는 반환 digest와 original byte spans를 사용한다. E_VERSION_CONFLICT가 발생하면 새 내용을 읽고 변경을 다시 구성한다. 권한 거부를 우회하기 위해 다른 root나 shell tool을 사용하지 않는다.

지침은 host의 기존 안전·승인 정책보다 상위 권한이 아니다. 실제 agent가 불편하게 byte offset을 계산한다면 별도 host-side diff adapter를 검토할 수 있지만 ZCR 안에서 fuzzy patch를 조용히 적용하지 않는다. 처음에는 좁은 검색으로 반환 byte spans를 재사용하는 실험을 한다.

## 4. 시작·종료

standalone 시작은 policy 검증→identity 확인→journal recovery→resource cap→MCP initialization 순서다. startup에서 전체 repository index 완료를 기다리지 않는다. 필요한 파일부터 lazy read하고 scan은 예산 안에서 후순위로 수행한다.

종료는 신규 admission 중단→취소 통지→callback drain→미커밋 temp 정리→journal flush→watcher/FD close다. 일정 시간을 넘긴 shutdown은 source write 강제 재시도 없이 recovery record를 보존하고 종료한다. kill -9에서도 다음 시작의 상태 판정이 가능해야 한다.

## 5. Broker 운영

운영자가 broker를 명시적으로 띄운 뒤 각 host는 bridge를 통해 연결한다. broker path와 token은 source tree 밖 current-user-only 공간에 둔다. client 16개 제한, workspace별 active writer1, low-RAM active tasks2의 초기값을 적용한다. 더 많은 session은 대기/거부한다.

broker가 없으면 silent 자동 시작하지 않고 명확한 오류와 standalone 가능 여부를 표시한다. 자동 spawn/daemonize가 보안·lifecycle을 바꾸므로 별도 승인 없이 동작하지 않는다. broker crash 후 bridge는 자동 write 재전송하지 않고 receipt 확인 절차를 따른다.

## 6. 상태·로그

health는 build/schema version, actual backend, supported capabilities, memory limits/current estimates, queue depth, usable concurrency, QoS policy, pressure/thermal signal availability를 제공한다. 특정 core 번호에 배치됐다고 추정 출력하지 않는다.

status는 현재 session의 workspace incarnation, task/fence expiry, dirty/index state, 마지막 receipt만 제공한다. 다른 client의 path/query는 노출하지 않는다. observability는 bounded counters/ring이며 tracing 활성화로 메모리가 무제한 늘지 않는다.

## 7. 실패 시 운영 행동

memory warning은 cache 축소 및 concurrency 감소를 자동 수행한다. 파일 버전 충돌은 사용자가 읽은 내용이 낡았다는 뜻이다. watcher overflow는 background rescan 또는 checked-live fallback이며 source 손상은 아니다. UNCERTAIN receipt는 해당 경로 write를 잠그고 원본/새 hash와 실제 파일을 사람이 비교하도록 안내한다.

## 8. 사용자 설정 범위

기본 profile은 balanced다. 사용자는 latency, throughput, model_coexist 중 선택할 수 있다. memory cap과 max workers는 낮출 수 있고, 높일 때도 policy hard limits와 actual memory headroom을 넘지 못한다. environment variable로 policy를 우회하는 hidden override는 두지 않는다.
