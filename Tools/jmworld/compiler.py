"""Deterministic synthetic compiler; synthetic evidence is never real Jamaica data."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import uuid

VERSION = "0.1.0"
SCHEMA = "0.1"
SIZES = {"M8": 8000, "W1": 1000, "D250": 250, "D125": 125}
PARISHES = ["Kingston", "St. Andrew", "St. Catherine", "Clarendon", "Manchester",
            "St. Elizabeth", "Westmoreland", "Hanover", "St. James", "Trelawny",
            "St. Ann", "St. Mary", "Portland", "St. Thomas"]

class ContractError(ValueError):
    pass

def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")

def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()

def parse_cell(text):
    match = re.fullmatch(r"JM:(M8|W1|D250|D125):(-?(?:0|[1-9][0-9]*)):(-?(?:0|[1-9][0-9]*))", text)
    if not match:
        raise ContractError("GEO_CELL_ID")
    level, x, n = match[1], int(match[2]), int(match[3])
    if text != f"JM:{level}:{x}:{n}" or max(abs(x), abs(n)) > 2**52 - 1:
        raise ContractError("GEO_NONCANONICAL_CELL_ID")
    return level, x, n

def index(east, north, anchor_e=0, anchor_n=0, level="W1"):
    if level not in SIZES or not all(math.isfinite(x) for x in (east, north, anchor_e, anchor_n)):
        raise ContractError("GEO_COORDINATE")
    x, n = math.floor((east-anchor_e)/SIZES[level]), math.floor((north-anchor_n)/SIZES[level])
    result = f"JM:{level}:{x}:{n}"
    parse_cell(result)
    return result

def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def load_config(path):
    config = json.loads(Path(path).read_text())
    if config.get("evidence_class") != "SYNTHETIC_TEST_ONLY":
        raise ContractError("COMPILER_SYNTHETIC_ONLY")
    if config.get("schema_version") != SCHEMA or config.get("vertical_datum_id") != "SYNTHETIC_METRES":
        raise ContractError("GEO_DATUM_OR_SCHEMA")
    for key in ("anchor_e", "anchor_n", "seed", "road_width_m"):
        if not isinstance(config.get(key), (int, float)) or not math.isfinite(config[key]):
            raise ContractError("COMPILER_CONFIG:" + key)
    if config["road_width_m"] <= 0 or config["road_width_m"] > 100:
        raise ContractError("COMPILER_ROAD_WIDTH")
    return config

class SourceRegistry:
    """Local candidate registry, not the future authoritative PostGIS service."""
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.executescript("""
          PRAGMA foreign_keys=ON;
          CREATE TABLE IF NOT EXISTS source_versions (
            source_id TEXT NOT NULL, content_hash TEXT NOT NULL, metadata TEXT NOT NULL,
            PRIMARY KEY (source_id,content_hash));
          CREATE TABLE IF NOT EXISTS changesets (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, content_hash TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('CANDIDATE','VALIDATED','ACCEPTED')),
            FOREIGN KEY(source_id,content_hash) REFERENCES source_versions(source_id,content_hash));
        """)
    def add(self, manifest_path):
        path = Path(manifest_path); item = json.loads(path.read_text())
        required = ("source_id", "author", "source_uri", "source_date", "license", "rights_status", "horizontal_crs", "vertical_datum_id", "evidence_class", "input_file")
        if any(not isinstance(item.get(k), str) or not item[k].strip() for k in required):
            raise ContractError("DB_SOURCE_METADATA_MISSING")
        raw_path = (path.parent/item["input_file"]).resolve()
        item["content_hash"] = digest(raw_path.read_bytes())
        if item["rights_status"] not in ("APPROVED", "REFERENCE_ONLY", "UNRESOLVED"):
            raise ContractError("DB_RIGHTS_STATUS")
        value = canonical(item).decode()
        existing = self.db.execute("SELECT metadata FROM source_versions WHERE source_id=? AND content_hash=?", (item["source_id"], item["content_hash"])).fetchone()
        if existing and existing[0] != value:
            raise ContractError("DB_SOURCE_VERSION_IMMUTABLE")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO source_versions VALUES (?,?,?)", (item["source_id"], item["content_hash"], value))
        return item
    def candidate(self, source_id, content_hash):
        row = self.db.execute("SELECT metadata FROM source_versions WHERE source_id=? AND content_hash=?", (source_id, content_hash)).fetchone()
        if not row: raise ContractError("DB_SOURCE_NOT_FOUND")
        item = json.loads(row[0])
        if item["rights_status"] != "APPROVED": raise ContractError("DB_SOURCE_NOT_APPROVED")
        cid = digest(canonical([source_id, content_hash]))
        with self.db: self.db.execute("INSERT OR IGNORE INTO changesets VALUES (?,?,?,'CANDIDATE')", (cid, source_id, content_hash))
        return {"changeset_id":cid,"status":"CANDIDATE"}
    def list(self):
        return [json.loads(x[0]) for x in self.db.execute("SELECT metadata FROM source_versions ORDER BY source_id,content_hash")]
    def close(self): self.db.close()

def height(east, north, seed):
    # Global integer metre samples make independently compiled cell seams identical.
    # This is deliberately fabricated test terrain, never accepted national geography.
    return round(8 + 3 * math.sin(east / 1500 + seed) * math.cos(north / 1700), 6)

class Compiler:
    def __init__(self, config, output, target="android-mid"):
        if target not in ("android-low", "android-mid", "android-high", "ios-high", "desktop-test"):
            raise ContractError("COMPILER_TARGET")
        self.config, self.output, self.target = config, Path(output), target
        self.code_hash = digest(Path(__file__).read_bytes())
        self.hits = self.built = self.repaired = 0

    def artifact(self, payload, cell, layer, source_fragment, dependencies):
        build_key = digest(canonical({"schema":SCHEMA, "source_state_hash":digest(canonical(source_fragment)),
            "compiler_code":self.code_hash,"compiler_version":VERSION,"asset_library":"synthetic-primitives-v1",
            "layer_compiler":layer+":1", "target":self.target,"options":{"sample_spacing_m":62.5},"dependencies":dependencies}))
        payload = dict(payload, build_key=build_key)
        data = canonical(payload); content_hash = digest(data)
        relative = "objects/"+content_hash.split(":")[1]+".json"
        path = self.output/relative
        if path.exists() and path.read_bytes() == data: self.hits += 1
        else:
            if path.exists():
                path.replace(path.with_suffix(".corrupt-"+str(uuid.uuid4()))); self.repaired += 1
            atomic_write(path, data); self.built += 1
        return {"artifact_id":content_hash,"kind":layer,"representation":"PROOF", "quality_min":"low","quality_max":"ultra",
            "uri":relative,"byte_size":len(data),"content_hash":content_hash,"compression":"none",
            "dependencies":dependencies,"required_for":["physics","visual"],"priority_bias":0,"fallback_artifact_id":"",
            "world_cell_id":cell,"source_state_hash":digest(canonical(source_fragment)),"compiler_version":VERSION,
            "target":self.target,"validation":"PASS","build_key":build_key}

    def cell(self, cell):
        level, x, n = parse_cell(cell)
        if level != "W1": raise ContractError("COMPILER_W1_REQUIRED")
        cfg = self.config; min_e = cfg["anchor_e"] + x*1000; min_n = cfg["anchor_n"] + n*1000
        sample_count = 17
        heights = [height(min_e+i*62.5, min_n+j*62.5, cfg["seed"]) for j in range(sample_count) for i in range(sample_count)]
        terrain_source = {k:cfg[k] for k in ("anchor_e","anchor_n","seed","vertical_datum_id")}
        terrain_source["cell"] = cell
        terrain = self.artifact({"payload_version":1,"cell_id":cell,"sample_count":sample_count,"spacing_m":62.5,"heights":heights},cell,"terrain.mesh",terrain_source,[])
        width = cfg.get("road_overrides", {}).get(cell, {}).get("width_m", cfg["road_width_m"])
        if not math.isfinite(width) or not 0 < width <= 100: raise ContractError("COMPILER_ROAD_WIDTH")
        points = [{"east":i*62.5,"north":500,"height":height(min_e+i*62.5,min_n+500,cfg["seed"])+0.08} for i in range(sample_count)]
        roads = self.artifact({"payload_version":1,"cell_id":cell,"width_m":width,"points":points},cell,"roads.mesh",{"cell":cell,"width_m":width},[terrain["artifact_id"]])
        return {"cell_id":cell,"bounds":{"min_e":min_e,"min_n":min_n,"max_e":min_e+1000,"max_n":min_n+1000},
            "revision":1,"layers":{"terrain":[terrain],"roads":[roads]}}

    def manifest(self, cells):
        items = [self.cell(c) for c in sorted(set(cells))]
        world_hash = digest(canonical(items))
        result = {"manifest_version":1,"world_id":"JM","world_version":"synthetic-"+world_hash[7:23],"schema_version":SCHEMA,
            "created_at":"2026-10-09T00:00:00Z","minimum_client_protocol":1,"artifact_base":"./","shared_packs":[],
            "evidence_class":"SYNTHETIC_TEST_ONLY","anchor_e":self.config["anchor_e"],"anchor_n":self.config["anchor_n"],
            "vertical_datum_id":"SYNTHETIC_METRES","cells":items}
        atomic_write(self.output/"manifest.json", canonical(result))
        atomic_write(self.output/"world_constants.json",canonical({"schema_version":SCHEMA,"horizontal_crs":"SYNTHETIC_PROJECTED_METRES",
            "vertical_datum_id":"SYNTHETIC_METRES","grid_anchor_e":self.config["anchor_e"],"grid_anchor_n":self.config["anchor_n"],
            "horizontal_scale":1,"vertical_scale":1,"canonical_jamaica_anchor_frozen":False}))
        return result

def references(manifest):
    return {r["artifact_id"]:r for cell in manifest["cells"] for group in cell["layers"].values() for r in group}

def verify(manifest_path):
    path = Path(manifest_path); manifest = json.loads(path.read_text())
    if manifest.get("manifest_version") != 1 or manifest.get("schema_version") != SCHEMA or manifest.get("minimum_client_protocol", 99) > 1:
        raise ContractError("ARTIFACT_VERSION")
    ids=set(); refs=references(manifest)
    for cell in manifest["cells"]:
        parse_cell(cell["cell_id"])
        if cell["cell_id"] in ids: raise ContractError("ARTIFACT_DUPLICATE_CELL")
        ids.add(cell["cell_id"])
    for key, ref in refs.items():
        if key != ref["content_hash"] or not re.fullmatch(r"sha256:[0-9a-f]{64}",key): raise ContractError("ARTIFACT_HASH_ID")
        local = (path.parent/ref["uri"]).resolve()
        if not local.is_relative_to(path.parent.resolve()): raise ContractError("ARTIFACT_PATH_ESCAPE")
        data = local.read_bytes()
        if len(data) != ref["byte_size"] or digest(data) != ref["content_hash"]: raise ContractError("ARTIFACT_INTEGRITY")
        if any(dep not in refs for dep in ref["dependencies"]): raise ContractError("ARTIFACT_DEPENDENCY_MISSING")
    visited, visiting=set(),set()
    def visit(key):
        if key in visiting: raise ContractError("ARTIFACT_DEPENDENCY_CYCLE")
        if key in visited: return
        visiting.add(key)
        for dep in refs[key]["dependencies"]: visit(dep)
        visiting.remove(key);visited.add(key)
    for key in refs: visit(key)
    return {"result":"PASS","cells":len(ids),"artifacts":len(refs)}

def diff(a, b):
    def layer_map(m): return {(c["cell_id"],k):[r["artifact_id"] for r in v] for c in m["cells"] for k,v in c["layers"].items()}
    old,new=layer_map(a),layer_map(b)
    return [{"cell":cell,"layer":layer,"before":old.get((cell,layer),[]),"after":new.get((cell,layer),[])}
            for cell,layer in sorted(old.keys()|new.keys()) if old.get((cell,layer)) != new.get((cell,layer))]

def main(argv=None):
    parser=argparse.ArgumentParser(prog="jmworld")
    parser.add_argument("--json",action="store_true"); parser.add_argument("--run-id",default=None)
    sub=parser.add_subparsers(dest="command",required=True)
    compile_p=sub.add_parser("compile"); cp=compile_p.add_subparsers(dest="kind",required=True)
    for kind in ("synthetic","cell"):
        p=cp.add_parser(kind)
        if kind=="cell":p.add_argument("cell")
        else:
            p.add_argument("--size",type=int,default=12);p.add_argument("--minimum",type=int,default=-4)
        p.add_argument("--config",default="World/Fixtures/synthetic_world.json")
        p.add_argument("--output",default="Assets/StreamingAssets/Yardman")
        p.add_argument("--target",default="android-mid")
    p=sub.add_parser("validate");p.add_argument("manifest")
    p=sub.add_parser("diff");p.add_argument("before");p.add_argument("after")
    p=sub.add_parser("index");p.add_argument("east",type=float);p.add_argument("north",type=float)
    p=sub.add_parser("coverage");p.add_argument("manifest")
    p=sub.add_parser("source");sp=p.add_subparsers(dest="operation",required=True)
    for op in ("add","list","candidate"):
        q=sp.add_parser(op);q.add_argument("--registry",default="world-registry/sources.sqlite")
        if op=="add":q.add_argument("--manifest",required=True)
        if op=="candidate":q.add_argument("source_id");q.add_argument("content_hash")
    args=parser.parse_args(argv);run_id=args.run_id or str(uuid.uuid4())
    try:
        if args.command=="compile":
            cfg=load_config(args.config);compiler=Compiler(cfg,args.output,args.target)
            if args.kind=="synthetic":
                if not 1<=args.size<=128:raise ContractError("COMPILER_GRID_SIZE")
                cells=[f"JM:W1:{x}:{n}" for x in range(args.minimum,args.minimum+args.size) for n in range(args.minimum,args.minimum+args.size)]
            else:cells=[args.cell]
            m=compiler.manifest(cells); result=dict(verify(Path(args.output)/"manifest.json"),world_version=m["world_version"],built=compiler.built,cache_hits=compiler.hits,repaired=compiler.repaired)
        elif args.command=="validate":result=verify(args.manifest)
        elif args.command=="index":result={"cell_id":index(args.east,args.north)}
        elif args.command=="diff":result={"changes":diff(json.loads(Path(args.before).read_text()),json.loads(Path(args.after).read_text()))}
        elif args.command=="coverage":
            m=json.loads(Path(args.manifest).read_text());result={"evidence_class":m["evidence_class"],"synthetic_cells":len(m["cells"]),"parishes":[{"name":p,"accepted_geographic_cells":0,"status":"NOT_INGESTED"} for p in PARISHES]}
        else:
            registry=SourceRegistry(args.registry)
            try:
                if args.operation=="add":result=registry.add(args.manifest)
                elif args.operation=="candidate":result=registry.candidate(args.source_id,args.content_hash)
                else:result={"sources":registry.list()}
            finally:registry.close()
        print(json.dumps({"run_id":run_id,"ok":True,"result":result},sort_keys=True));return 0
    except (ContractError,ValueError,KeyError) as exc:
        print(json.dumps({"run_id":run_id,"ok":False,"error":str(exc)}));return 2
    except OSError as exc:
        print(json.dumps({"run_id":run_id,"ok":False,"error":"COMPILER_IO","detail":type(exc).__name__}));return 3

if __name__=="__main__":raise SystemExit(main())
