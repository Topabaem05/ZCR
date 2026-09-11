#!/usr/bin/env python3
"""Validate this design bundle, not the unimplemented Zig runtime.

Usage: python verification/validate_bundle.py [--report /path/to/report.json]
Requires Python 3.10+ and jsonschema. Does not use the network or mutate sources.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    sys.exit('Missing document-validation dependency: jsonschema (not a runtime dependency).')

ROOT=Path(__file__).resolve().parents[1]
checks=[]
def check(name,condition,detail=''):
    checks.append({'check':name,'status':'pass' if condition else 'fail','detail':detail})
def load(p):return json.loads((ROOT/p).read_text(encoding='utf-8'))
def valid(schema,value):return not list(Draft202012Validator(schema,format_checker=FormatChecker()).iter_errors(value))

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--report',type=Path)
    args=ap.parse_args()
    jsonfiles=list(ROOT.rglob('*.json'))
    parsed={}
    for p in jsonfiles:
        try:parsed[str(p.relative_to(ROOT))]=json.loads(p.read_text(encoding='utf-8'))
        except Exception as e:check('json_parse:'+str(p.relative_to(ROOT)),False,str(e))
    check('all_json_parse',len(parsed)==len(jsonfiles),str(len(jsonfiles)))
    schemas=list(ROOT.rglob('*.schema.json'))
    for p in schemas:
        try:Draft202012Validator.check_schema(json.loads(p.read_text()));check('schema:'+str(p.relative_to(ROOT)),True)
        except Exception as e:check('schema:'+str(p.relative_to(ROOT)),False,str(e))
    tools=load('contracts/tools.json')['tools'];toolmap={t['name']:t for t in tools}
    check('eight_unique_tools',len(toolmap)==len(tools)==8)
    for call in load('examples/tool-calls.json')['calls']:
        check('example:'+call['tool'],valid(toolmap[call['tool']]['inputSchema'],call['arguments']))
    check('negative:empty_literal',not valid(toolmap['zcr_search']['inputSchema'],{'literal':''}))
    check('negative:33_batch_items',not valid(toolmap['zcr_batch_read']['inputSchema'],{'items':[{'item_id':str(i),'path':'a'} for i in range(33)]}))
    check('negative:model_root_override',not valid(toolmap['zcr_read']['inputSchema'],{'path':'a','root':'/etc'}))
    check('negative:output_limit',not valid(toolmap['zcr_read']['inputSchema'],{'path':'a','output_bytes':2097153}))
    ms=load('contracts/task-manifest.schema.json');mf=load('examples/task-manifest.planned.json')
    check('planned_manifest_schema',valid(ms,mf))
    altered=dict(mf);altered['state']='active'
    check('negative:unbound_active_manifest',not valid(ms,altered))
    reply=load('examples/read-response.fixture.json')
    check('read_reply_envelope',valid(load('contracts/response.schema.json'),reply))
    check('read_reply_data',valid(load('contracts/data.schema.json')['$defs']['read'],reply['data']))
    check('read_reply_byte_count',len(json.dumps(reply['data'],ensure_ascii=False,separators=(',',':')).encode())==reply['meta']['returned_bytes'])
    bad=dict(reply);bad['truncated']=True
    check('negative:false_complete',not valid(load('contracts/response.schema.json'),bad))
    vectors=load('tests/vectors.json');fixturemap={f['id']:f for f in vectors['fixtures']}
    for f in vectors['fixtures']:
        b=f['text'].encode();offset=0;spans=[]
        for piece in b.splitlines(keepends=True):
            spans.append({'start':offset,'end':offset+len(piece)});offset+=len(piece)
        check('fixture:'+f['id'],len(b)==f['byte_length'] and hashlib.sha256(b).hexdigest()==f['sha256'] and spans==f['lines'])
    for v in vectors['patch_vectors']:
        b=fixturemap[v['source_fixture']]['text'].encode();spans=v['replacements'];ok=True
        try:
            for r in spans:b[:r['start']].decode();b[:r['end']].decode()
        except UnicodeDecodeError:ok=False
        if 'expected_error' in v:check('patch_fixture:'+v['id'],not ok)
        else:
            chunks=[];off=0
            for r in spans:chunks.extend([b[off:r['start']],r['text'].encode()]);off=r['end']
            chunks.append(b[off:]);check('patch_fixture:'+v['id'],ok and b''.join(chunks).decode()==v['expected_text'])
    mem=load('config/memory-profiles.json')['profiles']
    for r in mem:
        total=sum(r[k] for k in ['base_mib','emergency_mib','paths_mib','content_mib','ast_mib','inflight_mib'])
        check('memory_sum:'+str(r['ram_upper_gib']),total==r['tracked_mib']==r['group_mib']*0.75)
    ts=load('tasks/tasks.json')['tasks'];taskmap={t['id']:t for t in ts};testcases=load('tests/catalog.json')['tests'];testmap={t['id']:t for t in testcases}
    check('26_unique_tasks',len(taskmap)==len(ts)==26)
    check('unique_test_ids',len(testmap)==len(testcases))
    check('all_runtime_tests_not_run',all(t['execution_status']=='not_run' for t in testcases))
    assigned=set()
    colors={}
    def visit(tid):
        if colors.get(tid)==1:raise ValueError('cycle at '+tid)
        if colors.get(tid)==2:return
        colors[tid]=1
        for d in taskmap[tid]['depends_on']:visit(d)
        colors[tid]=2
    try:
        for t in ts:visit(t['id'])
        check('task_dag_acyclic',True)
    except Exception as e:check('task_dag_acyclic',False,str(e))
    for t in ts:
        p=ROOT/t['document'];text=p.read_text() if p.exists() else ''
        check('task_steps:'+t['id'],all(f'**S{i:02}' in text for i in range(1,7)))
        check('task_file_ownership:'+t['id'],all(path in text for path in t['owns']))
        for ti in t['tests']:
            assigned.add(ti);check('test_link:'+ti,ti in testmap and ti in text)
    check('all_catalog_tests_attached_to_tasks',set(testmap)<=assigned,str(sorted(set(testmap)-assigned)))
    # Exact path ownership must not collide between unrelated coding tasks.
    owners={}
    for t in ts:
        for path in t['owns']:owners.setdefault(path,[]).append(t['id'])
    collisions={k:v for k,v in owners.items() if len(v)>1}
    check('exclusive_declared_owned_paths',not collisions,str(collisions))
    sourceids={s['id'] for s in load('references/sources.json')['sources']}
    links=[];missing=[];badref=[]
    for p in ROOT.rglob('*.md'):
        text=p.read_text(encoding='utf-8')
        check('no_unfinished_markers:'+str(p.relative_to(ROOT)),not re.search(r'\b(?:TBD|TODO|FIXME)\b',text))
        for ref in re.findall(r'\[(R\d{2})\]',text):
            if ref not in sourceids:badref.append((str(p),ref))
        for url in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)',text):
            if url.startswith(('http:','https:','mailto:','#')):continue
            pathpart=url.split('#')[0];target=(p.parent/unquote(pathpart)).resolve();links.append(url)
            if not target.exists():missing.append((str(p.relative_to(ROOT)),url))
            elif ROOT not in target.parents and target!=ROOT:missing.append((str(p.relative_to(ROOT)),'escape '+url))
    check('markdown_links_exist',not missing,json.dumps(missing,ensure_ascii=False))
    check('source_refs_known',not badref,str(badref))
    svgfiles=list((ROOT/'diagrams').glob('*.svg'))
    for p in svgfiles:
        try:ET.parse(p);check('svg_xml:'+p.name,True)
        except ET.ParseError as e:check('svg_xml:'+p.name,False,str(e))
    class HTMLAudit(HTMLParser):
        def __init__(self):super().__init__();self.ids=[];self.fragments=[];self.assets=[];self.sections=0
        def handle_starttag(self,tag,attrs):
            a=dict(attrs)
            if 'id' in a:self.ids.append(a['id'])
            if tag=='section':self.sections+=1
            href=a.get('href','')
            if href.startswith('#'):self.fragments.append(href[1:])
            if tag in ['script','img','iframe'] and a.get('src'):self.assets.append(a['src'])
            if tag=='link' and a.get('href'):self.assets.append(a['href'])
    book=(ROOT/'DESIGNBOOK.html').read_text();ha=HTMLAudit();ha.feed(book)
    check('html_unique_ids',len(ha.ids)==len(set(ha.ids)))
    check('html_fragment_links',all(h in set(ha.ids) for h in ha.fragments),str([h for h in ha.fragments if h not in set(ha.ids)]))
    check('html_no_external_assets',not ha.assets,str(ha.assets))
    check('html_all_main_and_task_docs',ha.sections==49,str(ha.sections))
    result=load('bench/results-template.json')
    check('benchmark_not_fabricated',result['status']=='not_run' and all(v is None for v in result['metrics'].values()))
    failed=[c for c in checks if c['status']=='fail']
    report={'scope':'document/schema/fixture/package validation ONLY; no Zig runtime, Mac hardware, or actual host integration was tested','status':'pass' if not failed else 'fail','checks_total':len(checks),'checks_failed':len(failed),'counts':{'main_design_docs':len(list((ROOT/'docs').glob('*.md'))),'tasks':len(ts),'task_steps':6*len(ts),'test_specifications':len(testcases),'core_tools':len(tools),'svg_diagrams':len(svgfiles),'primary_sources':len(sourceids)},'checks':checks}
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['scope','status','checks_total','checks_failed','counts']},ensure_ascii=False,indent=2))
    for c in failed:print('FAIL',c['check'],c['detail'])
    return 1 if failed else 0
if __name__=='__main__':raise SystemExit(main())
