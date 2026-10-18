#!/usr/bin/env python3
"""Validate recovered fleet selector identity bindings.

This gate prevents dedicated recovered selectors from silently sharing hero media,
losing source provenance, or falling back to an unrelated named vehicle asset.
"""
from __future__ import annotations
import argparse, hashlib, json, re
from pathlib import Path

SHA256_RE=re.compile(r'^[0-9a-f]{64}$')

def validate(path:Path)->dict:
 data=json.loads(path.read_text())
 if int(data.get('format_version',0))!=1:raise ValueError('unsupported format_version')
 vehicles=data.get('vehicles',[])
 if not isinstance(vehicles,list):raise ValueError('vehicles must be a list')
 ids=set();heroes={};fail=[]
 for entry in vehicles:
  if not isinstance(entry,dict):fail.append('non-dictionary vehicle entry');continue
  vid=str(entry.get('id','')).strip();hero=str(entry.get('hero_scene','')).strip();identity=str(entry.get('source_identity','')).strip();unit=str(entry.get('source_unit','')).strip();sha=str(entry.get('source_sha256','')).strip()
  if not vid:fail.append('missing id');continue
  if vid in ids:fail.append(f'{vid}: duplicate selector id')
  ids.add(vid)
  if not identity:fail.append(f'{vid}: missing source_identity')
  if not unit:fail.append(f'{vid}: missing source_unit')
  if not SHA256_RE.fullmatch(sha):fail.append(f'{vid}: invalid source_sha256')
  if not hero:fail.append(f'{vid}: missing dedicated hero_scene')
  elif hero in heroes:fail.append(f'{vid}: hero_scene aliases {heroes[hero]} via {hero}')
  else:heroes[hero]=vid
  if hero and hero!='road_car.glb' and Path(hero).suffix.lower()!='.glb':fail.append(f'{vid}: hero_scene is not GLB')
  dims=entry.get('dimensions_m',[])
  if not isinstance(dims,list) or len(dims)!=3 or any(float(v)<=0 for v in dims):fail.append(f'{vid}: invalid dimensions_m')
  for key in ('wheelbase_m','track_width_m','wheel_radius_m'):
   try:value=float(entry.get(key,0.0))
   except (TypeError,ValueError):value=0.0
   if value<=0.0:fail.append(f'{vid}: invalid {key}')
 result={'format_version':1,'source':path.name,'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'vehicle_count':len(vehicles),'selector_ids':sorted(ids),'hero_scene_count':len(heroes),'accepted':not fail,'failures':fail}
 if fail:raise ValueError('; '.join(fail))
 return result

def main()->int:
 p=argparse.ArgumentParser();p.add_argument('registry',type=Path);p.add_argument('--output',type=Path);a=p.parse_args();result=validate(a.registry)
 if a.output:a.output.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
 print(json.dumps(result,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
