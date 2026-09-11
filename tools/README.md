# 문서 재생성

Markdown과 SVG를 수정한 뒤 `python tools/render_book.py`를 실행하면 오프라인 DESIGNBOOK.html을 다시 만든다. Python의 markdown-it-py가 필요하며, 이는 문서 도구에만 해당한다. 런타임 자체는 Zig 설계다.

DOT를 수정했다면 먼저 Graphviz `dot -Tsvg diagrams/<name>.dot -o diagrams/<name>.svg`로 SVG를 다시 생성한다. Mermaid는 독립 편집용 대체 원본이다. 현재 renderer는 docs/00~17과 tasks/T00~T25를 순서대로 읽으며 새 장을 추가할 때 순서/검증 section count를 함께 갱신한다.

`python verification/validate_bundle.py`로 schema, 예시, task graph, 소유 파일, local links, fixture bytes, 메모리 합계, 오프라인 HTML을 검증한다. 이 검사로 Zig runtime correctness나 성능을 검증했다고 주장할 수 없다.
