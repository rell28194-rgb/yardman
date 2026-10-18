#!/usr/bin/env python3
from __future__ import annotations
import argparse,gzip,json,struct,hashlib
from pathlib import Path
from typing import Any

CLASS_NAMES={1:'GameObject',4:'Transform',23:'MeshRenderer',33:'MeshFilter'}

def align4(v:int)->int:return (v+3)&~3
class R:
 def __init__(self,d:bytes,p:int=0): self.d=d; self.p=p
 def i32(self): v=struct.unpack_from('<i',self.d,self.p)[0];self.p+=4;return v
 def u32(self): v=struct.unpack_from('<I',self.d,self.p)[0];self.p+=4;return v
 def i64(self): v=struct.unpack_from('<q',self.d,self.p)[0];self.p+=8;return v
 def u16(self): v=struct.unpack_from('<H',self.d,self.p)[0];self.p+=2;return v
 def u8(self): v=self.d[self.p];self.p+=1;return v
 def f32(self): v=struct.unpack_from('<f',self.d,self.p)[0];self.p+=4;return v
 def cstr(self):
  e=self.d.index(0,self.p);s=self.d[self.p:e].decode('utf8','replace');self.p=e+1;return s
 def astr(self):
  n=self.i32(); s=self.d[self.p:self.p+n].decode('utf8','replace'); self.p=align4(self.p+n); return s
 def pptr(self): return {'m_FileID':self.i32(),'m_PathID':self.i64()}

def read_raw(path:Path)->bytes:
 b=path.read_bytes(); return gzip.decompress(b) if path.suffix.lower()=='.gz' else b

def parse_file(path:Path)->dict[str,Any]:
 raw=read_raw(path)
 if len(raw)<20: raise ValueError('too small')
 ms,fs,version,data_offset=struct.unpack_from('>IIII',raw,0)
 if fs!=len(raw) or version!=17: raise ValueError(f'unsupported header fs={fs} actual={len(raw)} version={version}')
 r=R(raw,20); unity=r.cstr(); platform=r.i32(); type_tree=r.u8()
 if not unity.startswith('2018.2.') or type_tree: raise ValueError(f'unsupported unity={unity} typetree={type_tree}')
 tc=r.i32(); classes=[]
 for _ in range(tc):
  cid=r.i32();r.u8(); struct.unpack_from('<h',raw,r.p);r.p+=2
  if cid==114:r.p+=16
  r.p+=16; classes.append(cid)
 oc=r.i32(); objects=[]
 for _ in range(oc):
  r.p=align4(r.p); pid=r.i64(); st=r.u32(); sz=r.u32(); ti=r.i32();
  objects.append({'path_id':pid,'class_id':classes[ti],'offset':data_offset+st,'size':sz})
 script_count=r.i32()
 scripts=[]
 for _ in range(script_count): scripts.append({'file_id':r.i32(),'path_id':r.i64()})
 external_count=r.i32(); externals=[]
 for index in range(external_count):
  temp=r.cstr(); guid=raw[r.p:r.p+16].hex();r.p+=16; typ=r.i32(); name=r.cstr();
  externals.append({'file_id':index+1,'temp':temp,'guid':guid,'type':typ,'path':name})
 parsed={}
 for o in objects:
  cid=o['class_id']; data=raw[o['offset']:o['offset']+o['size']]
  if cid not in CLASS_NAMES: continue
  try: tree=parse_object(cid,data)
  except Exception as exc: tree={'_parse_error':str(exc)}
  parsed[str(o['path_id'])]={'type':CLASS_NAMES[cid],'class_id':cid,'size':o['size'],'tree':tree}
 hierarchy=build_hierarchy(parsed,externals)
 return {'format_version':1,'tool':'yardman_unity2018_vehicle_prefab_reader','source_file':path.name,'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'unity_version':unity,'platform':platform,'data_offset':data_offset,'objects_total':len(objects),'externals':externals,'objects':parsed,'hierarchy':hierarchy}

def parse_object(cid:int,data:bytes)->dict:
 r=R(data)
 if cid==1:
  n=r.i32(); comps=[{'component':r.pptr()} for _ in range(n)]; layer=r.i32(); name=r.astr(); tag=r.u16(); active=bool(r.u8())
  if r.p!=len(data): raise ValueError(f'GameObject trailing bytes {len(data)-r.p}')
  return {'m_Component':comps,'m_Layer':layer,'m_Name':name,'m_Tag':tag,'m_IsActive':active}
 if cid==4:
  go=r.pptr(); rot={k:r.f32() for k in ('x','y','z','w')}; pos={k:r.f32() for k in ('x','y','z')}; scale={k:r.f32() for k in ('x','y','z')}; n=r.i32(); children=[r.pptr() for _ in range(n)]; father=r.pptr()
  if r.p!=len(data): raise ValueError(f'Transform trailing bytes {len(data)-r.p}')
  return {'m_GameObject':go,'m_LocalRotation':rot,'m_LocalPosition':pos,'m_LocalScale':scale,'m_Children':children,'m_Father':father}
 if cid==33:
  tree={'m_GameObject':r.pptr(),'m_Mesh':r.pptr()}
  if r.p!=len(data): raise ValueError(f'MeshFilter trailing bytes {len(data)-r.p}')
  return tree
 if cid==23:
  go=r.pptr(); flags=list(data[r.p:r.p+8]); r.p+=8
  rendering_layer=r.u32(); lightmap_index=r.u16(); lightmap_dynamic=r.u16()
  lto={k:r.f32() for k in ('x','y','z','w')}; ltod={k:r.f32() for k in ('x','y','z','w')}
  n=r.i32(); mats=[r.pptr() for _ in range(n)]
  tail=data[r.p:]
  return {'m_GameObject':go,'m_Enabled':bool(flags[0]),'m_CastShadows':flags[1],'m_ReceiveShadows':flags[2],'m_DynamicOccludee':flags[3],'m_MotionVectors':flags[4],'m_LightProbeUsage':flags[5],'m_ReflectionProbeUsage':flags[6],'m_RenderingLayerMask':rendering_layer,'m_LightmapIndex':lightmap_index,'m_LightmapIndexDynamic':lightmap_dynamic,'m_LightmapTilingOffset':lto,'m_LightmapTilingOffsetDynamic':ltod,'m_Materials':mats,'_tail_bytes':len(tail)}
 raise ValueError(cid)

def pptr_target(ptr:dict, externals:list[dict])->dict:
 file_id=int(ptr.get('m_FileID',0)); path_id=int(ptr.get('m_PathID',0))
 result={'file_id':file_id,'path_id':path_id}
 if file_id>0 and file_id<=len(externals): result['external_path']=externals[file_id-1]['path']
 return result

def build_hierarchy(objects:dict, externals:list[dict])->dict:
 by_pid={int(pid):item for pid,item in objects.items()}
 gameobjects={pid:item['tree'] for pid,item in by_pid.items() if item['type']=='GameObject'}
 transforms={pid:item['tree'] for pid,item in by_pid.items() if item['type']=='Transform'}
 entries=[]; roots=[]
 for go_pid,go in sorted(gameobjects.items()):
  component_ids=[int(c['component']['m_PathID']) for c in go.get('m_Component',[]) if int(c['component']['m_FileID'])==0]
  transform_id=next((pid for pid in component_ids if by_pid.get(pid,{}).get('type')=='Transform'),None)
  mesh_filter_id=next((pid for pid in component_ids if by_pid.get(pid,{}).get('type')=='MeshFilter'),None)
  renderer_id=next((pid for pid in component_ids if by_pid.get(pid,{}).get('type')=='MeshRenderer'),None)
  entry={'game_object_path_id':go_pid,'name':go.get('m_Name',''),'active':bool(go.get('m_IsActive',True)),'layer':go.get('m_Layer'),'transform_path_id':transform_id}
  if transform_id is not None:
   tr=transforms[transform_id]
   entry['parent_transform']=pptr_target(tr['m_Father'],externals)
   entry['child_transforms']=[pptr_target(v,externals) for v in tr['m_Children']]
   entry['local_rotation']=tr['m_LocalRotation']; entry['local_position']=tr['m_LocalPosition']; entry['local_scale']=tr['m_LocalScale']
   if int(tr['m_Father']['m_PathID'])==0 and int(tr['m_Father']['m_FileID'])==0: roots.append({'game_object_path_id':go_pid,'transform_path_id':transform_id,'name':go.get('m_Name','')})
  if mesh_filter_id is not None:
   mf=by_pid[mesh_filter_id]['tree']; entry['mesh_filter_path_id']=mesh_filter_id; entry['mesh']=pptr_target(mf['m_Mesh'],externals)
  if renderer_id is not None:
   mr=by_pid[renderer_id]['tree']; entry['mesh_renderer_path_id']=renderer_id; entry['materials']=[pptr_target(v,externals) for v in mr['m_Materials']]
  entries.append(entry)
 return {'roots':roots,'entries':entries,'renderable_entries':sum(1 for e in entries if 'mesh' in e and 'materials' in e)}

def comparable(tree:dict)->dict:
 return {k:v for k,v in tree.items() if not k.startswith('_')}

def main()->int:
 ap=argparse.ArgumentParser();ap.add_argument('source',type=Path);ap.add_argument('--output',type=Path);ap.add_argument('--validate-unitypy-json',type=Path);args=ap.parse_args()
 report=parse_file(args.source)
 if args.validate_unitypy_json:
  truth=json.load(open(args.validate_unitypy_json)); mism=[]; counts={}
  for pid,item in report['objects'].items():
   counts[item['type']]=counts.get(item['type'],0)+1
   t=truth.get(pid)
   if not t or t.get('type')!=item['type']:
    mism.append({'path_id':pid,'reason':'missing_or_type'}); continue
   expected=comparable(t['tree']); actual=comparable(item['tree'])
   if item['type']=='MeshRenderer': expected={k:expected[k] for k in actual if k in expected}
   if actual!=expected: mism.append({'path_id':pid,'type':item['type'],'reason':'field_mismatch','actual':actual,'expected':expected})
  report['validation']={'ground_truth':args.validate_unitypy_json.name,'counts':counts,'mismatches':mism,'passed':not mism}
 text=json.dumps(report,indent=2,sort_keys=True)+'\n'
 if args.output: args.output.write_text(text)
 else: print(text,end='')
 return 0 if report.get('validation',{}).get('passed',True) else 1
if __name__=='__main__': raise SystemExit(main())
