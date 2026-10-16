import copy
import json
import math
from pathlib import Path
import tempfile
import unittest
from jmworld.compiler import Compiler, ContractError, SourceRegistry, canonical, diff, digest, index, load_config, parse_cell, verify

ROOT=Path(__file__).resolve().parents[2]

class CompilerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.out=Path(self.tmp.name)
        self.config=load_config(ROOT/'World/Fixtures/synthetic_world.json')
    def tearDown(self):self.tmp.cleanup()
    def compile(self,cells=None,config=None):
        compiler=Compiler(config or self.config,self.out)
        manifest=compiler.manifest(cells or ['JM:W1:0:0','JM:W1:1:0','JM:W1:0:1'])
        return compiler,manifest
    def test_half_open_boundaries(self):
        self.assertEqual(index(0,0),'JM:W1:0:0')
        self.assertEqual(index(1000,1000),'JM:W1:1:1')
        self.assertEqual(index(-0.0001,-1000),'JM:W1:-1:-1')
        self.assertEqual(index(999.999,0),'JM:W1:0:0')
    def test_nonfinite_coordinates(self):
        for value in [math.nan,math.inf,-math.inf]:
            with self.assertRaises(ContractError):index(value,0)
    def test_canonical_ids(self):
        for text in ['JM:W1:01:2','JM:1000:0:0','JM:W1:-0:0','../x','JM:W1:0:0 ']:
            with self.assertRaises(ContractError):parse_cell(text)
    def test_reproducible_manifest_and_cache(self):
        c,a=self.compile();original=(self.out/'manifest.json').read_bytes()
        d,b=self.compile()
        self.assertEqual(c.built,6);self.assertEqual(d.built,0);self.assertEqual(d.hits,6)
        self.assertEqual(a,b);self.assertEqual(original,(self.out/'manifest.json').read_bytes())
    def test_order_does_not_change_output(self):
        _,a=self.compile(['JM:W1:0:0','JM:W1:1:0'])
        _,b=self.compile(['JM:W1:1:0','JM:W1:0:0','JM:W1:0:0'])
        self.assertEqual(a,b)
    def test_shared_edges_exactly_equal(self):
        _,m=self.compile()
        data={c['cell_id']:json.loads((self.out/c['layers']['terrain'][0]['uri']).read_text()) for c in m['cells']}
        a=data['JM:W1:0:0']['heights'];east=data['JM:W1:1:0']['heights'];north=data['JM:W1:0:1']['heights']
        self.assertEqual(a[16::17],east[0::17]);self.assertEqual(a[-17:],north[:17])
    def test_single_road_edit_has_one_artifact_fanout(self):
        _,a=self.compile();cfg=copy.deepcopy(self.config);cfg['road_overrides']={'JM:W1:0:0':{'width_m':11}}
        c,b=self.compile(config=cfg);changes=diff(a,b)
        self.assertEqual(c.built,1);self.assertEqual(c.hits,5)
        self.assertEqual([(r['cell'],r['layer']) for r in changes],[('JM:W1:0:0','roads')])
    def test_terrain_change_invalidates_dependent_roads(self):
        _,a=self.compile();cfg=dict(self.config,seed=42);c,b=self.compile(config=cfg)
        self.assertEqual(c.built,6);self.assertEqual(len(diff(a,b)),6)
    def test_target_participates_in_build_key(self):
        _,a=self.compile();b=Compiler(self.config,self.out/'other','ios-high').manifest(['JM:W1:0:0'])
        self.assertNotEqual(a['cells'][0]['layers']['terrain'][0]['build_key'],b['cells'][0]['layers']['terrain'][0]['build_key'])
    def test_valid_manifest_verifies(self):
        self.compile();self.assertEqual(verify(self.out/'manifest.json')['artifacts'],6)
    def test_corrupt_bytes_rejected_then_repaired(self):
        _,m=self.compile();p=self.out/m['cells'][0]['layers']['terrain'][0]['uri'];p.write_bytes(b'broken')
        with self.assertRaises(ContractError):verify(self.out/'manifest.json')
        c,_=self.compile();self.assertEqual(c.repaired,1);self.assertEqual(verify(self.out/'manifest.json')['result'],'PASS')
    def test_missing_dependency_rejected(self):
        _,m=self.compile();m['cells'][0]['layers']['roads'][0]['dependencies']=['sha256:'+'0'*64]
        (self.out/'manifest.json').write_bytes(canonical(m))
        with self.assertRaisesRegex(ContractError,'DEPENDENCY_MISSING'):verify(self.out/'manifest.json')
    def test_dependency_cycle_rejected(self):
        _,m=self.compile();r=m['cells'][0]['layers']['terrain'][0];r['dependencies']=[r['artifact_id']]
        (self.out/'manifest.json').write_bytes(canonical(m))
        with self.assertRaisesRegex(ContractError,'DEPENDENCY_CYCLE'):verify(self.out/'manifest.json')
    def test_path_escape_rejected(self):
        _,m=self.compile();m['cells'][0]['layers']['terrain'][0]['uri']='../outside.json'
        (self.out/'manifest.json').write_bytes(canonical(m))
        with self.assertRaisesRegex(ContractError,'PATH_ESCAPE'):verify(self.out/'manifest.json')
    def test_unknown_manifest_version_rejected(self):
        _,m=self.compile();m['minimum_client_protocol']=9;(self.out/'manifest.json').write_bytes(canonical(m))
        with self.assertRaisesRegex(ContractError,'VERSION'):verify(self.out/'manifest.json')
    def test_source_metadata_required(self):
        p=self.out/'source.json';p.write_text('{}');r=SourceRegistry(self.out/'sources.sqlite')
        try:
            with self.assertRaisesRegex(ContractError,'METADATA_MISSING'):r.add(p)
        finally:r.close()
    def test_source_registration_and_candidate_do_not_accept(self):
        p=self.out/'source.json';fixture=json.loads((ROOT/'World/Fixtures/source_manifest.json').read_text())
        fixture['input_file']='raw.json';(self.out/'raw.json').write_bytes(canonical(self.config));p.write_bytes(canonical(fixture))
        r=SourceRegistry(self.out/'sources.sqlite')
        try:
            a=r.add(p);b=r.add(p);self.assertEqual(a,b);self.assertEqual(len(r.list()),1)
            self.assertEqual(r.candidate(a['source_id'],a['content_hash'])['status'],'CANDIDATE')
            fixture['license']='silently changed';p.write_bytes(canonical(fixture))
            with self.assertRaisesRegex(ContractError,'IMMUTABLE'):r.add(p)
        finally:r.close()
    def test_nonapproved_source_cannot_enter_candidate(self):
        p=self.out/'source.json';item=json.loads((ROOT/'World/Fixtures/source_manifest.json').read_text())
        item.update(input_file='raw.json',rights_status='REFERENCE_ONLY');(self.out/'raw.json').write_text('{}');p.write_bytes(canonical(item))
        r=SourceRegistry(self.out/'sources.sqlite')
        try:
            a=r.add(p)
            with self.assertRaisesRegex(ContractError,'NOT_APPROVED'):r.candidate(a['source_id'],a['content_hash'])
        finally:r.close()

if __name__=='__main__':unittest.main()
