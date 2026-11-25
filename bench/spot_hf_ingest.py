"""CPU-only ingestion of actual HF+PEFT spot observations. Never runs a model.

The six frozen tests, rubric and T1 bytes remain immutable. A partial evaluation
stream is diagnostic evidence, not a completed 620-case verdict or Q8 serving proof.
"""
from __future__ import annotations
import argparse
import hashlib
import html
import json
import math
from pathlib import Path


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def file_json(path):
    data=Path(path).read_bytes()
    return json.loads(data.decode('utf-8-sig')),hashlib.sha256(data).hexdigest()


def text_sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def save(path,value):
    path=Path(path)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
    path.chmod(0o600)


def expected_user(case):
    request=case['planned_candidate_request']
    if case['task']=='clean':
        return request['control_line']+'\n'+case['input']
    wire={key:request[key] for key in ('contract','settings','editing_prompt')}
    return '[Polish request v1] '+canonical(wire)+'\n'+case['input']


def validate_sources(fixture,fixture_sha,rubric,rubric_sha,t1,requests):
    cases=fixture.get('cases',[])
    if (fixture.get('schema_version')!=2 or len(cases)!=6
        or len({c['id']for c in cases})!=6 or [c['case_number']for c in cases]!=list(range(1,7))):
        raise ValueError('Require the authoritative frozen six-case v2 fixture')
    if rubric.get('cases_sha256')!=fixture_sha:
        raise ValueError('Rubric belongs to another fixture')
    if t1.get('identity',{}).get('fixture_sha256')!=fixture_sha or t1['identity'].get('rubric_sha256')!=rubric_sha:
        raise ValueError('T1 observations belong to another frozen fixture/rubric')
    if len(t1.get('predictions',[]))!=6 or {r['id']for r in t1['predictions']}!={c['id']for c in cases}:
        raise ValueError('T1 comparison must cover exactly six original IDs')
    if requests.get('kind')!='frozen_adapter_evaluation_requests_v1' or requests.get('spot_cases_sha256')!=fixture_sha:
        raise ValueError('Request pack is not bound to this fixture')
    rows=requests.get('requests',[])
    if len(rows)!=620 or len({r['id']for r in rows})!=620:
        raise ValueError('Require the exact unique 620-request pack')
    counts={name:sum(r.get('corpus')==name for r in rows)for name in ('held363','r251','spots')}
    if counts!={'held363':363,'r251':251,'spots':6}:
        raise ValueError('Request corpus counts differ')
    byid={r['id']:r for r in rows if r.get('corpus')=='spots'}
    expected={'spots/'+c['id']for c in cases}
    if set(byid)!=expected:
        raise ValueError('Unexpected spot request IDs')
    for index,case in enumerate(cases):
        if (case.get('never_train') is not True or case.get('split')!='test_only'
            or case['task']!=('polish'if index==5 else 'clean')
            or case['input_sha256']!=text_sha(case['input'])
            or case['reference_sha256']!=text_sha(case['reference'])):
            raise ValueError('Frozen fixture identity/task/text mismatch')
        row=byid['spots/'+case['id']]
        if (row['task']!=case['task'] or row['input']!=case['input']
            or row['input_sha256']!=case['input_sha256']
            or row['user']!=expected_user(case)
            or row['prompt_sha256']!=text_sha(row['prompt'])
            or row['prompt'].count('<|im_start|>user\n'+row['user']+'<|im_end|>\n')!=1):
            raise ValueError('Exact spot input/request mode/prompt binding differs')
    return byid


def prepare_plan(fixture_path,rubric_path,t1_path,request_path,out_path):
    fixture,fs=file_json(fixture_path);rubric,rs=file_json(rubric_path)
    t1,ts=file_json(t1_path);requests,qs=file_json(request_path)
    spots=validate_sources(fixture,fs,rubric,rs,t1,requests)
    plan={'schema_version':1,'kind':'six_spot_cpu_hf_ingest_plan_v1',
          'fixture':str(Path(fixture_path).resolve()),'fixture_sha256':fs,
          'rubric':str(Path(rubric_path).resolve()),'rubric_sha256':rs,
          't1_predictions':str(Path(t1_path).resolve()),'t1_predictions_sha256':ts,
          'request_pack':str(Path(request_path).resolve()),'request_pack_sha256':qs,
          'pack_manifest_sha256':requests['pack_manifest_sha256'],
          'spot_bindings':{rid:{key:row[key]for key in ('corpus','task','input_sha256','prompt_sha256','max_new_tokens')}for rid,row in spots.items()},
          'policy':'Only actual exact-bound HF+PEFT observations; partial streams diagnostic; never Q8 serving proof. No inference.'}
    out_path=Path(out_path)
    if out_path.exists():
        raise FileExistsError('Preserve existing versioned preparation')
    out_path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    save(out_path,plan)
    return plan


def load_plan(path):
    plan,plan_sha=file_json(path)
    if plan.get('kind')!='six_spot_cpu_hf_ingest_plan_v1':
        raise ValueError('Wrong ingestion plan')
    objects={}
    for name in ('fixture','rubric','t1_predictions','request_pack'):
        value,actual=file_json(plan[name])
        if actual!=plan[name+'_sha256']:
            raise ValueError('A frozen source changed: '+name)
        objects[name]=value
    spots=validate_sources(objects['fixture'],plan['fixture_sha256'],objects['rubric'],plan['rubric_sha256'],objects['t1_predictions'],objects['request_pack'])
    actual={rid:{key:row[key]for key in ('corpus','task','input_sha256','prompt_sha256','max_new_tokens')}for rid,row in spots.items()}
    if actual!=plan['spot_bindings']:
        raise ValueError('Ingestion bindings changed')
    return plan,plan_sha,objects,spots


def validate_observations(records,spots):
    found={}
    for row in records:
        rid=row.get('id','')
        if row.get('corpus')!='spots' and not rid.startswith('spots/'):
            continue
        if rid not in spots or row.get('corpus')!='spots':
            raise ValueError('Unknown ID or false spot corpus')
        if rid in found:
            raise ValueError('Duplicate observed spot ID')
        request=spots[rid]
        for key in ('corpus','task','input_sha256','prompt_sha256','max_new_tokens'):
            if row.get(key)!=request[key]:
                raise ValueError('Observed request binding differs: '+key)
        if not isinstance(row.get('output'),str) or row.get('finish_reason')not in ('stop','length'):
            raise ValueError('Malformed actual output/finish record')
        if row.get('error')is not None and not isinstance(row['error'],str):
            raise ValueError('Malformed error')
        seconds=row.get('seconds')
        if isinstance(seconds,bool)or not isinstance(seconds,(int,float))or not math.isfinite(seconds)or seconds<0:
            raise ValueError('Malformed generation timing')
        found[rid]=dict(row)
    if set(found)!=set(spots):
        raise ValueError('Wait for all six exact spot observations; no fabricated slots')
    return [found[rid]for rid in spots]


def observation_set_sha(rows):
    keys=('id','corpus','task','input_sha256','prompt_sha256','max_new_tokens','output','finish_reason','error')
    return digest([{key:row.get(key)for key in keys}for row in sorted(rows,key=lambda r:r['id'])])


def final_candidate(payload,plan):
    diagnostic=payload.get('kind')=='diagnostic_complete_final_r2_predictions'
    if (payload.get('kind') not in ('actual_t2_final_verdict_predictions','diagnostic_complete_final_r2_predictions') or payload.get('round')!='R2'
        or (diagnostic and (payload.get('diagnostic_only') is not True or payload.get('qualifies_for_export') is not False or payload.get('qualifies_for_shipping') is not False))
        or payload.get('candidate_kind')!='hf_peft_adapter' or payload.get('complete')is not True
        or payload.get('terminal_exit_code')!=(5 if diagnostic else 0) or payload.get('serving_quantization_verified')is not False
        or payload.get('request_pack_sha256')!=plan['request_pack_sha256']
        or payload.get('pack_manifest_sha256')!=plan['pack_manifest_sha256']):
        raise ValueError('Not a completed exact-bound R2 HF adapter result')
    identity=payload.get('model_identity',{})
    if (identity.get('candidate_kind')!='hf_peft_adapter' or not identity.get('run_id','').startswith('r2-')
        or digest(identity)!=payload.get('model_identity_sha256')):
        raise ValueError('Candidate model identity does not verify')
    scalar_hashes=('trainer_sha256','config_sha256','training_receipt_sha256','training_terminal_state_sha256')
    def valid_hash(value):
        return isinstance(value,str)and len(value)==64 and all(c in '0123456789abcdef'for c in value)
    if any(not valid_hash(identity.get(key))for key in scalar_hashes):
        raise ValueError('Incomplete model identity source hashes')
    for key in ('base_files_sha256','adapter_files_sha256','source_files_sha256'):
        values=identity.get(key)
        if not isinstance(values,dict)or not values or any(not valid_hash(value)for value in values.values()):
            raise ValueError('Incomplete candidate file identity')
    if not {'adapter_config.json','adapter_model.safetensors'}<=set(identity['adapter_files_sha256']):
        raise ValueError('Final adapter file identities missing')
    if identity['source_files_sha256'].get('train_r2.py')!=identity['trainer_sha256']:
        raise ValueError('Frozen trainer identity differs')
    main=payload.get('predictions',[]);spots=payload.get('spot_predictions',[])
    all_rows=main+spots
    if (len(main)!=614 or len(spots)!=6 or len({r['id']for r in all_rows})!=620
        or sum(r.get('corpus')=='held363'for r in main)!=363
        or sum(r.get('corpus')=='r251'for r in main)!=251):
        raise ValueError('Final result is not complete 363+251+six coverage')
    return {'candidate_kind':'hf_peft_adapter','run_id':identity['run_id'],'source_diagnostic_only':diagnostic,
            'model_identity_sha256':payload['model_identity_sha256'],'model_identity':identity,
            'identity_verification':'full identity payload canonical hash verified; no model execution here',
            'complete_620_evaluation':True,'serving_quantization_verified':False,
            'precision_label':'HF BF16 base + PEFT adapter evaluation; not merged Q8 serving'},spots


def stream_candidate(progress):
    identity=progress.get('model_identity_sha256')
    diagnostic=progress.get('kind')=='diagnostic_adapter_evaluation_progress_v1'
    if (progress.get('kind') not in ('actual_adapter_evaluation_progress_v1','diagnostic_adapter_evaluation_progress_v1')
        or (diagnostic and progress.get('diagnostic_only') is not True)
        or not progress.get('run_id','').startswith('r2-')
        or not isinstance(identity,str)or len(identity)!=64
        or any(c not in '0123456789abcdef'for c in identity)
        or progress.get('completed',0)<6):
        raise ValueError('Need actual R2 evaluator progress with model identity and six completed cases')
    return {'candidate_kind':'hf_peft_adapter','run_id':progress['run_id'],
            'source_diagnostic_only':diagnostic,
            'model_identity_sha256':identity,'model_identity':None,
            'identity_verification':'reported progress hash only; complete identity receipt pending',
            'evaluation_state':progress.get('state'),'evaluation_error':progress.get('error'),
            'complete_620_evaluation':False,'serving_quantization_verified':False,
            'precision_label':'HF BF16 + PEFT evaluator stream; diagnostic, no Q8 serving claim'}


def ingest(plan_path,out,predictions_path=None,records_path=None,progress_path=None):
    plan,plan_sha,objects,spots=load_plan(plan_path)
    if bool(predictions_path)==bool(records_path):
        raise ValueError('Supply either final predictions or a copied records stream')
    source={}
    if predictions_path:
        payload,payload_sha=file_json(predictions_path)
        candidate,records=final_candidate(payload,plan)
        source=dict(kind='complete_adapter_predictions',path=str(Path(predictions_path).resolve()),sha256=payload_sha)
    else:
        if not progress_path:
            raise ValueError('A copied stream requires its actual progress/identity snapshot')
        data=Path(records_path).read_bytes()
        records=[json.loads(line)for line in data.decode('utf-8-sig').split('\n')if line.strip()]
        progress,ps=file_json(progress_path)
        candidate=stream_candidate(progress)
        source=dict(kind='partial_adapter_evaluation_stream',path=str(Path(records_path).resolve()),
                    sha256=hashlib.sha256(data).hexdigest(),progress_path=str(Path(progress_path).resolve()),progress_sha256=ps)
    observed=validate_observations(records,spots)
    observation_sha=observation_set_sha(observed)
    byid={r['id']:r for r in observed}
    t1={r['id']:r for r in objects['t1_predictions']['predictions']}
    cases=[]
    for fixture_case in objects['fixture']['cases']:
        row=byid['spots/'+fixture_case['id']]
        cases.append({'case_id':fixture_case['id'],'request_id':row['id'],'task':row['task'],
                      'title':fixture_case['title'],'input':fixture_case['input'],
                      'wispr_reference':fixture_case['reference'],'known_reference_errors':fixture_case['known_reference_errors'],
                      't1_actual_output':t1[fixture_case['id']]['output'],'hf_peft_actual_output':row['output'],
                      'observation':row,'output_sha256':text_sha(row['output']),
                      'inference_valid':row['finish_reason']=='stop'and not row.get('error')and bool(row['output'].strip()),
                      'planned_request':fixture_case['planned_candidate_request'],
                      'actual_source_wispr_settings':'unknown in this fixture','audio_scope':'text-only app-output/typed test; no raw-ASR or audio correctness claim',
                      'review_status':'independent preservation and habits review required'})
    bundle={'schema_version':1,'kind':'actual_six_hf_peft_spot_comparison_v1','candidate':candidate,
            'source':source,'ingest_plan_sha256':plan_sha,'fixture_sha256':plan['fixture_sha256'],
            'rubric_sha256':plan['rubric_sha256'],'t1_predictions_sha256':plan['t1_predictions_sha256'],
            'request_pack_sha256':plan['request_pack_sha256'],'spot_observation_set_sha256':observation_sha,
            'cases':cases,'automatic_acceptance':False,'human_approval':False}
    review={'schema_version':1,'kind':'independent_six_spot_review_request_v1',
            'model_identity_sha256':candidate['model_identity_sha256'],
            'predictions_sha256':source['sha256']if predictions_path else None,
            'source_stream_sha256':source['sha256']if records_path else None,
            'fixture_sha256':plan['fixture_sha256'],'rubric_sha256':plan['rubric_sha256'],
            'spot_observation_set_sha256':observation_sha,'candidate':candidate,'cases':cases,
            'rubric':objects['rubric'],'required_review':'Preservation first: facts,names,numbers,negations,conditions,commitments,hedges. Then each applicable habit1–6 separately. Case6isrewrite. KnownWisprmistakesearnnothing.',
            'expected_results_schema':{'case_id':'original fixture ID, no spots/ prefix','preservation':'pass|hold|fail; unresolved hold is not release approval',
                'critical_errors':'actual findings, not prefilled','habits':'six frozen habit scores and notes','prediction_output_sha256':'exact actual output digest'},
            'partial_stream_policy':'A partial stream is diagnostic. Later final binding needs the same model identity and exact spot_observation_set_sha256 before replacing its file hash with the full620result hash.',
            'results_created':False,'human_approval':False}
    out=Path(out)
    if out.exists():raise FileExistsError('Preserve previous derived evidence')
    out.mkdir(parents=True,mode=0o700)
    save(out/'comparison.json',bundle);save(out/'review-request.json',review)
    write_html(out/'comparison.html',bundle)
    # Verify frozen-source bytes again after creating the new derived files.
    load_plan(plan_path)
    return {'out':str(out.resolve()),'observations':len(cases),'candidate':candidate,
            'spot_observation_set_sha256':observation_sha,'review_request_sha256':file_json(out/'review-request.json')[1]}


def write_html(path,bundle):
    escape=html.escape;candidate=bundle['candidate'];body=''
    for case in bundle['cases']:
        labels=['Typed input'if case['task']=='polish'else'FluidVoice app input','Wispr reference','T1 actual Q8 output','R2 actual HF + PEFT output']
        values=[case['input'],case['wispr_reference'],case['t1_actual_output'],case['hf_peft_actual_output']]
        columns=''.join('<article><h3>'+escape(label)+'</h3><div>'+escape(value)+'</div></article>'for label,value in zip(labels,values))
        body+='<section><h2>'+escape(case['title'])+'</h2><p>'+('Selected-text rewrite'if case['task']=='polish'else'Normal dictation cleanup')+' · Independent preservation review pending</p><div class="columns">'+columns+'</div>'
        if not case['inference_valid']:body+='<p class="warning">This observed response is incomplete or has an error. It is not a successful result.</p>'
        if case['known_reference_errors']:body+='<ul>'+''.join('<li>'+escape(x)+'</li>'for x in case['known_reference_errors'])+'</ul>'
        body+='</section>'
    title='Actual HF + PEFT spot observations'
    lead='Complete 620-case evaluation receipt supplied.'if candidate['complete_620_evaluation']else'Six actual responses from a partial evaluation stream. Diagnostic only; full evaluation and identity receipt are pending.'
    page='''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Six actual adapter spot checks</title><style>*{box-sizing:border-box}body{margin:0;background:#080808;color:#eee;font:14px/1.6 ui-monospace,monospace}main{max-width:1800px;margin:auto;padding:32px}h1{font-size:30px;font-weight:400}h2{font-size:20px;font-weight:400}h3{font-size:12px;font-weight:400;color:#aaa}p,li{color:#aaa;max-width:110ch}section{border-top:1px solid #292929;margin-top:30px;padding-top:25px}.columns{display:grid;grid-template-columns:repeat(4,minmax(230px,1fr));gap:22px;overflow-x:auto}.columns article{min-width:230px}.columns article div{white-space:pre-wrap;font:14px/1.7 system-ui,sans-serif;color:#ddd}.columns article:last-child div{color:#a8c9e9}.warning{color:#e4b4a0}code{overflow-wrap:anywhere}@media(max-width:700px){main{padding:20px}.columns{grid-template-columns:repeat(4,260px)}}</style></head><body><main>'''
    page+='<h1>'+title+'</h1><p>'+lead+'</p><p>'+escape(candidate['precision_label'])+'. T1 and R2 use different runtimes and precision. These columns compare writing behavior; they do not establish Q8 serving quality or compare runtime speed.</p><p>Model identity: <code>'+escape(candidate['model_identity_sha256'])+'</code></p><p>Exact FluidVoice app outputs and typed text are inputs. Source Wispr settings are unknown. Facts, names, numbers and hedges take priority over layout. No preservation verdict or habit score has been fabricated.</p>'+body+'</main></body></html>'
    Path(path).write_text(page);Path(path).chmod(0o600)


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    prep=sub.add_parser('prepare')
    for key in ('fixture','rubric','t1','requests','out'):prep.add_argument('--'+key,type=Path,required=True)
    run=sub.add_parser('ingest');run.add_argument('--plan',type=Path,required=True);run.add_argument('--out',type=Path,required=True)
    group=run.add_mutually_exclusive_group(required=True);group.add_argument('--predictions',type=Path);group.add_argument('--records',type=Path)
    run.add_argument('--progress',type=Path)
    args=parser.parse_args()
    private=Path.home()/'Library/Application Support/VOICE'
    if private.resolve() not in args.out.expanduser().resolve().parents:
        parser.error('Private evaluation outputs must stay under VOICE')
    if args.command=='prepare':
        plan=prepare_plan(args.fixture,args.rubric,args.t1,args.requests,args.out)
        print(json.dumps({'prepared':True,'spot_requests':len(plan['spot_bindings']),'models_executed':False}))
    else:print(json.dumps(ingest(args.plan,args.out,args.predictions,args.records,args.progress),indent=2))


if __name__=='__main__':main()
