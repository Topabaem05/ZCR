# 수행한 검증과 수행하지 않은 검증

## 수행

- JSON 및 JSON Schema 파싱, 8개 tool 입력 예시, logical response/typed read payload.
- 잘못된 empty literal, 33-item batch, root override, 과대 출력, unbound active manifest 거부.
- UTF-8/CRLF/EOF fixture의 bytes·SHA-256·line offset 및 선언된 patch fixture.
- 26 Task의 dependency DAG, 파일 소유권 중복, S01–S06, 92개 test specification 연결.
- RAM profile의 합계, 로컬 Markdown 링크, 출처 ID, SVG XML, HTML anchor와 external asset 부재.
- Chromium에 HTML 문자열을 주입해 1440×1080 viewport에서 표지·본문을 렌더링하고 확인. body width=1440, 49개 문서 section. 컨테이너 browser policy가 file URL navigation을 막아 set_content 방식으로 렌더링했다.

상세 자동 검사 결과는 `report.json`에 있다. 이미지 검토는 전체 49개 section을 한 장씩 검토했다는 뜻이 아니다. 대표 표지/본문 및 주요 도식을 확인했다.

## 미수행

Zig runtime 구현, 실제 Zig compile, Apple Silicon/Intel Mac/Linux/Windows runtime 시험, Codex/Claude 설정 등록, QoS의 실제 core 배치, RAM footprint, local LLM tok/s, 전력 및 E2E 성능 측정은 수행하지 않았다. benchmark template과 runtime test catalog의 상태는 NOT_RUN이다.

## 재검증

```sh
python verification/validate_bundle.py --report verification/report.json
```

Python 3.10+와 jsonschema가 필요하다. 이는 문서 패키지 검증 의존성이며 runtime 배포 의존성이 아니다. `MANIFEST.sha256`은 패키지 내 파일 무결성을 위한 목록이다. 파일을 편집하면 manifest를 다시 생성해야 한다.
