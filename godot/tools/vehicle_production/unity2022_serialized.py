#!/usr/bin/env python3
from __future__ import annotations
import struct, json
from pathlib import Path
from dataclasses import dataclass
from typing import Any

COMMON={0:'AABB',5:'AnimationClip',19:'AnimationCurve',34:'AnimationState',49:'Array',55:'Base',60:'BitField',69:'bitset',76:'bool',81:'char',86:'ColorRGBA',96:'Component',106:'data',111:'deque',117:'double',124:'dynamic_array',138:'FastPropertyName',155:'first',161:'float',167:'Font',172:'GameObject',183:'Generic Mono',196:'GradientNEW',208:'GUID',213:'GUIStyle',222:'int',226:'list',231:'long long',241:'map',245:'Matrix4x4f',256:'MdFour',263:'MonoBehaviour',277:'MonoScript',288:'m_ByteSize',299:'m_Curve',307:'m_EditorClassIdentifier',331:'m_EditorHideFlags',349:'m_Enabled',359:'m_ExtensionPtr',374:'m_GameObject',387:'m_Index',395:'m_IsArray',405:'m_IsStatic',416:'m_MetaFlag',427:'m_Name',434:'m_ObjectHideFlags',452:'m_PrefabInternal',469:'m_PrefabParentObject',490:'m_Script',499:'m_StaticEditorFlags',519:'m_Type',526:'m_Version',536:'Object',543:'pair',548:'PPtr<Component>',564:'PPtr<GameObject>',581:'PPtr<Material>',596:'PPtr<MonoBehaviour>',616:'PPtr<MonoScript>',633:'PPtr<Object>',646:'PPtr<Prefab>',659:'PPtr<Sprite>',672:'PPtr<TextAsset>',688:'PPtr<Texture>',702:'PPtr<Texture2D>',718:'PPtr<Transform>',734:'Prefab',741:'Quaternionf',753:'Rectf',759:'RectInt',767:'RectOffset',778:'second',785:'set',789:'short',795:'size',800:'SInt16',807:'SInt32',814:'SInt64',821:'SInt8',827:'staticvector',840:'string',847:'TextAsset',857:'TextMesh',866:'Texture',874:'Texture2D',884:'Transform',894:'TypelessData',907:'UInt16',914:'UInt32',921:'UInt64',928:'UInt8',934:'unsigned int',947:'unsigned long long',966:'unsigned short',981:'vector',988:'Vector2f',997:'Vector3f',1006:'Vector4f',1015:'m_ScriptingClassIdentifier',1042:'Gradient',1051:'Type*',1057:'int2_storage',1070:'int3_storage',1083:'BoundsInt',1093:'m_CorrespondingSourceObject',1121:'m_PrefabInstance',1138:'m_PrefabAsset',1152:'FileSize'}
ALIGN=0x4000

def a4(x): return (x+3)&~3
class Reader:
 def __init__(self,d:bytes,p=0,end='<'): self.d=d; self.p=p; self.end=end
 def align(self,n=4): self.p=(self.p+n-1)&~(n-1)
 def read(self,n): v=self.d[self.p:self.p+n]; self.p+=n; return v
 def unpack(self,f): f=self.end+f; n=struct.calcsize(f); v=struct.unpack_from(f,self.d,self.p); self.p+=n; return v[0] if len(v)==1 else v
 def i8(self): return self.unpack('b')
 def u8(self): return self.unpack('B')
 def i16(self): return self.unpack('h')
 def u16(self): return self.unpack('H')
 def i32(self): return self.unpack('i')
 def u32(self): return self.unpack('I')
 def i64(self): return self.unpack('q')
 def u64(self): return self.unpack('Q')
 def f32(self): return self.unpack('f')
 def f64(self): return self.unpack('d')
 def cstr(self): e=self.d.index(0,self.p); s=self.d[self.p:e].decode('utf8','replace'); self.p=e+1; return s
 def astr(self): n=self.i32(); s=self.read(n).decode('utf8','replace'); self.align(); return s

@dataclass
class Node:
 version:int; level:int; flags:int; typ:str; name:str; byte_size:int; index:int; meta:int; ref_hash:int
@dataclass
class SType:
 class_id:int; script_idx:int; nodes:list[Node]; deps:list[int]
@dataclass
class Obj:
 path_id:int; start:int; size:int; type_index:int; class_id:int

class Serialized:
 def __init__(self,path:Path):
  self.path=Path(path); self.data=self.path.read_bytes(); self.types=[];self.objects=[];self.externals=[]; self.parse()
 def parse(self):
  b=self.data
  # Unity 2022 SerializedFile v22: the legacy prefix keeps only the version;
  # the extension contains the real metadata size, 64-bit file size/offset.
  self.version=struct.unpack_from('>I',b,8)[0]
  if self.version>=22:
   self.metadata_size=struct.unpack_from('>I',b,20)[0];self.file_size=struct.unpack_from('>Q',b,24)[0];self.data_offset=struct.unpack_from('>Q',b,32)[0]; self.endian='<'; p=48
  else: raise ValueError('only SerializedFile v22+ is supported')
  if self.file_size != len(b): raise ValueError(f'file-size mismatch {self.file_size}!={len(b)}')
  r=Reader(b,p,self.endian); self.unity=r.cstr();self.platform=r.i32();self.type_tree=bool(r.u8()); nt=r.i32()
  for _ in range(nt):
   cid=r.i32(); stripped=r.u8(); script_idx=r.i16()
   if script_idx>=0 and cid==114: r.read(16)
   r.read(16)
   nodes=[]
   if self.type_tree:
    nc=r.i32(); ss=r.i32(); raw=r.read(nc*32); sb=r.read(ss)
    for i in range(nc):
     ver,lev,fl,to,no,bs,idx,meta,refh=struct.unpack_from('<HBBIIiiiQ',raw,i*32)
     def s(off):
      if off&0x80000000:return COMMON.get(off&0x7fffffff,f'COMMON_{off&0x7fffffff}')
      e=sb.index(0,off);return sb[off:e].decode('utf8','replace')
     nodes.append(Node(ver,lev,fl,s(to),s(no),bs,idx,meta,refh))
   depn=r.i32(); deps=[r.i32() for _ in range(depn)]
   self.types.append(SType(cid,script_idx,nodes,deps))
  oc=r.i32()
  for _ in range(oc):
   r.align(); pid=r.i64(); start=r.i64(); size=r.u32(); ti=r.i32(); self.objects.append(Obj(pid,start,size,ti,self.types[ti].class_id))
  sc=r.i32(); self.script_types=[]
  for _ in range(sc):
   file_index=r.i32();r.align();local=r.i64();self.script_types.append((file_index,local))
  ec=r.i32()
  for _ in range(ec):
   temp=r.cstr();guid=r.read(16).hex();kind=r.i32();path=r.cstr();self.externals.append({'temp':temp,'guid':guid,'type':kind,'path':path})
  rtc=r.i32(); self.ref_types=[]
  for _ in range(rtc):
   cid=r.i32(); stripped=r.u8(); script_idx=r.i16()
   if script_idx>=0: r.read(16)
   r.read(16); nodes=[]
   if self.type_tree:
    nc=r.i32();ss=r.i32();raw=r.read(nc*32);sb=r.read(ss)
    for i in range(nc):
     ver,lev,fl,to,no,bs,idx,meta,refh=struct.unpack_from('<HBBIIiiiQ',raw,i*32)
     def s(off):
      if off&0x80000000:return COMMON.get(off&0x7fffffff,f'COMMON_{off&0x7fffffff}')
      e=sb.index(0,off);return sb[off:e].decode('utf8','replace')
     nodes.append(Node(ver,lev,fl,s(to),s(no),bs,idx,meta,refh))
   cname=r.cstr();ns=r.cstr();assembly=r.cstr();self.ref_types.append((cid,cname,ns,assembly,nodes))
  self.user_info=r.cstr(); self.metadata_end=r.p
 def obj_data(self,o:Obj): return self.data[self.data_offset+o.start:self.data_offset+o.start+o.size]
 def read_obj(self,o:Obj):
  nodes=self.types[o.type_index].nodes
  if not nodes:return None
  rr=Reader(self.obj_data(o),0,self.endian); value,ni=self._read_value(nodes,0,rr)
  if rr.p!=o.size: raise ValueError(f'obj {o.path_id} class {o.class_id}: read {rr.p}/{o.size} node_end={ni}')
  return value
 def _subtree_end(self,nodes,i):
  lev=nodes[i].level; j=i+1
  while j<len(nodes) and nodes[j].level>lev:j+=1
  return j
 def _read_value(self,nodes,i,r):
  n=nodes[i]; typ=n.typ; align=bool(n.meta&ALIGN)
  if typ=='SInt8': v=r.i8(); ni=i+1
  elif typ in ('UInt8','char'):v=r.u8();ni=i+1
  elif typ in ('short','SInt16'):v=r.i16();ni=i+1
  elif typ in ('UInt16','unsigned short'):v=r.u16();ni=i+1
  elif typ in ('int','SInt32'):v=r.i32();ni=i+1
  elif typ in ('UInt32','unsigned int','Type*'):v=r.u32();ni=i+1
  elif typ in ('long long','SInt64'):v=r.i64();ni=i+1
  elif typ in ('UInt64','unsigned long long','FileSize'):v=r.u64();ni=i+1
  elif typ=='float':v=r.f32();ni=i+1
  elif typ=='double':v=r.f64();ni=i+1
  elif typ=='bool':v=bool(r.u8());ni=i+1
  elif typ=='string': v=r.astr(); ni=min(i+4,len(nodes))
  elif typ=='TypelessData': size=r.i32();v=r.read(size);ni=min(i+3,len(nodes))
  elif typ=='map':
   end=self._subtree_end(nodes,i); pair_i=next(k for k in range(i+1,end) if nodes[k].typ=='pair'); first_i=pair_i+1; second_i=self._subtree_end(nodes,first_i); count=r.i32(); v=[]
   for _ in range(count):
    k,_=self._read_value(nodes,first_i,r); val,_=self._read_value(nodes,second_i,r);v.append((k,val))
   ni=end
  elif i+1<len(nodes) and nodes[i+1].typ=='Array' and nodes[i+1].level==n.level+1:
   end=self._subtree_end(nodes,i); data_i=i+3; count=r.i32();v=[]
   for _ in range(count): x,_=self._read_value(nodes,data_i,r);v.append(x)
   ni=end
   if nodes[i+1].meta&ALIGN: align=True
  else:
   end=self._subtree_end(nodes,i);v={};j=i+1
   while j<end:
    x,nj=self._read_value(nodes,j,r);v[nodes[j].name]=x;j=nj
   ni=end
  if align:r.align()
  return v,ni

def _reshape(vals,n): return [tuple(vals[i:i+n]) for i in range(0,len(vals),n)]
def unpack_ints(p,start=0,count=None):
 bs=int(p.get('m_BitSize',0)); data=p.get('m_Data',[]); n=int(p.get('m_NumItems',0)) if count is None else count
 bitpos=bs*start; ip=bitpos//8; bitpos%=8; out=[]
 if bs==0:return [0]*n
 mask=(1<<bs)-1
 for _ in range(n):
  bits=0;val=0
  while bits<bs:
   val |= (int(data[ip])>>bitpos)<<bits
   take=min(bs-bits,8-bitpos);bitpos+=take;bits+=take
   if bitpos==8:ip+=1;bitpos=0
  out.append(val&mask)
 return out
def unpack_floats(p,start=0,count=None):
 n=int(p.get('m_NumItems',0)) if count is None else count; bs=int(p.get('m_BitSize',0)); st=float(p.get('m_Start',0));rg=float(p.get('m_Range',0))
 if bs==0:return [st]*n
 vals=unpack_ints(p,start,n); scale=rg/((1<<bs)-1); return [x*scale+st for x in vals]
def decode_mesh(mesh:dict):
 import math
 cm=mesh['m_CompressedMesh']; vcount=int(cm['m_Vertices']['m_NumItems'])//3
 pos=_reshape(unpack_floats(cm['m_Vertices']),3) if vcount else []
 uv0=None; uv=cm['m_UV']; uvi=int(cm.get('m_UVInfo',0) or 0)
 if int(uv['m_NumItems'])>0:
  if uvi:
   off=0;channels={}
   for ch in range(8):
    bits=(uvi>>(ch*4))&15
    if bits&4:
     dim=1+(bits&3); vals=unpack_floats(uv,off,vcount*dim); channels[ch]=_reshape(vals,dim);off+=vcount*dim
   uv0=channels.get(0)
  else: uv0=_reshape(unpack_floats(uv,0,vcount*2),2)
 normals=None
 if int(cm['m_Normals']['m_NumItems'])>0:
  xy=_reshape(unpack_floats(cm['m_Normals']),2); signs=unpack_ints(cm['m_NormalSigns']);arr=[]
  for (x,y),sgn in zip(xy,signs):
   z2=1-x*x-y*y
   if z2>=0:z=math.sqrt(z2)
   else:
    z=0;L=math.sqrt(x*x+y*y) or 1;x/=L;y/=L
   if sgn==0:z=-z
   arr.append((x,y,z))
  normals=arr
 idx=unpack_ints(cm['m_Triangles']) if int(cm['m_Triangles']['m_NumItems'])>0 else []
 sub=[]; use16=int(mesh.get('m_IndexFormat',0))==0
 for sm in mesh['m_SubMeshes']:
  first=int(sm['firstByte'])//(2 if use16 else 4); count=int(sm['indexCount']); topo=int(sm['topology']); vals=idx[first:first+count]
  if topo==0:tris=[tuple(vals[i:i+3]) for i in range(0,len(vals),3)]
  elif topo==1:
   tris=[]
   for j in range(len(vals)-2):
    a,b,c=vals[j:j+3]
    if len({a,b,c})<3:continue
    tris.append((b,a,c) if j&1 else (a,b,c))
  elif topo==2:
   tris=[]
   for j in range(0,len(vals),4):
    a,b,c,d=vals[j:j+4];tris.extend([(a,b,c),(a,c,d)])
  else:raise ValueError(f'unsupported topology {topo}')
  sub.append(tris)
 return {'name':mesh['m_Name'],'positions':pos,'normals':normals,'uv0':uv0,'submeshes':sub,'indices':idx}

def main():
 import argparse
 ap=argparse.ArgumentParser();ap.add_argument('file',type=Path);ap.add_argument('--dump-class',type=int);ap.add_argument('--limit',type=int,default=3);a=ap.parse_args()
 sf=Serialized(a.file); print(json.dumps({'version':sf.version,'unity':sf.unity,'platform':sf.platform,'types':len(sf.types),'objects':len(sf.objects),'externals':sf.externals,'metadata_end':sf.metadata_end,'data_offset':sf.data_offset},indent=2))
 if a.dump_class is not None:
  for o in [x for x in sf.objects if x.class_id==a.dump_class][:a.limit]:
   print('OBJECT',o); print(json.dumps(sf.read_obj(o),indent=2,default=lambda x:list(x) if isinstance(x,(bytes,bytearray)) else str(x))[:20000])
if __name__=='__main__':raise SystemExit(main())
