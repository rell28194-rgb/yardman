using System;
using System.Collections.Generic;
using System.Text;
using Jamaica.Content;
using Jamaica.Streaming;
using UnityEngine;

namespace Jamaica.Unity.Runtime
{
    public sealed class CellPresentation : IDisposable
    {
        readonly ContentCatalog catalog;readonly FloatingOriginService origin;
        readonly Material terrainMaterial,roadMaterial;
        readonly Dictionary<StreamKey,GameObject> objects=new Dictionary<StreamKey,GameObject>();
        public CellPresentation(ContentCatalog catalog,FloatingOriginService origin,Material terrain,Material road)
        {this.catalog=catalog;this.origin=origin;terrainMaterial=terrain;roadMaterial=road;}
        public void Activate(StreamKey key,byte[] data)
        {
            var cell=catalog.Cells[key.Cell]; Mesh mesh=null;GameObject go=null;
            try
            {
                mesh=key.Layer==StreamLayer.Terrain?Terrain(JsonUtility.FromJson<TerrainPayload>(Encoding.UTF8.GetString(data)),key):Road(JsonUtility.FromJson<RoadPayload>(Encoding.UTF8.GetString(data)),key);
                go=new GameObject(key.ToString());go.SetActive(false);
                go.transform.position=origin.Local(new Jamaica.World.GlobalPosition(cell.bounds.min_e,cell.bounds.min_n));
                go.AddComponent<MeshFilter>().sharedMesh=mesh;
                var renderer=go.AddComponent<MeshRenderer>();renderer.sharedMaterial=key.Layer==StreamLayer.Terrain?terrainMaterial:roadMaterial;
                go.AddComponent<MeshCollider>().sharedMesh=mesh;
                go.SetActive(true);objects.Add(key,go);origin.Register(go.transform);
            }
            catch {if(go!=null)UnityEngine.Object.Destroy(go);if(mesh!=null)UnityEngine.Object.Destroy(mesh);throw;}
        }
        public void Deactivate(StreamKey key)
        {
            GameObject go;if(!objects.TryGetValue(key,out go))return;
            origin.Unregister(go.transform);var mesh=go.GetComponent<MeshFilter>().sharedMesh;
            go.SetActive(false);UnityEngine.Object.Destroy(go);UnityEngine.Object.Destroy(mesh);objects.Remove(key);
        }
        static Mesh Terrain(TerrainPayload p,StreamKey key)
        {
            if(p==null||p.payload_version!=1||p.cell_id!=key.Cell.ToString()||p.sample_count!=17||p.heights==null||p.heights.Length!=289||p.spacing_m!=62.5f)
                throw new InvalidOperationException("ARTIFACT_TERRAIN_PAYLOAD");
            int n=p.sample_count;var v=new Vector3[n*n];var uv=new Vector2[v.Length];var t=new int[(n-1)*(n-1)*6];int at=0;
            for(int z=0;z<n;z++)for(int x=0;x<n;x++)
            {int i=z*n+x;float h=p.heights[i];if(float.IsNaN(h)||float.IsInfinity(h))throw new InvalidOperationException("ARTIFACT_HEIGHT");v[i]=new Vector3(x*p.spacing_m,h,z*p.spacing_m);uv[i]=new Vector2(x/(float)(n-1),z/(float)(n-1));}
            for(int z=0;z<n-1;z++)for(int x=0;x<n-1;x++)
            {int i=z*n+x;t[at++]=i;t[at++]=i+n;t[at++]=i+1;t[at++]=i+1;t[at++]=i+n;t[at++]=i+n+1;}
            var mesh=new Mesh{name=key.ToString(),vertices=v,triangles=t,uv=uv};mesh.RecalculateNormals();mesh.RecalculateBounds();return mesh;
        }
        static Mesh Road(RoadPayload p,StreamKey key)
        {
            if(p==null||p.payload_version!=1||p.cell_id!=key.Cell.ToString()||p.points==null||p.points.Length!=17||float.IsNaN(p.width_m)||p.width_m<=0||p.width_m>100)
                throw new InvalidOperationException("ARTIFACT_ROAD_PAYLOAD");
            int n=p.points.Length;var v=new Vector3[n*2];var uv=new Vector2[n*2];var t=new int[(n-1)*6];
            for(int i=0;i<n;i++)
            {
                var q=p.points[i];
                if(q==null||!Jamaica.World.GlobalPosition.Finite(q.east)||!Jamaica.World.GlobalPosition.Finite(q.north)||!Jamaica.World.GlobalPosition.Finite(q.height))throw new InvalidOperationException("ARTIFACT_ROAD_POINT");
                v[2*i]=new Vector3(q.east,q.height,q.north-p.width_m/2);v[2*i+1]=new Vector3(q.east,q.height,q.north+p.width_m/2);uv[2*i]=new Vector2(i*8,0);uv[2*i+1]=new Vector2(i*8,1);if(i<n-1){int a=i*6,j=i*2;t[a]=j;t[a+1]=j+1;t[a+2]=j+2;t[a+3]=j+2;t[a+4]=j+1;t[a+5]=j+3;}
            }
            var mesh=new Mesh{name=key.ToString(),vertices=v,triangles=t,uv=uv};mesh.RecalculateNormals();mesh.RecalculateBounds();return mesh;
        }
        public void Dispose(){foreach(var key in new List<StreamKey>(objects.Keys))Deactivate(key);}
    }
}
