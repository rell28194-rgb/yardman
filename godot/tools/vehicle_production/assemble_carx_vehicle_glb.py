#!/usr/bin/env python3
from __future__ import annotations
import argparse, io, json, math, struct, hashlib
from pathlib import Path
from typing import Any
from PIL import Image

GLB_MAGIC=0x46546C67; GLB_JSON=0x4E4F534A; GLB_BIN=0x004E4942
FMT_SIZE={0:4,1:2}
ETC_MODS=((2,8,-2,-8),(5,17,-5,-17),(9,29,-9,-29),(13,42,-13,-42),(18,60,-18,-60),(24,80,-24,-80),(33,106,-33,-106),(47,183,-47,-183))
def a4(v:int)->int:return(v+3)&~3
class R:
 def __init__(self,d:bytes,p:int=0):self.d=d;self.p=p
 def i32(self):v=struct.unpack_from('<i',self.d,self.p)[0];self.p+=4;return v
 def u32(self):v=struct.unpack_from('<I',self.d,self.p)[0];self.p+=4;return v
 def i64(self):v=struct.unpack_from('<q',self.d,self.p)[0];self.p+=8;return v
 def u16(self):v=struct.unpack_from('<H',self.d,self.p)[0];self.p+=2;return v
 def u8(self):v=self.d[self.p];self.p+=1;return v
 def f32(self):v=struct.unpack_from('<f',self.d,self.p)[0];self.p+=4;return v
 def cstr(self):e=self.d.index(0,self.p);s=self.d[self.p:e].decode('utf8','replace');self.p=e+1;return s
 def astr(self):n=self.i32();s=self.d[self.p:self.p+n].decode('utf8','replace');self.p=a4(self.p+n);return s
 def pptr(self):return {'file_id':self.i32(),'path_id':self.i64()}
 def vec2(self):return [self.f32(),self.f32()]
 def color(self):return [self.f32() for _ in range(4)]

def read_sf(path:Path)->dict[str,Any]:
 raw=path.read_bytes(); ms,fs,ver,data_off=struct.unpack_from('>IIII',raw,0)
 if fs!=len(raw) or ver!=17:raise ValueError(f'{path.name}: expected serialized v17')
 r=R(raw,20);uv=r.cstr();platform=r.i32();typetree=r.u8()
 if not uv.startswith('2018.2.') or typetree:raise ValueError(f'{path.name}: unsupported Unity {uv} typetree={typetree}')
 tc=r.i32();classes=[]
 for _ in range(tc):
  cid=r.i32();r.u8();r.p+=2
  if cid==114:r.p+=16
  r.p+=16;classes.append(cid)
 oc=r.i32();objects={}
 for _ in range(oc):
  r.p=a4(r.p);pid=r.i64();start=r.u32();size=r.u32();ti=r.i32();objects[pid]={'class_id':classes[ti],'data':raw[data_off+start:data_off+start+size]}
 sc=r.i32();r.p+=sc*12;ec=r.i32();externals=[]
 for i in range(ec):
  temp=r.cstr();guid=raw[r.p:r.p+16].hex();r.p+=16;kind=r.i32();name=r.cstr();externals.append({'file_id':i+1,'path':name,'guid':guid,'type':kind,'temp':temp})
 return {'path':path,'sha256':hashlib.sha256(raw).hexdigest(),'unity':uv,'objects':objects,'externals':externals}

def resolve_ptr(sf:dict,ptr:dict)->tuple[str,int]:
 f=int(ptr['file_id']);p=int(ptr['path_id'])
 return (sf['path'].name,p) if f==0 else (sf['externals'][f-1]['path'],p)

def parse_go(d:bytes):
 r=R(d);n=r.i32();comps=[r.pptr() for _ in range(n)];layer=r.i32();name=r.astr();tag=r.u16();active=bool(r.u8());return {'components':comps,'layer':layer,'name':name,'active':active}
def parse_transform(d:bytes):
 r=R(d);go=r.pptr();q=[r.f32() for _ in range(4)];p=[r.f32() for _ in range(3)];s=[r.f32() for _ in range(3)];n=r.i32();children=[r.pptr() for _ in range(n)];father=r.pptr();return {'go':go,'rotation':q,'position':p,'scale':s,'children':children,'father':father}
def parse_meshfilter(d:bytes):r=R(d);return {'go':r.pptr(),'mesh':r.pptr()}
def parse_renderer(d:bytes):
 r=R(d);go=r.pptr();flags=list(d[r.p:r.p+8]);r.p+=8;r.u32();r.u16();r.u16();r.p+=32;n=r.i32();mats=[r.pptr() for _ in range(n)];return {'go':go,'materials':mats,'enabled':bool(flags[0])}

def prefab(sf:dict)->dict:
 parsed={}
 for pid,o in sf['objects'].items():
  cid=o['class_id'];d=o['data']
  if cid==1:parsed[pid]=(cid,parse_go(d))
  elif cid==4:parsed[pid]=(cid,parse_transform(d))
  elif cid==33:parsed[pid]=(cid,parse_meshfilter(d))
  elif cid==23:parsed[pid]=(cid,parse_renderer(d))
 gos={pid:t for pid,(cid,t) in parsed.items() if cid==1}; trs={pid:t for pid,(cid,t) in parsed.items() if cid==4}
 entries=[]
 for gpid,g in gos.items():
  local=[int(p['path_id']) for p in g['components'] if int(p['file_id'])==0]
  tid=next((x for x in local if x in parsed and parsed[x][0]==4),None); mf=next((x for x in local if x in parsed and parsed[x][0]==33),None);mr=next((x for x in local if x in parsed and parsed[x][0]==23),None)
  e={'go_pid':gpid,'name':g['name'],'active':g['active'],'transform_pid':tid}
  if tid:
   tr=trs[tid];e.update({'position':tr['position'],'rotation':tr['rotation'],'scale':tr['scale'],'father':tr['father'],'child_transforms':tr['children']})
  if mf:e['mesh']=resolve_ptr(sf,parsed[mf][1]['mesh'])
  if mr:e['materials']=[resolve_ptr(sf,p) for p in parsed[mr][1]['materials']];e['renderer_enabled']=parsed[mr][1]['enabled']
  entries.append(e)
 return {'entries':entries}

def aligned_string(d:bytes,o:int)->tuple[str,int]:
 n=struct.unpack_from('<i',d,o)[0];o+=4;return d[o:o+n].decode('utf8','replace'),a4(o+n)
def parse_mesh(d:bytes,pid:int)->dict:
 name,o=aligned_string(d,0);nsub=struct.unpack_from('<i',d,o)[0];o+=4;subs=[]
 for _ in range(nsub):
  first,count,topology,base,firstv,vcount=struct.unpack_from('<IIIIII',d,o);o+=24;o+=24
  if topology!=0:raise ValueError(f'{name}: non-triangle topology')
  subs.append((first,count,base))
 for label in range(4):
  n=struct.unpack_from('<i',d,o)[0];o+=4
  if n:raise ValueError(f'{name}: blend data unsupported')
 bind=struct.unpack_from('<i',d,o)[0];o+=4+bind*64; bone=struct.unpack_from('<i',d,o)[0];o+=4+bone*4;o+=4
 comp,readable,keepv,keepi=struct.unpack_from('<BBBB',d,o);o+=4
 if comp!=0:raise ValueError(f'{name}: compressed mesh')
 idxfmt=struct.unpack_from('<i',d,o)[0];o+=4; ibs=struct.unpack_from('<i',d,o)[0];o+=4;ib=d[o:o+ibs];o=a4(o+ibs)
 vc=struct.unpack_from('<I',d,o)[0];o+=4;cc=struct.unpack_from('<i',d,o)[0];o+=4;channels=[]
 for _ in range(cc):channels.append(struct.unpack_from('<BBBB',d,o));o+=4
 ds=struct.unpack_from('<i',d,o)[0];o+=4;vd=d[o:o+ds]
 active=[(i,*c) for i,c in enumerate(channels) if c[3]>0]
 if not active or active[0][0]!=0:raise ValueError(f'{name}: missing position')
 if any(st!=0 for _,st,_,_,_ in active):raise ValueError(f'{name}: multistream unsupported')
 if any(fmt not in FMT_SIZE for _,_,_,fmt,_ in active):raise ValueError(f'{name}: unsupported vertex format')
 stride=max(off+dim*FMT_SIZE[fmt] for _,_,off,fmt,dim in active)
 if stride*vc!=ds:raise ValueError(f'{name}: stride mismatch {stride}*{vc}!={ds}')
 def chan(ci:int,dims:int):
  if ci>=len(channels):return None
  st,off,fmt,dim=channels[ci]
  if dim==0:return None
  if fmt!=0 or dim<dims:return None
  f='<'+('f'*dims);return [struct.unpack_from(f,vd,i*stride+off) for i in range(vc)]
 pos=chan(0,3);norm=chan(1,3);uv=chan(4,2)
 if pos is None:raise ValueError(f'{name}: no positions')
 isz=2 if idxfmt==0 else 4; code='H' if isz==2 else 'I';ctype=5123 if isz==2 else 5125; prim=[]
 for first,count,base in subs:
  vals=list(struct.unpack_from('<'+code*count,ib,first))
  if base:vals=[x+base for x in vals]
  if any(x>=vc for x in vals):raise ValueError(f'{name}: bad index')
  prim.append(vals)
 return {'path_id':pid,'name':name,'positions':pos,'normals':norm,'uv0':uv,'indices':prim,'component_type':ctype,'stride':stride,'channels':channels}

def parse_material(sf:dict,d:bytes)->dict:
 r=R(d);name=r.astr();shader=resolve_ptr(sf,r.pptr());kw=r.astr();light=r.u32();inst=bool(r.u8());dbl=bool(r.u8());r.p=a4(r.p);queue=r.i32();tags={}
 for _ in range(r.i32()):tags[r.astr()]=r.astr()
 passes=[r.astr() for _ in range(r.i32())];tex={}
 for _ in range(r.i32()):
  k=r.astr();ptr=r.pptr();tex[k]={'target':resolve_ptr(sf,ptr),'scale':r.vec2(),'offset':r.vec2()}
 fl={}
 for _ in range(r.i32()):k=r.astr();fl[k]=r.f32()
 colors={}
 for _ in range(r.i32()):k=r.astr();colors[k]=r.color()
 return {'name':name,'keywords':kw,'queue':queue,'tags':tags,'textures':tex,'floats':fl,'colors':colors,'double_sided':dbl}

def parse_texture(d:bytes)->dict:
 r=R(d);name=r.astr();forced=r.i32();down=r.u8();r.p=a4(r.p);w=r.i32();h=r.i32();complete=r.u32();fmt=r.i32();mips=r.i32();r.p+=4;priority=r.i32();imgcount=r.i32();dim=r.i32();filterm=r.i32();aniso=r.i32();bias=r.f32();wrapu=r.i32();wrapv=r.i32();wrapw=r.i32();light=r.i32();cs=r.i32();size=r.i32();image=d[r.p:r.p+size];r.p=a4(r.p+size);streamoff=r.u32();streamsize=r.u32();streampath=r.astr()
 if streamsize or streampath:raise ValueError(f'{name}: streamed texture not bundled')
 return {'name':name,'width':w,'height':h,'format':fmt,'data':image,'mips':mips,'filter':filterm,'wrap_u':wrapu,'wrap_v':wrapv}
def clamp(v):return 0 if v<0 else 255 if v>255 else v
def e4(v):return(v<<4)|v
def e5(v):return(v<<3)|(v>>2)
def s3(v):return v-8 if v&4 else v
def decode_tex(t:dict)->Image.Image:
 w,h,fmt,data=t['width'],t['height'],t['format'],t['data']
 if fmt==3:return Image.frombytes('RGB',(w,h),data[:w*h*3]).transpose(Image.Transpose.FLIP_TOP_BOTTOM).convert('RGBA')
 if fmt==4:return Image.frombytes('RGBA',(w,h),data[:w*h*4]).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
 if fmt!=34:raise ValueError(f"{t['name']}: unsupported texture fmt {fmt}")
 out=bytearray(w*h*4);off=0
 for by in range((h+3)//4):
  for bx in range((w+3)//4):
   hi,lo=struct.unpack('>II',data[off:off+8]);off+=8;diff=(hi>>1)&1;flip=hi&1;t1=(hi>>5)&7;t2=(hi>>2)&7
   if diff:
    r1=(hi>>27)&31;g1=(hi>>19)&31;b1=(hi>>11)&31;r2=r1+s3((hi>>24)&7);g2=g1+s3((hi>>16)&7);b2=b1+s3((hi>>8)&7);c1=(e5(r1),e5(g1),e5(b1));c2=(e5(r2&31),e5(g2&31),e5(b2&31))
   else:c1=(e4((hi>>28)&15),e4((hi>>20)&15),e4((hi>>12)&15));c2=(e4((hi>>24)&15),e4((hi>>16)&15),e4((hi>>8)&15))
   for y in range(4):
    py=by*4+y
    if py>=h:continue
    for x in range(4):
     px=bx*4+x
     if px>=w:continue
     k=x*4+y;idx=((lo>>k)&1)|(((lo>>(k+16))&1)<<1);sec=(y>=2) if flip else (x>=2);bc=c2 if sec else c1;mod=ETC_MODS[t2 if sec else t1][idx];dst=((h-1-py)*w+px)*4;out[dst:dst+4]=bytes((clamp(bc[0]+mod),clamp(bc[1]+mod),clamp(bc[2]+mod),255))
 return Image.frombytes('RGBA',(w,h),bytes(out))

def pbr_params(m:dict)->tuple[float,float]:
 n=m['name'].lower()
 if 'chrome' in n:return .95,.12
 if 'metal' in n or 'disk' in n:return .8,.2
 if 'paint' in n:return .65,.28
 if 'glass' in n:return .0,.08
 if 'plastic' in n:return .05,.58
 if 'interior' in n:return .05,.48
 return .15,.42

def build(vehicle_manifest:Path,source_cache:Path,output:Path,report_path:Path|None=None)->dict:
 vm=json.loads(vehicle_manifest.read_text());identity=vm['identity'];root_name=vm['root_source_unit'];root_sf=read_sf(source_cache/root_name);pf=prefab(root_sf)
 file_meta={e['name']:e for e in vm['files']}; allowed=set(file_meta)
 cache={root_name:root_sf}
 def get_sf(name:str)->dict:
  if name not in allowed and name!=root_name:raise ValueError(f'unresolved dependency {name}')
  if name not in cache:cache[name]=read_sf(source_cache/name)
  return cache[name]
 selected=[]
 for e in pf['entries']:
  if 'mesh' not in e or 'materials' not in e:continue
  low=e['name'] in {'BodyL','InteriorL','DriverWheelL'} or e['name'].lower().startswith('shadowcaster') or e['name'].lower()=='interiorshadow'
  if not low:selected.append(e)
 mesh_assets={};mat_assets={};tex_assets={};used_files={root_name}
 for e in selected:
  fn,pid=e['mesh'];used_files.add(fn);sf=get_sf(fn);o=sf['objects'].get(pid)
  if not o or o['class_id']!=43:raise ValueError(f'{e["name"]}: mesh target {fn}:{pid} missing')
  mesh_assets[(fn,pid)]=parse_mesh(o['data'],pid)
  for mf,mpid in e['materials']:
   used_files.add(mf);msf=get_sf(mf);mo=msf['objects'].get(mpid)
   if not mo or mo['class_id']!=21:raise ValueError(f'material {mf}:{mpid} missing')
   mat=mat_assets.setdefault((mf,mpid),parse_material(msf,mo['data']))
   for prop,tv in mat['textures'].items():
    tf,tpid=tv['target']
    if tpid==0:continue
    used_files.add(tf);tsf=get_sf(tf);to=tsf['objects'].get(tpid)
    if not to or to['class_id']!=28:continue
    tex_assets.setdefault((tf,tpid),parse_texture(to['data']))
 doc={'asset':{'version':'2.0','generator':'Yardman CarX exact-source vehicle assembler'},'scene':0,'scenes':[{'nodes':[]}],'nodes':[],'meshes':[],'materials':[],'textures':[],'images':[],'samplers':[{'magFilter':9729,'minFilter':9987,'wrapS':10497,'wrapT':10497}],'buffers':[{'byteLength':0}],'bufferViews':[],'accessors':[],'extras':{'vehicle_identity':identity,'root_source_unit':root_name,'source_manifest':vehicle_manifest.name,'source_file_count':vm['file_count'],'source_total_uncompressed_bytes':vm['total_uncompressed_bytes']}}
 binary=bytearray()
 def view(payload:bytes,target=None,stride=None):
  while len(binary)%4:binary.append(0)
  st=len(binary);binary.extend(payload);v={'buffer':0,'byteOffset':st,'byteLength':len(payload)}
  if target:v['target']=target
  if stride:v['byteStride']=stride
  doc['bufferViews'].append(v);return len(doc['bufferViews'])-1
 def accessor(v,ctype,count,typ,bo=0,mn=None,mx=None):
  a={'bufferView':v,'componentType':ctype,'count':count,'type':typ}
  if bo:a['byteOffset']=bo
  if mn is not None:a['min']=mn
  if mx is not None:a['max']=mx
  doc['accessors'].append(a);return len(doc['accessors'])-1
 tex_index={}
 for key,t in sorted(tex_assets.items()):
  im=decode_tex(t);bio=io.BytesIO();im.save(bio,format='PNG',optimize=True);payload=bio.getvalue();bv=view(payload);doc['images'].append({'name':t['name'],'mimeType':'image/png','bufferView':bv,'extras':{'source_file':key[0],'source_path_id':key[1],'source_format':t['format']}});doc['textures'].append({'sampler':0,'source':len(doc['images'])-1});tex_index[key]=len(doc['textures'])-1
 mat_index={}
 for key,m in sorted(mat_assets.items()):
  color=list(m['colors'].get('_Color',[1,1,1,1]));metal,rough=pbr_params(m);pbr={'baseColorFactor':color,'metallicFactor':metal,'roughnessFactor':rough}
  main=m['textures'].get('_MainTex');alpha=m['textures'].get('_AlphaTex')
  if main and main['target'] in tex_index:
   if alpha and alpha['target'] in tex_index:
    base=decode_tex(tex_assets[main['target']]);am=decode_tex(tex_assets[alpha['target']]).convert('L')
    if base.size==am.size:
     base.putalpha(am);bio=io.BytesIO();base.save(bio,format='PNG',optimize=True);bv=view(bio.getvalue());doc['images'].append({'name':m['name']+'_combined','mimeType':'image/png','bufferView':bv});doc['textures'].append({'sampler':0,'source':len(doc['images'])-1});pbr['baseColorTexture']={'index':len(doc['textures'])-1}
    else:pbr['baseColorTexture']={'index':tex_index[main['target']]}
   else:pbr['baseColorTexture']={'index':tex_index[main['target']]}
  gm={'name':m['name'],'pbrMetallicRoughness':pbr,'doubleSided':True,'extras':{'source_file':key[0],'source_path_id':key[1],'source_keywords':m['keywords']}}
  if color[3]<.999 or 'glass' in m['name'].lower():gm['alphaMode']='BLEND'
  doc['materials'].append(gm);mat_index[key]=len(doc['materials'])-1
 mesh_index={}
 for e in selected:
  key=e['mesh']
  if key in mesh_index:continue
  m=mesh_assets[key];pos=[(x,y,-z) for x,y,z in m['positions']];norm=None if m['normals'] is None else [(x,y,-z) for x,y,z in m['normals']];uv=m['uv0'];vp=bytearray()
  for i,p in enumerate(pos):
   vp.extend(struct.pack('<fff',*p))
   if norm is not None:vp.extend(struct.pack('<fff',*norm[i]))
   if uv is not None:vp.extend(struct.pack('<ff',*uv[i]))
  stride=12+(12 if norm is not None else 0)+(8 if uv is not None else 0);vv=view(bytes(vp),34962,stride);mins=[min(p[i] for p in pos) for i in range(3)];maxs=[max(p[i] for p in pos) for i in range(3)];attrs={'POSITION':accessor(vv,5126,len(pos),'VEC3',0,mins,maxs)};bo=12
  if norm is not None:attrs['NORMAL']=accessor(vv,5126,len(pos),'VEC3',bo);bo+=12
  if uv is not None:attrs['TEXCOORD_0']=accessor(vv,5126,len(pos),'VEC2',bo)
  prim=[];mats=e['materials']
  if len(m['indices'])!=len(mats):raise ValueError(f'{e["name"]}: submesh/material mismatch')
  for si,idx in enumerate(m['indices']):
   rev=[]
   for j in range(0,len(idx),3):a,b,c=idx[j:j+3];rev+=(a,c,b)
   code='H' if m['component_type']==5123 else 'I';iv=view(struct.pack('<'+code*len(rev),*rev),34963);ia=accessor(iv,m['component_type'],len(rev),'SCALAR',0,[min(rev)],[max(rev)]);pr={'attributes':dict(attrs),'indices':ia,'mode':4,'material':mat_index[mats[si]]};prim.append(pr)
  doc['meshes'].append({'name':m['name'],'primitives':prim,'extras':{'source_file':key[0],'source_path_id':key[1]}});mesh_index[key]=len(doc['meshes'])-1
 node_by_tid={};rename={'BodyH':'BodyShell','InteriorH':'Interior','DriverWheelH':'SteeringWheel','WheelFL':'Wheel_FL','WheelFR':'Wheel_FR','WheelRL':'Wheel_RL','WheelRR':'Wheel_RR'}
 for e in pf['entries']:
  if not e.get('transform_pid'):continue
  n={'name':rename.get(e['name'],e['name'])};p=e['position'];q=e['rotation'];s=e['scale'];n['translation']=[p[0],p[1],-p[2]];n['rotation']=[-q[0],-q[1],q[2],q[3]];n['scale']=s
  if e in selected:n['mesh']=mesh_index[e['mesh']]
  n['extras']={'source_game_object_path_id':e['go_pid'],'source_active':e['active']};doc['nodes'].append(n);node_by_tid[e['transform_pid']]=len(doc['nodes'])-1
 roots=[]
 for e in pf['entries']:
  tid=e.get('transform_pid')
  if not tid or tid not in node_by_tid:continue
  ni=node_by_tid[tid];father=e.get('father',{'file_id':0,'path_id':0})
  if int(father['file_id'])==0 and int(father['path_id']) in node_by_tid:
   pi=node_by_tid[int(father['path_id'])];doc['nodes'][pi].setdefault('children',[]).append(ni)
  else:roots.append(ni)
 named_root=next((i for i in roots if doc['nodes'][i]['name']==identity),roots[0] if roots else None)
 if named_root is None:raise ValueError('no root node')
 doc['nodes'][named_root]['translation']=[0,0,0];doc['nodes'][named_root]['rotation']=[0,0,0,1];doc['nodes'][named_root]['scale']=[1,1,1];doc['scenes'][0]['nodes']=[named_root]
 doc['buffers'][0]['byteLength']=len(binary);js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*((-len(js))%4);bb=bytes(binary)+b'\0'*((-len(binary))%4);total=12+8+len(js)+8+len(bb);glb=struct.pack('<III',GLB_MAGIC,2,total)+struct.pack('<II',len(js),GLB_JSON)+js+struct.pack('<II',len(bb),GLB_BIN)+bb;output.write_bytes(glb)
 report={'format_version':1,'vehicle':identity,'root_source_unit':root_name,'output':output.name,'output_bytes':len(glb),'output_sha256':hashlib.sha256(glb).hexdigest(),'source_manifest':vehicle_manifest.name,'source_file_count':vm['file_count'],'selected_renderables':[e['name'] for e in selected],'selected_renderable_count':len(selected),'mesh_count':len(mesh_index),'material_count':len(mat_index),'source_texture_count':len(tex_index),'gltf_texture_count':len(doc['textures']),'node_count':len(doc['nodes']),'used_source_files':sorted(used_files),'body_shell_present':any(n['name']=='BodyShell' for n in doc['nodes']),'wheel_anchors_present':all(any(n['name']==w for n in doc['nodes']) for w in ['Wheel_FL','Wheel_FR','Wheel_RL','Wheel_RR']),'interior_present':any(n['name']=='Interior' and 'mesh' in n for n in doc['nodes']),'source_hashes':{n:file_meta[n]['sha256'] for n in sorted(used_files) if n in file_meta}}
 if report_path:report_path.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
 return report

def main():
 ap=argparse.ArgumentParser();ap.add_argument('manifest',type=Path);ap.add_argument('source_cache',type=Path);ap.add_argument('output',type=Path);ap.add_argument('--report',type=Path);a=ap.parse_args();r=build(a.manifest,a.source_cache,a.output,a.report);print(json.dumps(r,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
