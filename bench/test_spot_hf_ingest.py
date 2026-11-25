"""Authored temporary CPU fixtures only; no actual predictions or model calls."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import spot_hf_ingest as I


class SpotIngestTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.cases=[]
        for n in range(1,7):
            text=f'Authored temporary example number {n} stays unchanged.'
            request={'control_line':'[Task: clean] [Level: light] [Styling: formal] [Structure: lists] [Context: general]'}if n<6 else {'contract':'t2-selected-text-polish-v1','settings':{k:True for k in ('concise','clarity','reorder','structure','maintain_your_tone')},'editing_prompt':''}
            self.cases.append(dict(id=f'authored-{n}',case_number=n,title=f'Authored test {n}',task='clean'if n<6 else'polish',input=text,reference=text,input_sha256=I.text_sha(text),reference_sha256=I.text_sha(text),never_train=True,split='test_only',planned_candidate_request=request,known_reference_errors=[]))
        fixture={'schema_version':2,'cases':self.cases};self.write('cases.json',fixture)
        self.write('rubric.json',{'cases_sha256':I.file_json(self.root/'cases.json')[1],'habits':[]})
        self.write('t1.json',{'identity':{'fixture_sha256':I.file_json(self.root/'cases.json')[1],'rubric_sha256':I.file_json(self.root/'rubric.json')[1]},'predictions':[{'id':c['id'],'output':c['input']}for c in self.cases]})
        requests=[]
        for corpus,count in [('held363',363),('r251',251)]:
            requests.extend({'id':f'{corpus}/{n}','corpus':corpus}for n in range(count))
        self.spots=[]
        for case in self.cases:
            user=I.expected_user(case);prompt='<|im_start|>user\n'+user+'<|im_end|>\n'
            self.spots.append(dict(id='spots/'+case['id'],corpus='spots',task=case['task'],input=case['input'],user=user,prompt=prompt,input_sha256=case['input_sha256'],prompt_sha256=I.text_sha(prompt),max_new_tokens=64))
        self.write('requests.json',{'kind':'frozen_adapter_evaluation_requests_v1','pack_manifest_sha256':'a'*64,'spot_cases_sha256':I.file_json(self.root/'cases.json')[1],'requests':requests+self.spots})
        I.prepare_plan(self.root/'cases.json',self.root/'rubric.json',self.root/'t1.json',self.root/'requests.json',self.root/'plan.json')
        self.records=[{**{k:r[k]for k in ('id','corpus','task','input_sha256','prompt_sha256','max_new_tokens')},'output':'Actual authored fixture output.','finish_reason':'stop','error':None,'seconds':.2}for r in self.spots]
        self.progress={'kind':'actual_adapter_evaluation_progress_v1','run_id':'r2-authored-test','state':'generating','completed':6,'model_identity_sha256':'b'*64}

    def write(self,name,value):
        I.save(self.root/name,value)

    def stream(self,records=None):
        (self.root/'records.jsonl').write_text(''.join(json.dumps(row)+'\n'for row in(records or self.records)))
        self.write('progress.json',self.progress)
        return I.ingest(self.root/'plan.json',self.root/'derived',records_path=self.root/'records.jsonl',progress_path=self.root/'progress.json')

    def test_actual_stream_has_six_unscored_observations_and_no_quantized_claim(self):
        result=self.stream()
        self.assertEqual(result['observations'],6)
        bundle=I.file_json(self.root/'derived/comparison.json')[0]
        self.assertFalse(bundle['candidate']['complete_620_evaluation'])
        self.assertFalse(bundle['candidate']['serving_quantization_verified'])
        self.assertTrue(all(c['review_status'].endswith('required')for c in bundle['cases']))
        review=I.file_json(self.root/'derived/review-request.json')[0]
        self.assertIsNone(review['predictions_sha256'])
        self.assertFalse(review['results_created'])

    def test_request_mode_and_input_binding_mismatches_are_rejected(self):
        for key,value in [('task','polish'),('input_sha256','0'*64),('prompt_sha256','0'*64),('corpus','r251')]:
            rows=copy.deepcopy(self.records);rows[0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                I.validate_observations(rows,{r['id']:r for r in self.spots})

    def test_duplicate_unknown_and_missing_spots_are_rejected(self):
        for rows in [self.records+self.records[:1],self.records[:-1],[{**self.records[0],'id':'spots/unknown'}]+self.records[1:]]:
            with self.assertRaises(ValueError):I.validate_observations(rows,{r['id']:r for r in self.spots})

    def test_changed_frozen_fixture_refuses_ingest(self):
        fixture=I.file_json(self.root/'cases.json')[0];fixture['cases'][0]['input']='Changed test'
        self.write('cases.json',fixture)
        with self.assertRaisesRegex(ValueError,'frozen source changed'):self.stream()

    def test_wrong_source_request_mode_refuses_preparation(self):
        pack=I.file_json(self.root/'requests.json')[0];pack['requests'][-1]['user']=self.cases[-1]['input'];self.write('changed-requests.json',pack)
        with self.assertRaisesRegex(ValueError,'request mode'):
            I.prepare_plan(self.root/'cases.json',self.root/'rubric.json',self.root/'t1.json',self.root/'changed-requests.json',self.root/'bad-plan.json')

    def final_payload(self):
        identity={'candidate_kind':'hf_peft_adapter','run_id':'r2-authored-test','base_files_sha256':{'weights':'a'*64},'adapter_files_sha256':{'adapter_config.json':'a'*64,'adapter_model.safetensors':'a'*64},'source_files_sha256':{'train_r2.py':'c'*64},**{k:'c'*64 for k in ('trainer_sha256','config_sha256','training_receipt_sha256','training_terminal_state_sha256')}}
        requests=I.file_json(self.root/'requests.json')[0]
        return {'kind':'actual_t2_final_verdict_predictions','round':'R2','candidate_kind':'hf_peft_adapter','complete':True,'terminal_exit_code':0,'serving_quantization_verified':False,'request_pack_sha256':I.file_json(self.root/'requests.json')[1],'pack_manifest_sha256':'a'*64,'model_identity':identity,'model_identity_sha256':I.digest(identity),'predictions':[{'id':r['id'],'corpus':r['corpus']}for r in requests['requests']if r['corpus']!='spots'],'spot_predictions':self.records}

    def test_complete_receipt_binds_full_file_but_not_Q8(self):
        self.write('final.json',self.final_payload())
        result=I.ingest(self.root/'plan.json',self.root/'derived',predictions_path=self.root/'final.json')
        self.assertTrue(result['candidate']['complete_620_evaluation'])
        review=I.file_json(self.root/'derived/review-request.json')[0]
        self.assertEqual(review['predictions_sha256'],I.file_json(self.root/'final.json')[1])
        self.assertFalse(review['candidate']['serving_quantization_verified'])

    def test_incomplete_or_tampered_final_identity_refused(self):
        for key,value in [('complete',False),('model_identity_sha256','0'*64),('round','R1'),('serving_quantization_verified',True)]:
            result=self.final_payload();result[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):I.final_candidate(result,I.file_json(self.root/'plan.json')[0])


if __name__=='__main__':unittest.main()
