#!/usr/bin/env python3
"""Upgrade an exact-source CarX hero GLB to Yardman's independent wheel rig contract.

CarX per-vehicle prefabs expose axle anchors/calipers but source tyre geometry is
provided by a shared runtime system outside the vehicle-local dependency closure.
This tool preserves those exact axle anchors, renames them to Yardman's runtime
contract, and adds a neutral provenance-marked tyre mesh under independent Spin
children. It never claims the fallback tyre geometry is recovered source art.
"""
from __future__ import annotations
import argparse, hashlib, json, math, struct
from pathlib import Path

GLB_MAGIC=0x46546C67; GLB_JSON=0x4E4F534A; GLB_BIN=0x004E4942
PIVOTS={"Wheel_FL":"FrontWheelLeft","Wheel_FR":"FrontWheelRight","Wheel_RL":"RearWheelLeft","Wheel_RR":"RearWheelRight"}

def pad4(data:bytes,fill:bytes=b"\0")->bytes:return data+fill*((-len(data))%4)

def read_glb(path:Path):
 b=path.read_bytes();magic,ver,total=struct.unpack_from('<III',b,0)
 if magic!=GLB_MAGIC or ver!=2 or total!=len(b):raise ValueError('invalid GLB header')
 jl,jt=struct.unpack_from('<II',b,12)
 if jt!=GLB_JSON:raise ValueError('missing JSON chunk')
 doc=json.loads(b[20:20+jl].decode('utf8').rstrip(' \0'))
 pos=20+jl
 if pos+8>len(b):return doc,b''
 bl,bt=struct.unpack_from('<II',b,pos);pos+=8
 if bt!=GLB_BIN:raise ValueError('missing BIN chunk')
 return doc,b[pos:pos+bl]

def write_glb(path:Path,doc:dict,binary:bytes)->bytes:
 doc['buffers'][0]['byteLength']=len(binary)
 js=pad4(json.dumps(doc,separators=(',',':')).encode(),b' ');bb=pad4(binary)
 payload=struct.pack('<III',GLB_MAGIC,2,12+8+len(js)+8+len(bb))+struct.pack('<II',len(js),GLB_JSON)+js+struct.pack('<II',len(bb),GLB_BIN)+bb
 path.write_bytes(payload);return payload

def append_view(doc:dict,binary:bytearray,payload:bytes,target:int|None=None,stride:int|None=None)->int:
 while len(binary)%4:binary.append(0)
 start=len(binary);binary.extend(payload);view={'buffer':0,'byteOffset':start,'byteLength':len(payload)}
 if target is not None:view['target']=target
 if stride is not None:view['byteStride']=stride
 doc.setdefault('bufferViews',[]).append(view);return len(doc['bufferViews'])-1

def add_accessor(doc:dict,view:int,ctype:int,count:int,kind:str,byte_offset:int=0,mn=None,mx=None)->int:
 a={'bufferView':view,'componentType':ctype,'count':count,'type':kind}
 if byte_offset:a['byteOffset']=byte_offset
 if mn is not None:a['min']=mn
 if mx is not None:a['max']=mx
 doc.setdefault('accessors',[]).append(a);return len(doc['accessors'])-1

def upgrade(source:Path,output:Path,report_path:Path|None=None)->dict:
 doc,bin0=read_glb(source);binary=bytearray(bin0);nodes=doc.setdefault('nodes',[]);names={n.get('name'):i for i,n in enumerate(nodes)}
 missing=[name for name in PIVOTS if name not in names]
 if missing:raise ValueError('missing recovered axle anchors: '+', '.join(missing))
 ys=[abs(float(nodes[names[name]].get('translation',[0,0,0])[1])) for name in PIVOTS]
 radius=max(.30,min(.45,sum(ys)/len(ys)));width=.24
 material={'name':'Yardman Runtime Tyre','pbrMetallicRoughness':{'baseColorFactor':[.025,.025,.025,1.0],'metallicFactor':0.0,'roughnessFactor':.88},'doubleSided':True,'extras':{'yardman_runtime_fallback':True,'reason':'CarX vehicle-local closure contains exact axle anchors/calipers but not shared runtime tyre art'}}
 doc.setdefault('materials',[]).append(material);material_index=len(doc['materials'])-1
 seg=24;positions=[];normals=[];uv=[]
 for side,x in enumerate((-width*.5,width*.5)):
  for k in range(seg):
   a=2*math.pi*k/seg;y=math.cos(a)*radius;z=math.sin(a)*radius
   positions.append((x,y,z));normals.append((0.0,math.cos(a),math.sin(a)));uv.append((float(side),float(k)/seg))
 vertex=bytearray()
 for i,p in enumerate(positions):vertex.extend(struct.pack('<fff',*p));vertex.extend(struct.pack('<fff',*normals[i]));vertex.extend(struct.pack('<ff',*uv[i]))
 vv=append_view(doc,binary,bytes(vertex),34962,32);mins=[min(p[i] for p in positions) for i in range(3)];maxs=[max(p[i] for p in positions) for i in range(3)]
 attrs={'POSITION':add_accessor(doc,vv,5126,len(positions),'VEC3',0,mins,maxs),'NORMAL':add_accessor(doc,vv,5126,len(positions),'VEC3',12),'TEXCOORD_0':add_accessor(doc,vv,5126,len(positions),'VEC2',24)}
 indices=[]
 for k in range(seg):
  n=(k+1)%seg;a=k;b=n;c=seg+k;d=seg+n;indices.extend((a,c,b,b,c,d))
 iv=append_view(doc,binary,struct.pack('<'+'H'*len(indices),*indices),34963);ia=add_accessor(doc,iv,5123,len(indices),'SCALAR',0,[min(indices)],[max(indices)])
 doc.setdefault('meshes',[]).append({'name':'YardmanRuntimeTyre','primitives':[{'attributes':attrs,'indices':ia,'mode':4,'material':material_index}],'extras':{'yardman_runtime_fallback':True}});mesh_index=len(doc['meshes'])-1
 names={n.get('name'):i for i,n in enumerate(nodes)}
 for old,new in PIVOTS.items():
  pi=names[old];nodes[pi]['name']=new;si=len(nodes);nodes.append({'name':new+'Spin','mesh':mesh_index,'translation':[0,0,0],'rotation':[0,0,0,1],'scale':[1,1,1],'extras':{'yardman_runtime_wheel_fallback':True}});nodes[pi].setdefault('children',[]).append(si)
 payload=write_glb(output,doc,bytes(binary));parents={}
 for i,n in enumerate(nodes):
  for c in n.get('children',[]):parents[c]=i
 names={n.get('name'):i for i,n in enumerate(nodes)};body=names.get('BodyShell');errors=[]
 def ancestor(a:int,b:int)->bool:
  cur=b
  while cur in parents:
   cur=parents[cur]
   if cur==a:return True
  return False
 for new in PIVOTS.values():
  p=names.get(new);s=names.get(new+'Spin')
  if p is None or s is None or parents.get(s)!=p:errors.append(new)
  elif body is not None and (ancestor(body,p) or ancestor(p,body)):errors.append(new+'_body_coupled')
 report={'format_version':1,'tool':'yardman_carx_runtime_rig_upgrade','source':source.name,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'output':output.name,'output_bytes':len(payload),'output_sha256':hashlib.sha256(payload).hexdigest(),'runtime_wheel_fallback':True,'wheel_radius_m':radius,'wheel_width_m':width,'pivots':list(PIVOTS.values()),'wheel_spin_contract_passed':not errors,'errors':errors}
 if report_path:report_path.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
 if errors:raise ValueError('runtime wheel contract failed: '+', '.join(errors))
 return report

def main()->int:
 p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);p.add_argument('--report',type=Path);a=p.parse_args();print(json.dumps(upgrade(a.source,a.output,a.report),indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
