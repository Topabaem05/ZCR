# 08 · API · MCP 계약

## 1. Transport와 신뢰 경계

기본 실행은 `zcr mcp --standalone --policy /absolute/policy.json`이다. 이것은 구현 예정 CLI 계약이며 현재 실행 파일이 제공되는 것은 아니다. host가 승인한 policy에 workspace·task를 바인딩한다. 모델의 tool arguments에는 임의 root, shell command, Git 환경변수, 새로운 task capability가 없다.

MCP 호환 기준은 **2025-11-25**로 고정하고 초기 handshake에서 protocol version과 capabilities를 협상한다. 지원되지 않는 버전을 조용히 흉내 내지 않는다. JSON-RPC id와 tool request id는 별도로 보존한다. custom `zcr_batch_read`는 MCP/JSON-RPC batch-array 지원을 뜻하지 않는다. stdio framing은 UTF-8 JSON 한 레코드+개행이며 stdout에는 protocol 데이터만 기록한다. [R14](../references/SOURCES.md#R14)

## 2. 최소 tool 집합

| tool | 입력 핵심 | 출력 핵심 | 권한 |
|---|---|---|---|
| zcr_read | path, start_line, line_count, write_intent | lines, raw-byte offsets, version | read |
| zcr_files | glob, limit, consistency | normalized relative paths, coverage | enumerate |
| zcr_search | literal, glob, context_lines, limit | matches + coalesced context | search |
| zcr_batch_read | items[1..32] | ordered item results/errors | read |
| zcr_patch | path, expected_sha256, replacements, idempotency_key | single-file receipt | patch |
| zcr_create | path, content, idempotency_key | no-overwrite receipt | create |
| zcr_status | optional receipt_id | task/workspace generation, receipt | own-session status |
| zcr_health | empty object | limits, pressure, capability state | own-session diagnostics |

모든 tool에 외부 계약의 `output_bytes`/`deadline_ms`가 적용된다. JSON Schema는 `contracts/tools.json`에 수록한다. schema 검증만으로 filesystem/security budget 검사가 끝나지 않는다. path의 **UTF-8 byte 길이**와 숫자 덧셈 overflow는 runtime에서 별도로 검사한다.

`zcr_search`는 v1에서 literal만 지원한다. 검색어는 빈 문자열을 금지하고 최대 4,096 UTF-8 bytes다. 기본은 case-sensitive, Unicode normalization 없음이다. case-insensitive/regex를 임의로 추정하지 않는다. literal에 정규식 문자가 있더라도 그 문자 자체를 검색한다.

## 3. 출력 프로필

기본 `text_v1`은 MCP `content`의 text block 한 개에 compact logical response JSON을 담는다. 동일 결과를 structuredContent와 text에 두 번 싣지 않는다. 이 모드에서는 tools discovery에 `outputSchema`를 광고하지 않는다.

별도 `structured_compat`는 logical response를 `structuredContent`에 담고 호환성 text copy도 함께 제공한다. MCP 사양의 structured output 호환 권고를 따른다. 두 표현의 **총 직렬화 byte**를 측정해 output budget을 적용하며, 실제 host가 중복 모델 입력을 만들지 않는지 검증한 후에만 사용한다. [R15](../references/SOURCES.md#R15)

```json
{
  "schema_version": "zcr/1",
  "request_id": "fixture-request-01",
  "workspace_id": "fixture-workspace-A",
  "generation": 7,
  "ok": true,
  "complete": true,
  "truncated": false,
  "consistency": "checked_live",
  "coverage": {"scope": "requested_files", "skipped": 0, "index_state": "live"},
  "data": {"items": []},
  "error": null,
  "meta": {"elapsed_us": 120, "returned_bytes": 0, "cache": "miss"}
}
```

위 elapsed 값은 **형식 설명용 fixture**이며 벤치마크가 아니다. 생산 응답은 실제 monotonic clock으로 측정한다. 모든 결과는 버전/coverage를 포함하되 진단용 세부 타이밍은 host 옵션으로 생략할 수 있다. `returned_bytes`는 재귀적으로 자체 문자열 길이를 계산하지 않도록 **data payload의 UTF-8 직렬화 길이**로 정의한다. transport 전체 byte는 telemetry 별도 항목이다.

## 4. 줄·바이트·버전

줄 번호는 1부터, byte span은 원본 bytes 기준 **0-based [start,end)**다. LF가 줄 경계를 만든다. CRLF의 CR도 원본 byte에 포함한다. 줄 반환에서 LF/CRLF를 보존하고 display 행 번호는 별도 필드다. EOF의 빈 마지막 줄 처리 규칙은 `tests/vectors.json`을 따른다.

`write_intent=false`의 read는 범위만 읽을 수 있으며 whole-file `sha256`는 null일 수 있다. `write_intent=true`는 8 MiB 이하 전체 bytes를 확인해 digest를 반환한다. 범위 hash를 whole-file hash로 표기하는 것은 금지다. 쓰기용 version token에는 workspace incarnation과 root identity 검증 상태도 결합한다.

`replacements`는 original byte spans 기준으로 정렬되어 있어야 한다. span 중복, 범위 overflow, UTF-8 codepoint 중간 분할을 거부한다. 같은 위치에 여러 insertion을 주는 모호한 요청도 거부한다. 예상 결과 hash는 전체 합성 후 계산한다.

## 5. 출력·검색 완결성

최대 결과·file size·deadline·policy filtering을 각각 구분한다. `complete=true`는 요청의 명시된 검색 범위와 policy 안에서 전체 결과를 수집했다는 뜻이지, 숨겨진 파일/ignored 파일까지 검색했다는 뜻이 아니다. `coverage`에 effective filters, skipped binary/oversize/unreadable counts를 담는다. unreadable 또는 중간 변경 때문에 요청 범위를 다 확인하지 못하면 complete=false다.

v1은 continuation cursor를 구현하지 않는다. cap 도달 시 `truncated=true`, 이유와 더 좁힐 수 있는 경로/필터 힌트를 반환한다. 오류인데 빈 성공 배열로 위장하지 않는다. 후속 cursor는 generation·policy digest에 바인딩하는 별도 ADR 대상이다.

## 6. 오류와 재시도

| code | 의미 | 자동 재시도 규칙 |
|---|---|---|
| E_INVALID_ARGUMENT | schema, range, UTF-8, overlap 오류 | 입력 수정 필요 |
| E_SCOPE / E_PATH_ESCAPE | root/task 권한 밖 | 금지 |
| E_UNSUPPORTED | 미지원 operation/consistency/platform | capability 확인 |
| E_NOT_FOUND / E_NOT_REGULAR | 없음, 디렉터리·device 등 | 사용자 의도 확인 |
| E_VERSION_CONFLICT | 읽은 뒤 콘텐츠 변경 | 다시 읽고 새 patch 생성 |
| E_LEASE / E_FENCE | writer 권한 만료·교체 | host가 재바인딩 |
| E_BUSY / E_RESOURCE | queue, FD, memory 부족 | 제한된 backoff, deadline 유지 |
| E_OUTPUT_BUDGET | 결과 표현 예산 초과 | 범위를 좁힘 |
| E_CANCELLED / E_DEADLINE | 커밋 전 중단 | read는 가능, write receipt 확인 |
| E_IO / E_DURABILITY | I/O 또는 persistence 실패 | applied/receipt 먼저 확인 |
| E_RECOVERY_REQUIRED | commit 여부 불명확 | 쓰기 차단, status 확인 |
| E_INTERNAL | 불변조건 위반 | workspace quarantine |

Tool 실행 오류는 MCP tool result `isError=true`와 logical error로 보고한다. 잘못된 JSON-RPC 형식/없는 method는 JSON-RPC 수준 오류다. 하나의 failure를 두 수준에서 중복 response하지 않는다.

## 7. Idempotency

변경 요청 키는 `(security_domain,workspace_incarnation,task_id,idempotency_key)`다. 같은 key+같은 canonical operation digest는 기존 receipt를 반환한다. 같은 key+다른 payload는 `E_INVALID_ARGUMENT`이며 재실행하지 않는다. key는 128 bytes 이하 ASCII printable이며 완료 ledger를 24 h 또는 workspace 종료까지 보존한다. ledger 최대 10,000 entries에 도달하면 만료 항목만 제거하고, 안전한 공간이 없으면 새로운 변경 요청을 거부한다. 무응답 후 새 key를 발급해 같은 patch를 맹목적으로 반복하지 않는다.

## 8. 요청 유효성 및 parser 한도

JSON nesting 최대 64, duplicate key 금지, NaN/Infinity 금지, integer 범위 엄격 검사, unknown tool fields 거부, raw frame 16 MiB에서 선행 차단한다. decode하기 전에 최소 input buffer credit을 확보한다. 작은 전역 control budget으로 `health/cancel`에 대한 최소 응답 여지를 남긴다. cancel은 해당 session의 request만 대상으로 한다.
