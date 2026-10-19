#!/usr/bin/env python3
import json
import tempfile
from pathlib import Path

from build_hydrology_truth_sidecar import build_sidecar, load_evidence, load_registered_segments


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "hydrology"
        (root / "tiles").mkdir(parents=True)
        key_a = "1:2:w10:1.000000:2.000000:3.000000:4.000000"
        key_b = "1:2:w11:5.000000:6.000000:7.000000:8.000000"
        record_format = ["ax", "ay", "az", "bx", "by", "bz", "source_way", "segment_key"]
        (root / "tiles/tile_1_2.json").write_text(json.dumps({
            "tile": [1, 2],
            "segments": [[1, 10, 2, 3, 9, 4, "w10", key_a], [5, 8, 6, 7, 7, 8, "w11", key_b]],
        }))
        (root / "manifest.json").write_text(json.dumps({
            "record_format": record_format,
            "tiles": [{"x": 1, "z": 2, "file": "tiles/tile_1_2.json", "segments": 2}],
        }))
        segments = load_registered_segments(root)
        assert [s["segment_key"] for s in segments] == [key_a, key_b]

        # Canonical WRA payload: authority is recomputed from the exact mapped
        # unit plus valid line-overlap provenance, not trusted from JSON flags.
        evidence = Path(tmp) / "evidence.json"
        evidence.write_text(json.dumps({"evidence": [{
            "segment_key": key_a,
            "source": "wra",
            "source_feature_id": "lower-morass-01",
            "layer": "wmu",
            "mapped_unit": "Black River Lower Morass",
            "intersection_fraction": 0.75,
            "geometry_valid": True,
            "geometry_repaired": False,
            "segment_length_m": 100.0,
            "intersection_length_m": 75.0,
            "join_topology": "line_overlap",
        }]}))
        loaded = load_evidence(evidence)[key_a][0]
        assert loaded.authorizes_morphology
        assert loaded.evidence_token == "wra:black_river_lower_morass_wmu"
        assert loaded.topology_consistent

        output = Path(tmp) / "truth-sidecar.json"
        pack = build_sidecar(root, output, evidence)
        assert output.is_file()
        assert len(pack["segments"]) == 2
        assert pack["segments"][0]["segment_key"] == key_a
        assert pack["segments"][0]["decision"]["status"] == "approved"
        assert pack["segments"][0]["decision"]["morphology_family"] == "lowland_wetland"
        assert pack["segments"][1]["decision"]["status"] == "blocked"
        assert pack["metrics"]["segments_approved"] == 1
        assert pack["metrics"]["segments_blocked_no_evidence"] == 1

        # A producer cannot spoof authority/token when the mapped unit is not an
        # approved exact contract.
        spoof = Path(tmp) / "spoof.json"
        spoof.write_text(json.dumps({"evidence": [{
            "segment_key": key_a,
            "source": "wra",
            "source_feature_id": "unknown-01",
            "layer": "wmu",
            "mapped_unit": "Unknown Jamaica Unit",
            "intersection_fraction": 1.0,
            "evidence_token": "wra:black_river_lower_morass_wmu",
            "authorizes_morphology": True,
        }]}))
        spoofed = load_evidence(spoof)[key_a][0]
        assert not spoofed.authorizes_morphology
        assert spoofed.evidence_token == ""

        # Repaired source geometry stays audit-only even with an exact unit.
        repaired = Path(tmp) / "repaired.json"
        repaired.write_text(json.dumps({"evidence": [{
            "segment_key": key_a,
            "source": "wra",
            "source_feature_id": "lower-morass-repaired",
            "layer": "wmu",
            "mapped_unit": "Black River Lower Morass",
            "intersection_fraction": 0.5,
            "geometry_valid": True,
            "geometry_repaired": True,
        }]}))
        assert not load_evidence(repaired)[key_a][0].authorizes_morphology

        # A length/fraction topology contradiction also stays non-destructive.
        inconsistent = Path(tmp) / "inconsistent.json"
        inconsistent.write_text(json.dumps({"evidence": [{
            "segment_key": key_a,
            "source": "wra",
            "source_feature_id": "lower-morass-bad-topology",
            "layer": "wmu",
            "mapped_unit": "Black River Lower Morass",
            "intersection_fraction": 0.8,
            "segment_length_m": 100.0,
            "intersection_length_m": 2.0,
            "join_topology": "line_overlap",
        }]}))
        inconsistent_record = load_evidence(inconsistent)[key_a][0]
        assert not inconsistent_record.topology_consistent
        assert not inconsistent_record.authorizes_morphology

        bad = Path(tmp) / "bad"
        bad.mkdir()
        (bad / "manifest.json").write_text(json.dumps({"record_format": ["source_way"], "tiles": []}))
        try:
            load_registered_segments(bad)
        except ValueError:
            pass
        else:
            raise AssertionError("compiler output without segment_key must fail closed")
    print("HYDROLOGY_TRUTH_SIDECAR_PASS")


if __name__ == "__main__":
    main()
