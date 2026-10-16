# Copyright (C) 2026 BigFat-Dev
# SPDX-License-Identifier: MIT
import json,sys,os
thread='11111111-1111-4111-8111-111111111111'
original='点击备注后，直接返回原对话的准确消息位置。'
read_count=0
mode=os.environ.get('RECALL_FIXTURE_VERIFY_MODE','')
for line in sys.stdin:
 try:r=json.loads(line)
 except:continue
 if 'id' not in r:continue
 method=r.get('method');params=r.get('params',{})
 if mode=='slow' and method=='thread/items/list':
  import time
  time.sleep(1)
 if os.environ.get('RECALL_FIXTURE_TRACE'):
  with open(os.environ['RECALL_FIXTURE_TRACE'],'a') as trace:trace.write(method+'\n')
 if method=='initialize':answer={'userAgent':'readonly-fixture'}
 elif method=='thread/read':
  read_count+=1
  if read_count==3 and os.environ.get('RECALL_FIXTURE_LIFECYCLE')=='1':sys.exit(0)
  answer={'thread':{'id':thread,'name':'虚构对话'}}
 elif method=='thread/items/list':
  first=params.get('cursor') is None
  source=original
  source_id='message-original'
  if read_count==2 and os.environ.get('RECALL_FIXTURE_LIFECYCLE')=='1':source+='原文已改变。'
  if mode=='changed' or (mode=='change_after_third' and read_count>=3):source+='原文已改变。'
  if mode=='deleted':source_id='replacement-id'
  source_item={'type':'agentMessage','id':source_id,'text':source}
  other={'type':'agentMessage','id':'message-other','text':original if not mode else '与目标无关的虚构消息。'}
  if mode=='duplicate' or (mode=='append_after_third' and read_count>=3):other['text']=original
  if mode=='markup_duplicate':other['text']='点击**备注**后，直接返回原对话的准确消息位置。'
  if mode=='tool_duplicate':other={'type':'commandExecution','id':'tool','output':original}
  if mode=='split_tool_duplicate':other={'type':'toolOutput','id':'tool','content':[{'text':'点击备注后，直接返回'},{'text':'原对话的准确消息位置。'}]}
  if mode=='field_heavy':other={'type':'toolOutput','id':'tool','metadata':{f'field{i}':f'无关虚构字段{i}' for i in range(2000)},'output':'与目标无关的虚构结果。'}
  if mode=='nested_tool_after_third':other={'type':'toolOutput','id':'tool','nested':{'output':original if read_count>=3 else '与目标无关的虚构结果。'}}
  if mode=='reorder_after_third':
   parts=['点击备注后，直接返回','原对话的准确消息位置。']
   if read_count<3:parts.reverse()
   other={'type':'toolOutput','id':'tool','content':[{'text':text} for text in parts]}
  if params.get('turnId'):
   rows=[{'turnId':'turn-original','item':source_item}] if params['turnId']=='turn-original' else []
   answer={'data':rows,'nextCursor':None}
  else:answer={'data':[{'turnId':'turn-original' if first else 'turn-other','item':source_item if first else other}],'nextCursor':'fixture-page-two' if first else None}
 else:
  print(json.dumps({'id':r['id'],'error':{'message':'Non-read method refused'}}),flush=True);continue
 print(json.dumps({'id':r['id'],'result':answer}),flush=True)
