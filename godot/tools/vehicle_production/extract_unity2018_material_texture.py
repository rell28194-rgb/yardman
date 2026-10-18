#!/usr/bin/env python3
"""Dependency-free Unity 2018.2 Material/Texture2D recovery for Yardman vehicle sources."""
from __future__ import annotations
import argparse,gzip,hashlib,json,struct
from pathlib import Path
from typing import Any
from PIL import Image

MATERIAL=21; TEXTURE2D=28
MODS=((2,8,-2,-8),(5,17,-5,-17),(9,29,-9,-29),(13,42,-13,-42),(18,60,-18,-60),(24,80,-24,-80),(33,106,-33,-106),(47,183,-47,-183))
def align4(v:int)->int:return (v+3)&~3
class Reader:
 def __init__(self,data:bytes,pos:int=0):self.data=data;self.pos=pos
 def i32(self):v=struct.unpack_from('<i',self.data,self.pos)[0];self.pos+=4;return v
 def u32(self):v=struct.unpack_from('<I',self.data,self.pos)[0];self.pos+=4;return v
 def i64(self):v=struct.unpack_from('<q',self.data,self.pos)[0];self.pos+=8;return v
 def u8(self):v=self.data[self.pos];self.pos+=1;return v
 def f32(self):v=struct.unpack_from('<f',self.data,self.pos)[0];self.pos+=4;return v
 def cstr(self):e=self.data.index(0,self.pos);s=self.data[self.pos:e].decode('utf8','replace');self.pos=e+1;return s
 def astr(self):n=self.i32();s=self.data[self.pos:self.pos+n].decode('utf8','replace');self.pos=align4(self.pos+n);return s
 def pptr(self):return {'m_FileID':self.i32(),'m_PathID':self.i64()}
 def vec2(self):return {'x':self.f32(),'y':self.f32()}
 def color(self):return {k:self.f32() for k in 'rgba'}

def raw_bytes(path:Path)->bytes:
 data=path.read_bytes();return gzip.decompress(data) if path.suffix.lower()=='.gz' else data

def serialized(path:Path)->dict[str,Any]:
 compressed=path.read_bytes();raw=raw_bytes(path)
 metadata_size,file_size,version,data_offset=struct.unpack_from('>IIII',raw,0)
 if file_size!=len(raw) or version!=17:raise ValueError('expected Unity serialized-file version 17')
 r=Reader(raw,20);unity=r.cstr();platform=r.i32();type_tree=r.u8()
 if not unity.startswith('2018.2.') or type_tree:raise ValueError(f'unsupported Unity source {unity} typetree={type_tree}')
 type_count=r.i32();classes=[]
 for _ in range(type_count):
  cid=r.i32();r.u8();r.pos+=2
  if cid==114:r.pos+=16
  r.pos+=16;classes.append(cid)
 object_count=r.i32();objects={}
 for _ in range(object_count):
  r.pos=align4(r.pos);pid=r.i64();start=r.u32();size=r.u32();ti=r.i32();objects[pid]={'class_id':classes[ti],'data':raw[data_offset+start:data_offset+start+size]}
 script_count=r.i32();r.pos+=script_count*12
 external_count=r.i32();externals=[]
 for index in range(external_count):
  temp=r.cstr();guid=raw[r.pos:r.pos+16].hex();r.pos+=16;kind=r.i32();name=r.cstr();externals.append({'file_id':index+1,'path':name,'guid':guid,'type':kind,'temp':temp})
 return {'source_file':path.name,'source_sha256':hashlib.sha256(compressed).hexdigest(),'unity_version':unity,'platform':platform,'objects':objects,'externals':externals}

def target(ptr:dict,externals:list[dict])->dict:
 f=int(ptr['m_FileID']);p=int(ptr['m_PathID']);out={'file_id':f,'path_id':p}
 if f>0 and f<=len(externals):out['external_path']=externals[f-1]['path']
 return out

def parse_material(data:bytes,externals:list[dict])->dict:
 r=Reader(data);name=r.astr();shader=target(r.pptr(),externals);keywords=r.astr();lightmap=r.u32();inst=bool(r.u8());double=bool(r.u8());r.pos=align4(r.pos);queue=r.i32()
 tags={}
 for _ in range(r.i32()):
  key=r.astr();value=r.astr();tags[key]=value
 passes=[r.astr() for _ in range(r.i32())]
 texenvs={}
 for _ in range(r.i32()):
  key=r.astr();texenvs[key]={'m_Texture':target(r.pptr(),externals),'m_Scale':r.vec2(),'m_Offset':r.vec2()}
 floats={}
 for _ in range(r.i32()):
  key=r.astr();value=r.f32();floats[key]=value
 colors={}
 for _ in range(r.i32()):
  key=r.astr();value=r.color();colors[key]=value
 if r.pos!=len(data):raise ValueError(f'Material trailing bytes {len(data)-r.pos}')
 return {'m_Name':name,'m_Shader':shader,'m_ShaderKeywords':keywords,'m_LightmapFlags':lightmap,'m_EnableInstancingVariants':inst,'m_DoubleSidedGI':double,'m_CustomRenderQueue':queue,'m_StringTagMap':tags,'m_DisabledShaderPasses':passes,'m_SavedProperties':{'m_TexEnvs':texenvs,'m_Floats':floats,'m_Colors':colors}}

def parse_texture(data:bytes)->dict:
 r=Reader(data);name=r.astr();forced=r.i32();downscale=bool(r.u8());r.pos=align4(r.pos);width=r.i32();height=r.i32();complete=r.u32();fmt=r.i32();mips=r.i32();flags=list(data[r.pos:r.pos+4]);r.pos+=4;priority=r.i32();image_count=r.i32();dimension=r.i32();filter_mode=r.i32();aniso=r.i32();mip_bias=r.f32();wrap_u=r.i32();wrap_v=r.i32();wrap_w=r.i32();lightmap=r.i32();color_space=r.i32();size=r.i32();image=data[r.pos:r.pos+size];r.pos=align4(r.pos+size);stream_offset=r.u32();stream_size=r.u32();stream_path=r.astr()
 if r.pos!=len(data):raise ValueError(f'Texture2D trailing bytes {len(data)-r.pos}')
 return {'m_Name':name,'m_ForcedFallbackFormat':forced,'m_DownscaleFallback':downscale,'m_Width':width,'m_Height':height,'m_CompleteImageSize':complete,'m_TextureFormat':fmt,'m_MipCount':mips,'m_Flags':flags,'m_StreamingMipmapsPriority':priority,'m_ImageCount':image_count,'m_TextureDimension':dimension,'m_TextureSettings':{'m_FilterMode':filter_mode,'m_Aniso':aniso,'m_MipBias':mip_bias,'m_WrapU':wrap_u,'m_WrapV':wrap_v,'m_WrapW':wrap_w},'m_LightmapFormat':lightmap,'m_ColorSpace':color_space,'image_data':image,'m_StreamData':{'offset':stream_offset,'size':stream_size,'path':stream_path}}

def _clamp(v:int)->int:return 0 if v<0 else 255 if v>255 else v
def _e4(v:int)->int:return (v<<4)|v
def _e5(v:int)->int:return (v<<3)|(v>>2)
def _s3(v:int)->int:return v-8 if v&4 else v

def decode_texture(texture:dict)->Image.Image:
 fmt=int(texture['m_TextureFormat']);w=int(texture['m_Width']);h=int(texture['m_Height']);data=texture['image_data']
 if fmt==3:
  need=w*h*3
  if len(data)<need:raise ValueError('truncated RGB24 base level')
  return Image.frombytes('RGB',(w,h),data[:need]).transpose(Image.Transpose.FLIP_TOP_BOTTOM).convert('RGBA')
 if fmt==4:
  need=w*h*4
  if len(data)<need:raise ValueError('truncated RGBA32 base level')
  return Image.frombytes('RGBA',(w,h),data[:need]).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
 if fmt!=34:raise ValueError(f'validated Texture2D formats are RGB24(3), RGBA32(4), ETC_RGB4(34); got {fmt}')
 base=((w+3)//4)*((h+3)//4)*8
 if len(data)<base:raise ValueError('truncated ETC1 base level')
 pixels=bytearray(w*h*4);off=0
 for by in range((h+3)//4):
  for bx in range((w+3)//4):
   hi,lo=struct.unpack('>II',data[off:off+8]);off+=8;diff=(hi>>1)&1;flip=hi&1;t1=(hi>>5)&7;t2=(hi>>2)&7
   if diff:
    r1=(hi>>27)&31;g1=(hi>>19)&31;b1=(hi>>11)&31;r2=r1+_s3((hi>>24)&7);g2=g1+_s3((hi>>16)&7);b2=b1+_s3((hi>>8)&7);c1=(_e5(r1),_e5(g1),_e5(b1));c2=(_e5(r2&31),_e5(g2&31),_e5(b2&31))
   else:c1=(_e4((hi>>28)&15),_e4((hi>>20)&15),_e4((hi>>12)&15));c2=(_e4((hi>>24)&15),_e4((hi>>16)&15),_e4((hi>>8)&15))
   for y in range(4):
    py=by*4+y
    if py>=h:continue
    for x in range(4):
     px=bx*4+x
     if px>=w:continue
     k=x*4+y;idx=((lo>>k)&1)|(((lo>>(k+16))&1)<<1);second=(y>=2) if flip else (x>=2);basec=c2 if second else c1;mod=MODS[t2 if second else t1][idx];dst=((h-1-py)*w+px)*4
     pixels[dst:dst+4]=bytes((_clamp(basec[0]+mod),_clamp(basec[1]+mod),_clamp(basec[2]+mod),255))
 return Image.frombytes('RGBA',(w,h),bytes(pixels))

def main()->int:
 ap=argparse.ArgumentParser();ap.add_argument('source',type=Path);ap.add_argument('--path-id',type=int,default=1);ap.add_argument('--report',type=Path);ap.add_argument('--png',type=Path);args=ap.parse_args();sf=serialized(args.source);obj=sf['objects'].get(args.path_id)
 if obj is None:raise SystemExit('path ID not found')
 cid=obj['class_id'];report={'format_version':1,'tool':'yardman_unity2018_material_texture_recovery','source_file':sf['source_file'],'source_sha256':sf['source_sha256'],'unity_version':sf['unity_version'],'path_id':args.path_id,'class_id':cid}
 if cid==MATERIAL:report['material']=parse_material(obj['data'],sf['externals'])
 elif cid==TEXTURE2D:
  tex=parse_texture(obj['data']);report['texture']={k:v for k,v in tex.items() if k!='image_data'};report['texture']['image_data_bytes']=len(tex['image_data']);report['texture']['image_data_sha256']=hashlib.sha256(tex['image_data']).hexdigest()
  if args.png:
   image=decode_texture(tex);args.png.parent.mkdir(parents=True,exist_ok=True);image.save(args.png);report['png_file']=args.png.name;report['png_sha256']=hashlib.sha256(args.png.read_bytes()).hexdigest()
 else:raise SystemExit(f'path ID class {cid} is neither Material nor Texture2D')
 text=json.dumps(report,indent=2,sort_keys=True)+'\n';print(text,end='')
 if args.report:args.report.write_text(text)
 return 0
if __name__=='__main__':raise SystemExit(main())
