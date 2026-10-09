using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using Jamaica.World;
using Jamaica.Streaming;

namespace Jamaica.Content
{
    [Serializable] public sealed class WorldManifest
    {
        public int manifest_version, minimum_client_protocol;
        public string world_id, world_version, schema_version, evidence_class, vertical_datum_id;
        public double anchor_e, anchor_n;
        public CellEntry[] cells;
    }
    [Serializable] public sealed class CellEntry { public string cell_id; public CellBounds bounds; public int revision; public CellLayers layers; }
    [Serializable] public sealed class CellBounds { public double min_e, min_n, max_e, max_n; }
    [Serializable] public sealed class CellLayers { public ArtifactReference[] terrain, roads; }
    [Serializable] public sealed class ArtifactReference
    {
        public string artifact_id, content_hash, uri, kind, compression;
        public long byte_size;
        public string[] dependencies, required_for;
    }
    [Serializable] public sealed class TerrainPayload { public int payload_version, sample_count; public string cell_id; public float spacing_m; public float[] heights; }
    [Serializable] public sealed class RoadPoint { public float east, north, height; }
    [Serializable] public sealed class RoadPayload { public int payload_version; public string cell_id; public float width_m; public RoadPoint[] points; }
    public sealed class ContentCatalog
    {
        public readonly WorldManifest Manifest;
        public readonly Dictionary<CellId,CellEntry> Cells = new Dictionary<CellId,CellEntry>();
        public readonly Dictionary<StreamKey,ArtifactReference> Artifacts = new Dictionary<StreamKey,ArtifactReference>();
        public ContentCatalog(WorldManifest manifest)
        {
            if (manifest == null || manifest.manifest_version != 1 || manifest.minimum_client_protocol != 1 || manifest.schema_version != "0.1")
                throw new InvalidOperationException("ARTIFACT_VERSION");
            if (manifest.world_id != "JM" || manifest.evidence_class != "SYNTHETIC_TEST_ONLY" || manifest.vertical_datum_id != "SYNTHETIC_METRES")
                throw new InvalidOperationException("ARTIFACT_PROOF_DATA_REQUIRED");
            if (manifest.cells == null || manifest.cells.Length == 0) throw new InvalidOperationException("ARTIFACT_EMPTY_MANIFEST");
            Manifest = manifest; var hashes=new Dictionary<string,ArtifactReference>();
            var grid=new WorldGrid(manifest.anchor_e,manifest.anchor_n);
            foreach (CellEntry cell in manifest.cells)
            {
                CellId id=CellId.Parse(cell.cell_id);GlobalPosition min=grid.Minimum(id);
                if (id.Level!=CellLevel.W1 || cell.bounds==null || cell.bounds.min_e!=min.East || cell.bounds.min_n!=min.North || cell.bounds.max_e!=min.East+1000 || cell.bounds.max_n!=min.North+1000)
                    throw new InvalidOperationException("ARTIFACT_BOUNDS");
                Cells.Add(id,cell);
                if(cell.layers==null)throw new InvalidOperationException("ARTIFACT_LAYERS");
                Add(id,StreamLayer.Terrain,cell.layers.terrain,hashes);Add(id,StreamLayer.Roads,cell.layers.roads,hashes);
                var terrain=cell.layers.terrain[0];var road=cell.layers.roads[0];
                if(terrain.kind!="terrain.mesh" || road.kind!="roads.mesh" || terrain.dependencies.Length!=0 || road.dependencies.Length!=1 || road.dependencies[0]!=terrain.artifact_id)
                    throw new InvalidOperationException("ARTIFACT_PROOF_DEPENDENCIES");
            }
            foreach(var artifact in hashes.Values)foreach(string dependency in artifact.dependencies)
                if(!hashes.ContainsKey(dependency))throw new InvalidOperationException("ARTIFACT_DEPENDENCY_MISSING");
            var visited=new HashSet<string>();var visiting=new HashSet<string>();
            foreach(string hash in hashes.Keys)Visit(hash,hashes,visited,visiting);
        }
        void Add(CellId cell,StreamLayer layer,ArtifactReference[] refs,Dictionary<string,ArtifactReference> hashes)
        {
            if(refs==null || refs.Length!=1)throw new InvalidOperationException("ARTIFACT_PROOF_LAYER_COUNT");
            ArtifactReference r=refs[0];
            if(r==null || !Regex.IsMatch(r.content_hash??"","^sha256:[0-9a-f]{64}$") || r.artifact_id!=r.content_hash
               || !Regex.IsMatch(r.uri??"","^objects/[0-9a-f]{64}\\.json$") || r.uri!="objects/"+r.content_hash.Substring(7)+".json"
               || r.byte_size<=0 || r.byte_size>1024*1024 || r.dependencies==null || r.compression!="none")
                throw new InvalidOperationException("ARTIFACT_REFERENCE");
            if(hashes.ContainsKey(r.artifact_id))throw new InvalidOperationException("ARTIFACT_DUPLICATE_REFERENCE");
            Artifacts.Add(new StreamKey(cell,layer),r);hashes.Add(r.artifact_id,r);
        }
        static void Visit(string id,Dictionary<string,ArtifactReference> refs,HashSet<string> visited,HashSet<string> visiting)
        {
            if(visited.Contains(id))return;
            if(!visiting.Add(id))throw new InvalidOperationException("ARTIFACT_DEPENDENCY_CYCLE");
            foreach(string d in refs[id].dependencies)Visit(d,refs,visited,visiting);
            visiting.Remove(id);visited.Add(id);
        }
    }
}
