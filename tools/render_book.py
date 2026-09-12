#!/usr/bin/env python3
"""Rebuild DESIGNBOOK.html from existing Markdown and SVG. Requires markdown-it-py.
This is documentation tooling, not a dependency of the planned Zig runtime.
Run from any directory: python tools/render_book.py
"""
from pathlib import Path
import re, html
from markdown_it import MarkdownIt
ROOT=Path(__file__).resolve().parents[1]
def put(path,content):
    (ROOT/path).write_text(content.strip()+'\n',encoding='utf-8')
# Single-file HTML design book, inline SVG, no external JS/fonts.
main=sorted(ROOT.glob('docs/*.md'))
plans=sorted(ROOT.glob('docs/superpowers/plans/*.md'))
ordered=[ROOT/'README.md']+main+plans+[ROOT/'AGENTS.md',ROOT/'tasks/INDEX.md']+[ROOT/f'tasks/T{i:02}.md' for i in range(26)]+[ROOT/'contracts/README.md',ROOT/'references/SOURCES.md']
ids={str(p.relative_to(ROOT)):'doc-'+re.sub(r'[^a-zA-Z0-9]+','-',str(p.relative_to(ROOT))) for p in ordered}
md=MarkdownIt('commonmark',{'html':True}).enable('table')
sections=[];nav=[]
for p in ordered:
    rel=str(p.relative_to(ROOT));sid=ids[rel];text=p.read_text()
    title=text.splitlines()[0].lstrip('# ').strip()
    rendered=md.render(text)
    svg_seq=[0]
    def embed(m):
        src=m.group(1)
        if src.endswith('.svg'):
            target=(p.parent/src).resolve()
            if target.exists():
                svg=target.read_text();svg=svg[svg.find('<svg'):]
                svg_seq[0]+=1
                prefix=sid+'-svg-'+str(svg_seq[0])+'-'
                svg=re.sub(r'id="([^"]+)"',lambda x:'id="'+prefix+x.group(1)+'"',svg)
                svg=re.sub(r'(href=")#([^"]+)',lambda x:x.group(1)+'#'+prefix+x.group(2),svg)
                svg=re.sub(r'url\(#([^)]*)\)',lambda x:'url(#'+prefix+x.group(1)+')',svg)
                return '<figure class="diagram">'+svg+'</figure>'
        return m.group(0)
    rendered=re.sub(r'<img src="([^"]+)"[^>]*>',embed,rendered)
    def relink(m):
        url=html.unescape(m.group(1))
        if url.startswith(('http:','https:','mailto:','#')):return m.group(0)
        bare,sep,anchor=url.partition('#')
        target=(p.parent/bare).resolve()
        try: key=str(target.relative_to(ROOT))
        except ValueError:return m.group(0)
        if key in ids:
            dest='#'+(anchor if anchor.startswith('R') else ids[key])
            return 'href="'+dest+'"'
        # source code assets live in ZIP; remove dependency in portable book, retaining plain label.
        return 'data-package-file="'+html.escape(key)+'" title="편집 원본은 저장소에 포함"'
    rendered=re.sub(r'href="([^"]+)"',relink,rendered)
    sections.append(f'<section id="{sid}" class="doc"><div class="docpath">{html.escape(rel)}</div>{rendered}</section>')
    nav.append(f'<a href="#{sid}" class="{"task" if rel.startswith("tasks/T") else "main"}">{html.escape(title)}</a>')
css='''
:root{--ink:#172e3a;--muted:#56707b;--rule:#d9e3e5;--accent:#1c7468;--paper:#fff;--side:#f0f5f5}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:var(--paper);font:15px/1.82 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans KR",sans-serif}
nav{position:fixed;inset:0 auto 0 0;width:290px;overflow-y:auto;background:var(--side);padding:28px 20px 36px;border-right:1px solid var(--rule)}nav .brand{font-size:22px;font-weight:800;margin-bottom:5px}nav .sub{font-size:12px;color:var(--muted);margin-bottom:20px}nav a{display:block;text-decoration:none;color:var(--ink);font-size:12px;line-height:1.55;padding:6px 8px;border-radius:4px}nav a:hover{background:#dcebe7}nav a.task{padding-left:18px;font-size:11px}
main{margin-left:290px;max-width:1310px;padding:48px 48px 90px}.hero{padding:30px 0 32px;border-bottom:3px solid var(--accent)}.eyebrow{color:var(--accent);font-size:12px;font-weight:800;letter-spacing:.16em}.hero h1{font-size:40px;line-height:1.25;margin:15px 0}.hero p{color:var(--muted);max-width:790px}.meta{display:flex;gap:24px;flex-wrap:wrap;margin-top:22px;font-size:13px}.meta strong{color:var(--accent)}
.doc{padding:42px 0;border-bottom:1px solid var(--rule);scroll-margin-top:20px}.docpath{font-size:11px;color:var(--muted);letter-spacing:.03em;margin-bottom:9px}h1{font-size:27px;line-height:1.45;margin:0 0 24px}h2{font-size:21px;line-height:1.55;margin:34px 0 16px}h3{font-size:17px;margin:26px 0 12px}p{margin:13px 0}a{color:var(--accent);text-underline-offset:3px}strong{font-weight:750}ul,ol{padding-left:25px}li{margin:7px 0}blockquote{margin:20px 0;padding:0 18px;border-left:3px solid var(--accent);color:var(--muted)}
pre{background:#f3f6f7;color:#243c49;border:1px solid #e3eaec;padding:18px;border-radius:5px;overflow:auto;font:12px/1.65 ui-monospace,SFMono-Regular,Consolas,monospace}code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.88em;overflow-wrap:anywhere}p code,li code,td code{background:#eff4f4;padding:2px 4px;border-radius:3px}
table{width:100%;border-collapse:collapse;margin:20px 0;font-size:12px;line-height:1.65;display:block;overflow-x:auto}thead{background:#e9f2f0}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--rule);padding:10px 11px;min-width:85px}th{color:#17493f;font-weight:700}tr:nth-child(even) td{background:#fafcfc}.diagram{margin:24px 0;padding:12px;background:#fbfdfc;overflow:auto;border:1px solid #e2eae7;border-radius:5px}.diagram svg{width:100%;height:auto;min-width:600px;max-height:1500px}footer{font-size:12px;color:var(--muted);padding-top:30px}
@media(max-width:1000px){nav{position:relative;width:auto;max-height:320px}main{margin:0;padding:28px 22px}.hero h1{font-size:32px}.diagram svg{min-width:520px}}
@media print{nav{display:none}main{margin:0;padding:0;max-width:none}.hero h1{font-size:28px}.doc{break-before:page;padding-top:10px}h1,h2,h3{break-after:avoid}pre{white-space:pre-wrap;overflow-wrap:anywhere}table{display:table;font-size:9px}th,td{min-width:0;padding:5px}.diagram{break-inside:avoid;border:0}.diagram svg{min-width:0;max-height:820px}a{color:inherit;text-decoration:none}}
'''
page='''<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ZCR · Zig Code Runtime | C4 + SDD + Implementation Plans</title><style>'''+css+'''</style></head><body><nav><div class="brand">ZCR / DESIGN</div><div class="sub">Zig 0.16.0 · 2026-09-12<br>설계 · 구현 · 검증 진행 중</div>'''+''.join(nav)+'''</nav><main><header class="hero"><div class="eyebrow">CODE AGENT RUNTIME · IMPLEMENTATION & EVIDENCE</div><h1>빠른 모델이<br>코드 도구를 기다리지 않도록.</h1><p>Apple Silicon을 우선하는 Zig native runtime의 C4·SDD, 메모리·워크트리 격리, 처리 파이프라인, x86 이식성, 구현 Task와 검증 계약.</p><div class="meta"><span><strong>26</strong> implementation tasks</span><span><strong>8</strong> core tools</span><span><strong>11</strong> architecture diagrams</span><span><strong>미실측</strong> 성능 목표</span></div></header>'''+''.join(sections)+'''<footer>이 통합 문서는 외부 JavaScript·폰트·이미지 요청 없이 열람할 수 있습니다. 편집 가능한 원본·계약·fixture·검증기는 저장소에 포함되어 있습니다. 실행 상태는 작업 상태표를, 실제 시험 결과는 source·binary·환경이 기록된 evidence를 따릅니다. 문서 검증은 런타임 시험을 대신하지 않습니다.</footer></main></body></html>'''
put('DESIGNBOOK.html',page)
print('Built',len(list((ROOT/'diagrams').glob('*.svg'))),'SVG diagrams and HTML',len(page.encode()),'bytes')
