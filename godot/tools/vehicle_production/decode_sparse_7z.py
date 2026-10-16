#!/usr/bin/env python3
"""Dependency-free 7z metadata decoder/extractor for Yardman's split Beta archives.

Supports the subset used by recovered Yardman sources: COPY, LZMA and LZMA2
single-coder folders, encoded headers, file-name tables, and one-substream folders.
Large members are decoded incrementally so RR3's multi-gigabyte solid stream does
not need to be resident in memory.
"""
from __future__ import annotations

import argparse, io, json, lzma, struct, zlib
from pathlib import Path
from typing import Any

K_END=0x00; K_HEADER=0x01; K_ARCHIVE_PROPERTIES=0x02; K_ADDITIONAL_STREAMS=0x03; K_MAIN_STREAMS=0x04; K_FILES_INFO=0x05
K_PACK_INFO=0x06; K_UNPACK_INFO=0x07; K_SUBSTREAMS_INFO=0x08; K_SIZE=0x09; K_CRC=0x0A; K_FOLDER=0x0B; K_CODERS_UNPACK_SIZE=0x0C; K_NUM_UNPACK_STREAM=0x0D
K_EMPTY_STREAM=0x0E; K_NAME=0x11; K_ENCODED_HEADER=0x17
SIG=b"7z\xbc\xaf'\x1c"
STREAM_THRESHOLD=64*1024*1024
DEFAULT_CHUNK=8*1024*1024

class Reader:
    def __init__(self,data:bytes): self.f=io.BytesIO(data)
    def tell(self): return self.f.tell()
    def read(self,n:int):
        b=self.f.read(n)
        if len(b)!=n: raise EOFError((n,len(b),self.tell()))
        return b
    def u8(self): return self.read(1)[0]
    def u32(self): return struct.unpack('<I',self.read(4))[0]
    def uint(self):
        first=self.u8(); mask=0x80; value=0
        for i in range(8):
            if (first & mask)==0: return value | ((first & (mask-1)) << (8*i))
            value |= self.u8() << (8*i); mask >>= 1
        return value

def bool_vector(r:Reader,n:int):
    out=[]; mask=0; byte=0
    for _ in range(n):
        if mask==0: byte=r.u8(); mask=0x80
        out.append(bool(byte & mask)); mask >>= 1
    return out

def digest(r:Reader,n:int):
    all_defined=r.u8(); defined=[True]*n if all_defined else bool_vector(r,n)
    return defined,[r.u32() if d else None for d in defined]

def parse_folder(r:Reader):
    nc=r.uint(); coders=[]; total_in=total_out=0
    for _ in range(nc):
        main=r.u8(); method=r.read(main & 0x0f); nin=nout=1
        if main & 0x10: nin=r.uint(); nout=r.uint()
        props=b''
        if main & 0x20: props=r.read(r.uint())
        if main & 0x80: raise NotImplementedError('alternative coder methods')
        coders.append({'method':method,'nin':nin,'nout':nout,'props':props})
        total_in+=nin; total_out+=nout
    binds=[(r.uint(),r.uint()) for _ in range(total_out-1)]
    npacked=total_in-len(binds)
    if npacked==1:
        bound={x for x,_ in binds}; packed=[next(i for i in range(total_in) if i not in bound)]
    else: packed=[r.uint() for _ in range(npacked)]
    return {'coders':coders,'bind_pairs':binds,'pack_streams':packed,'total_in':total_in,'total_out':total_out}

def parse_streams(r:Reader):
    res={'pack_pos':0,'pack_sizes':[],'pack_crcs':[],'folders':[],'unpack_sizes':[],'folder_crcs':[],'num_substreams':[],'substream_sizes':[]}
    nid=r.u8()
    if nid==K_PACK_INFO:
        res['pack_pos']=r.uint(); count=r.uint(); nid=r.u8()
        if nid==K_SIZE: res['pack_sizes']=[r.uint() for _ in range(count)]; nid=r.u8()
        if nid==K_CRC: _,res['pack_crcs']=digest(r,count); nid=r.u8()
        if nid!=K_END: raise ValueError(('pack end',hex(nid),r.tell()))
        nid=r.u8()
    if nid==K_UNPACK_INFO:
        if r.u8()!=K_FOLDER: raise ValueError('missing folder')
        nf=r.uint()
        if r.u8(): raise NotImplementedError('external folders')
        res['folders']=[parse_folder(r) for _ in range(nf)]
        if r.u8()!=K_CODERS_UNPACK_SIZE: raise ValueError('missing coder unpack sizes')
        res['unpack_sizes']=[[r.uint() for _ in range(f['total_out'])] for f in res['folders']]
        nid2=r.u8()
        if nid2==K_CRC: _,res['folder_crcs']=digest(r,nf); nid2=r.u8()
        if nid2!=K_END: raise ValueError(('unpack end',hex(nid2),r.tell()))
        nid=r.u8()
    if nid==K_SUBSTREAMS_INFO:
        nf=len(res['folders']); nums=[1]*nf; sizes=[]; nid2=r.u8()
        if nid2==K_NUM_UNPACK_STREAM: nums=[r.uint() for _ in range(nf)]; nid2=r.u8()
        if nid2==K_SIZE:
            for i,num in enumerate(nums):
                total=res['unpack_sizes'][i][-1] if res['unpack_sizes'][i] else 0
                arr=[]; used=0
                for _ in range(max(0,num-1)):
                    x=r.uint(); arr.append(x); used+=x
                if num: arr.append(total-used)
                sizes.append(arr)
            nid2=r.u8()
        else: sizes=[[res['unpack_sizes'][i][-1]] if num else [] for i,num in enumerate(nums)]
        if nid2==K_CRC:
            count=sum(num for i,num in enumerate(nums) if not (num==1 and i<len(res['folder_crcs']) and res['folder_crcs'][i] is not None))
            digest(r,count); nid2=r.u8()
        if nid2!=K_END: raise ValueError(('substreams end',hex(nid2),r.tell()))
        res['num_substreams']=nums; res['substream_sizes']=sizes; nid=r.u8()
    if nid!=K_END: raise ValueError(('streams end',hex(nid),r.tell()))
    return res

def lzma2_dict(prop:int):
    if prop>40: raise ValueError(prop)
    if prop==40: return 0xffffffff
    return (2 | (prop & 1)) << (prop//2 + 11)

def coder_filter(f:dict[str,Any]):
    if len(f['coders'])!=1 or f['total_in']!=1 or f['total_out']!=1: raise NotImplementedError('multi-coder folder')
    c=f['coders'][0]; method=c['method']; props=c['props']
    if method==b'\x21': return method,{'id':lzma.FILTER_LZMA2,'dict_size':lzma2_dict(props[0])}
    if method==b'\x03\x01\x01':
        p=props[0]; lc=p%9; rem=p//9; lp=rem%5; pb=rem//5
        return method,{'id':lzma.FILTER_LZMA1,'dict_size':struct.unpack('<I',props[1:5])[0],'lc':lc,'lp':lp,'pb':pb}
    if method==b'\x00': return method,None
    raise NotImplementedError(('coder',method.hex(),props.hex()))

def decode_folder(data:bytes,f:dict[str,Any],expected:int):
    method,filt=coder_filter(f)
    if method==b'\x00': return data[:expected]
    return lzma.LZMADecompressor(format=lzma.FORMAT_RAW,filters=[filt]).decompress(data,max_length=expected if expected else -1)

def stream_decode(src,offset:int,packed_size:int,f:dict[str,Any],expected:int,dest:Path,chunk_size:int=DEFAULT_CHUNK,expected_crc:int|None=None):
    method,filt=coder_filter(f); dest.parent.mkdir(parents=True,exist_ok=True)
    remaining=packed_size; written=0; crc=0
    dec=None if method==b'\x00' else lzma.LZMADecompressor(format=lzma.FORMAT_RAW,filters=[filt])
    src.seek(offset)
    with dest.open('wb') as out:
        while remaining:
            block=src.read(min(chunk_size,remaining))
            if not block: raise EOFError(('packed stream truncated',remaining))
            remaining-=len(block)
            raw=block if dec is None else dec.decompress(block)
            if raw:
                out.write(raw); written+=len(raw); crc=zlib.crc32(raw,crc)
            if written>expected: raise ValueError(('decoded-size overflow',expected,written))
        if dec is not None:
            while not dec.eof and not dec.needs_input:
                raw=dec.decompress(b'')
                if not raw: break
                out.write(raw); written+=len(raw); crc=zlib.crc32(raw,crc)
    crc &= 0xffffffff
    if written!=expected:
        dest.unlink(missing_ok=True); raise ValueError(('decoded-size mismatch',expected,written))
    if dec is not None and not dec.eof:
        dest.unlink(missing_ok=True); raise ValueError('compressed stream ended before LZMA end marker')
    if expected_crc is not None and crc!=expected_crc:
        dest.unlink(missing_ok=True); raise ValueError(('folder CRC mismatch',hex(expected_crc),hex(crc)))
    return {'unpacked_size':written,'crc32':f'{crc:08x}','chunk_size':chunk_size}

def read_signature(path:Path):
    with path.open('rb') as f: h=f.read(32)
    if h[:6]!=SIG: raise ValueError(('bad signature',h[:8].hex()))
    crc=struct.unpack('<I',h[8:12])[0]; start=h[12:32]
    if (zlib.crc32(start)&0xffffffff)!=crc: raise ValueError('start-header CRC mismatch')
    off,size,ncrc=struct.unpack('<QQI',start)
    return {'version':list(h[6:8]),'next_offset':off,'next_size':size,'next_crc':ncrc}

def decoded_header(path:Path):
    sig=read_signature(path)
    with path.open('rb') as f: f.seek(32+sig['next_offset']); data=f.read(sig['next_size'])
    if (zlib.crc32(data)&0xffffffff)!=sig['next_crc']: raise ValueError('next-header CRC mismatch')
    r=Reader(data); nid=r.u8()
    if nid==K_HEADER: return data,sig,None
    if nid!=K_ENCODED_HEADER: raise ValueError(('unexpected next-header NID',hex(nid)))
    enc=parse_streams(r); off=32+enc['pack_pos']; size=enc['pack_sizes'][0]
    with path.open('rb') as f: f.seek(off); packed=f.read(size)
    expected=enc['unpack_sizes'][0][-1]
    return decode_folder(packed,enc['folders'][0],expected),sig,enc

def parse_files_header(data:bytes):
    r=Reader(data)
    if r.u8()!=K_HEADER: raise ValueError('decoded header is not kHeader')
    main=None; names=[]; nfiles=None; empty_stream=None; nid=r.u8()
    while nid!=K_END:
        if nid==K_ARCHIVE_PROPERTIES:
            while True:
                p=r.u8()
                if p==K_END: break
                r.read(r.uint())
        elif nid==K_ADDITIONAL_STREAMS: parse_streams(r)
        elif nid==K_MAIN_STREAMS: main=parse_streams(r)
        elif nid==K_FILES_INFO:
            nfiles=r.uint(); props={}
            while True:
                p=r.u8()
                if p==K_END: break
                props[p]=r.read(r.uint())
            if K_NAME in props:
                rr=Reader(props[K_NAME])
                if rr.u8(): raise NotImplementedError('external names')
                names=rr.read(len(props[K_NAME])-1).decode('utf-16le').split('\x00')
                if names and names[-1]=='': names.pop()
            if K_EMPTY_STREAM in props: empty_stream=bool_vector(Reader(props[K_EMPTY_STREAM]),nfiles)
        else: raise ValueError(('unknown header NID',hex(nid),r.tell()))
        nid=r.u8()
    return {'nfiles':nfiles,'names':names,'empty_stream':empty_stream,'main':main}

def pack_offsets(main):
    cur=32+main['pack_pos']; out=[]
    for size in main['pack_sizes']: out.append(cur); cur+=size
    return out

def file_stream_map(parsed):
    names=parsed['names']; empty=parsed.get('empty_stream')
    if empty is None:
        if len(names)==len(parsed['main']['folders']): return list(range(len(names)))
        if len(names)-len(parsed['main']['folders'])==1: return [None]+list(range(len(parsed['main']['folders'])))
        raise ValueError('cannot infer file-to-stream mapping')
    out=[]; stream=0
    for is_empty in empty:
        if is_empty: out.append(None)
        else: out.append(stream); stream+=1
    return out

def inspect(path:Path):
    header,sig,enc=decoded_header(path); parsed=parse_files_header(header); main=parsed['main']
    result={'signature':sig,'decoded_header_bytes':len(header),'encoded_header':enc is not None,'file_count':parsed['nfiles'],'files':parsed['names']}
    if main:
        result['streams']={'pack_pos':main['pack_pos'],'pack_count':len(main['pack_sizes']),'folder_count':len(main['folders']),'pack_sizes':main['pack_sizes'],'unpack_sizes':[x[-1] if x else 0 for x in main['unpack_sizes']],'pack_offsets':pack_offsets(main),'methods':[f['coders'][0]['method'].hex() if len(f['coders'])==1 else 'complex' for f in main['folders']]}
    return result

def extract_file(path:Path,index:int,dest:Path,chunk_size:int=DEFAULT_CHUNK):
    header,_,_=decoded_header(path); parsed=parse_files_header(header); main=parsed['main']
    mapping=file_stream_map(parsed); stream=mapping[index]
    if stream is None: raise IsADirectoryError(parsed['names'][index])
    if main['num_substreams'] and main['num_substreams'][stream]!=1: raise NotImplementedError('multiple substreams per folder')
    offsets=pack_offsets(main); psize=main['pack_sizes'][stream]; expected=main['unpack_sizes'][stream][-1]
    folder_crc=main['folder_crcs'][stream] if stream<len(main['folder_crcs']) else None
    if psize>=STREAM_THRESHOLD or expected>=STREAM_THRESHOLD:
        with path.open('rb') as f: stats=stream_decode(f,offsets[stream],psize,main['folders'][stream],expected,dest,chunk_size,folder_crc)
        mode='streaming'
    else:
        with path.open('rb') as f: f.seek(offsets[stream]); packed=f.read(psize)
        raw=decode_folder(packed,main['folders'][stream],expected)
        if len(raw)!=expected: raise ValueError(('decoded-size mismatch',expected,len(raw)))
        if folder_crc is not None and (zlib.crc32(raw)&0xffffffff)!=folder_crc: raise ValueError('folder CRC mismatch')
        dest.parent.mkdir(parents=True,exist_ok=True); dest.write_bytes(raw)
        stats={'unpacked_size':len(raw),'crc32':f'{zlib.crc32(raw)&0xffffffff:08x}'}; mode='memory'
    return {'file_index':index,'file_name':parsed['names'][index],'stream':stream,'pack_offset':offsets[stream],'pack_size':psize,'unpacked_size':expected,'output':str(dest),'mode':mode,**stats}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('archive',type=Path)
    sub=parser.add_subparsers(dest='command',required=True)
    ins=sub.add_parser('inspect'); ins.add_argument('--output',type=Path)
    ext=sub.add_parser('extract'); group=ext.add_mutually_exclusive_group(required=True); group.add_argument('--index',type=int); group.add_argument('--name'); ext.add_argument('--output',type=Path,required=True); ext.add_argument('--chunk-mib',type=int,default=8)
    args=parser.parse_args()
    if args.command=='inspect':
        result=inspect(args.archive); text=json.dumps(result,indent=2)+"\n"
        if args.output: args.output.write_text(text,encoding='utf-8')
        print(text,end=''); return 0
    header,_,_=decoded_header(args.archive); parsed=parse_files_header(header); idx=args.index
    if args.name is not None:
        try: idx=parsed['names'].index(args.name)
        except ValueError: raise SystemExit(f'archive member not found: {args.name}')
    if args.chunk_mib<1: raise SystemExit('--chunk-mib must be >= 1')
    print(json.dumps(extract_file(args.archive,idx,args.output,args.chunk_mib*1024*1024),indent=2)); return 0

if __name__=='__main__': raise SystemExit(main())
