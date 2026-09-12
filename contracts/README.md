# 계약 파일 사용법

`tools.json`은 eight-tool discovery template이며 실제 server는 enabled capabilities만 반환한다. `inputs/*.schema.json`은 각 입력을 독립 검증한다. `response.schema.json`은 logical envelope, `data.schema.json`의 `$defs`는 tool별 data payload다. 기본 text_v1의 MCP content 안에 이 envelope가 직렬화된다.

성공 payload mapping: zcr_read→read, zcr_files→files, zcr_search→search, zcr_batch_read→batch_read, zcr_patch/zcr_create→receipt, zcr_status→status, zcr_health→health. 실패 응답 data는 비어 있을 수 있고, 이미 적용된 write는 receipt를 포함해야 한다.

schema는 bytespan overlap/order, UTF-8 byte length, root scope, capability, unique item_id, whole-file hash validity, current fence, resource availability를 대신 검사하지 않는다. 이 semantic checks는 runtime 필수다. inputs의 maxLength는 JSON character limit일 뿐 byte limit 대신이 아니다.

`immutable_snapshot` consistency는 내부 결과/후속 capability용으로 예약되며 v1 public input에는 노출하지 않는다. 이를 외부에서 요청하면 E_UNSUPPORTED다. managed_generation/bounded_stale도 해당 단계와 policy가 활성화됐을 때만 허용한다.

planning manifest는 null identity를 허용하지만 ready/active는 실제 workspace/base/contract/fence/expiry가 필수다. 예시 planned manifest는 쓰기/실행 권한을 주지 않는다. 본 ZIP의 검증기용 Python/jsonschema는 **문서 제작·검증 도구**이며 Zig runtime의 배포 의존성이 아니다.
# Native cancellation contract

The native `Cancel` value carries a borrowed atomic flag and an optional monotonic deadline with its borrowed `std.Io` backend. `withTimeout(io, milliseconds)` may shorten an inherited deadline; `check()` distinguishes `Cancelled` from `DeadlineExceeded`. Both borrowed lifetimes extend through callback drain. This adds no wire field or permission. Native range reads intersect this deadline with `ReadSpec.deadline_ms`.
