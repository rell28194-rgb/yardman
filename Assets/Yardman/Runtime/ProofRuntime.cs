using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Jamaica.World;
using Jamaica.Content;
using Jamaica.Streaming;
using Jamaica.Simulation;
using UnityEngine;

namespace Jamaica.Unity.Runtime
{
    // Technical traversal harness. This is not the eventual vehicle solver or Jamaica map.
    public sealed class ProofRuntime : MonoBehaviour
    {
        public Material TerrainMaterial,RoadMaterial,ProbeMaterial;
        public Camera View;
        public bool AutoDrive=true;
        public float SpeedMetresPerSecond=70;
        public float BenchmarkSeconds=1800;
        ContentCatalog catalog;CellStreamer streamer;CellPresentation presentation;
        FloatingOriginService origin;WorldGrid grid;PredictivePlanner planner;
        EntityStore entities;EntityId probeId;Rigidbody probe;
        CancellationTokenSource lifetime;string status="Loading world manifest";
        double elapsed,nextPlan,nextTelemetry;float direction=1;
        long blockedSteps;bool ready,completed;string latestTelemetry;
        readonly List<float> frames=new List<float>(36000);
        [Serializable] class SavedProbe {public string entity_id;public double east,north,height,odometer;public long version;public int schema_version=1;}
        [Serializable] class Sample {public double elapsed_s,global_e,global_n,odometer_m;public int active_layers,queued_layers,origin_shifts;public long blocked_steps,managed_memory_bytes;public float frame_ms,battery_level;}
        [Serializable] class Result {public string benchmark_id="ARCH-PROOF-001_RUNTIME",result="MEASURED_NOT_CERTIFIED",unity_version,platform,device;public double duration_s,odometer_m;public int origin_shifts,peak_stream_entries;public long blocked_steps,stream_failures;public float p50_ms,p95_ms,p99_ms;}
        string SavePath {get{return Path.Combine(Application.persistentDataPath,"yardman-proof-save.json");}}
        string TelemetryPath {get{return Path.Combine(Application.persistentDataPath,"yardman-proof-telemetry.jsonl");}}

        async void Start()
        {
            lifetime=new CancellationTokenSource();
            try
            {
                string root=Application.streamingAssetsPath+"/Yardman";
                byte[] bytes=await UnityContentSource.Read(root+"/manifest.json",lifetime.Token);
                catalog=new ContentCatalog(JsonUtility.FromJson<WorldManifest>(Encoding.UTF8.GetString(bytes)));
                grid=new WorldGrid(catalog.Manifest.anchor_e,catalog.Manifest.anchor_n);
                origin=new FloatingOriginService(new GlobalPosition(0,0));planner=new PredictivePlanner(grid);
                entities=new EntityStore();probeId=EntityId.Parse("715139ea-8735-4308-a537-fbe3af866ed9");
                EntityState state=new EntityState(probeId,new GlobalPosition(500,500,12));
                if(File.Exists(SavePath))
                {
                    string saved=await Task.Run(()=>File.ReadAllText(SavePath),lifetime.Token);
                    var snapshot=JsonUtility.FromJson<SavedProbe>(saved);
                    if(snapshot.schema_version==1 && snapshot.entity_id==probeId.ToString() && catalog.Cells.ContainsKey(grid.At(new GlobalPosition(snapshot.east,snapshot.north,snapshot.height))))
                    {state.Position=new GlobalPosition(snapshot.east,snapshot.north,snapshot.height);state.OdometerMetres=snapshot.odometer;state.Version=snapshot.version;}
                }
                lifetime.Token.ThrowIfCancellationRequested();entities.Add(state);entities.SetTier(probeId,FidelityTier.PhysicsInteraction);
                origin.Rebase(new GlobalPosition(Math.Floor(state.Position.East/1000)*1000,Math.Floor(state.Position.North/1000)*1000));
                var body=GameObject.CreatePrimitive(PrimitiveType.Cube);body.name="Persistent traversal probe";body.layer=2;body.transform.localScale=new Vector3(4.4f,1.3f,1.9f);
                body.GetComponent<Renderer>().sharedMaterial=ProbeMaterial;probe=body.AddComponent<Rigidbody>();probe.isKinematic=true;probe.position=origin.Local(state.Position);origin.Register(body.transform);
                origin.Register(View.transform);QualityProfiles.Apply(YardmanQuality.Balanced,View);
                presentation=new CellPresentation(catalog,origin,TerrainMaterial,RoadMaterial);
                streamer=new CellStreamer(new UnityContentSource(catalog,root)){Capacity=96,Concurrency=4,IntegrationBudget=1};
                streamer.Activate=presentation.Activate;streamer.Deactivate=presentation.Deactivate;
                streamer.CanActivate=k=>k.Layer==StreamLayer.Terrain||streamer.IsActive(new StreamKey(k.Cell,StreamLayer.Terrain));
                streamer.Failure=(k,error)=>status=error+" "+k;
                ready=true;status="Synthetic streaming proof • 1 metre = 1 metre";
            }
            catch(OperationCanceledException){}
            catch(Exception e){status="STARTUP FAILED: "+e.Message;Debug.LogError(status);}
        }
        void Update()
        {
            if(!ready||completed)return;elapsed+=Time.unscaledDeltaTime;
            if(frames.Count<216000)frames.Add(Time.unscaledDeltaTime*1000);
            var state=entities.Get(probeId);
            if(elapsed>=nextPlan)
            {streamer.SetDesired(planner.Plan(state.Position,direction*SpeedMetresPerSecond,0,elapsed));nextPlan=elapsed+.1;}
            streamer.Tick(elapsed);
            if(elapsed>=nextTelemetry){nextTelemetry=elapsed+1;QueueTelemetry(state);}
            if(BenchmarkSeconds>0&&elapsed>=BenchmarkSeconds){completed=true;WriteResult();status="Drive finished • telemetry written";}
        }
        void FixedUpdate()
        {
            if(!ready||completed)return;
            var state=entities.Get(probeId);float throttle=AutoDrive?1:Input.GetAxisRaw("Vertical");
            // A bounded back-and-forth synthetic corridor forces repeated unload/reload and rebases.
            if(state.Position.East>6500)direction=-1;else if(state.Position.East< -2500)direction=1;
            double east=state.Position.East+direction*SpeedMetresPerSecond*throttle*Time.fixedDeltaTime;
            var proposed=new GlobalPosition(east,state.Position.North,state.Position.Height);
            if(!streamer.PhysicsReady(grid.At(state.Position))||!streamer.PhysicsReady(grid.At(proposed))){blockedSteps++;return;}
            Vector3 local=origin.Local(proposed);RaycastHit hit;
            if(!Physics.Raycast(new Vector3(local.x,100,local.z),Vector3.down,out hit,150)){blockedSteps++;return;}
            proposed=new GlobalPosition(east,state.Position.North,origin.Frame.Origin.Height+hit.point.y+.9);
            entities.Move(probeId,proposed,state.Version);
            if(Math.Abs(local.x)>2000||Math.Abs(local.z)>2000)
                origin.Rebase(new GlobalPosition(Math.Floor(proposed.East/1000)*1000,Math.Floor(proposed.North/1000)*1000));
            probe.MovePosition(origin.Local(proposed));
        }
        void LateUpdate()
        {
            if(probe==null)return;
            Vector3 goal=probe.position+new Vector3(-direction*11,7,-12);
            View.transform.position=Vector3.Lerp(View.transform.position,goal,1-Mathf.Exp(-Time.deltaTime*5));
            View.transform.LookAt(probe.position+Vector3.up);
        }
        void OnGUI()
        {
            float scale=Mathf.Max(1,Screen.width/1400f);GUI.matrix=Matrix4x4.Scale(new Vector3(scale,scale,1));
            GUILayout.BeginArea(new Rect(18,18,460,Mathf.Min(440,Screen.height/scale-36)),GUI.skin.box);
            GUILayout.Label("YARDMAN / TECHNICAL PROOF");GUILayout.Label(status);
            if(ready)
            {
                var state=entities.Get(probeId);GUILayout.Label(grid.At(state.Position)+" • "+(state.OdometerMetres/1000).ToString("F2")+" km");
                GUILayout.Label("Active layers "+streamer.Metrics.Active+"  |  rebases "+origin.Frame.Revision+"  |  safety holds "+blockedSteps);
                GUILayout.Label("Target speed: "+(SpeedMetresPerSecond*3.6f).ToString("F0")+" km/h");
                AutoDrive=GUILayout.Toggle(AutoDrive,"Automatic stress drive");
                foreach(YardmanQuality profile in Enum.GetValues(typeof(YardmanQuality)))
                    if(GUILayout.Button(profile.ToString()))QualityProfiles.Apply(profile,View);
                if(QualityProfiles.Current==YardmanQuality.Custom)
                {
                    GUILayout.Label("Shadow distance: "+QualitySettings.shadowDistance.ToString("F0")+" m");
                    QualitySettings.shadowDistance=GUILayout.HorizontalSlider(QualitySettings.shadowDistance,60,600);
                    GUILayout.Label("Detail distance multiplier: "+QualitySettings.lodBias.ToString("F1"));
                    QualitySettings.lodBias=GUILayout.HorizontalSlider(QualitySettings.lodBias,.5f,2.5f);
                }
                if(GUILayout.Button("Save persistent probe"))_ = Save();
            }
            GUILayout.EndArea();
        }
        async void QueueTelemetry(EntityState state)
        {
            var sample=new Sample{elapsed_s=elapsed,global_e=state.Position.East,global_n=state.Position.North,odometer_m=state.OdometerMetres,
                active_layers=streamer.Metrics.Active,queued_layers=streamer.Metrics.Queued,origin_shifts=origin.Frame.Revision,blocked_steps=blockedSteps,
                managed_memory_bytes=GC.GetTotalMemory(false),frame_ms=Time.unscaledDeltaTime*1000,battery_level=SystemInfo.batteryLevel};
            latestTelemetry=JsonUtility.ToJson(sample)+"\n";string path=TelemetryPath,text=latestTelemetry;
            try{await Task.Run(()=>{lock(fileLock)File.AppendAllText(path,text);});}catch(Exception){status="Telemetry write failed";}
        }
        static readonly object fileLock=new object();
        async Task Save()
        {
            if(!ready)return;var s=entities.Get(probeId);
            string text=JsonUtility.ToJson(new SavedProbe{entity_id=s.Id.ToString(),east=s.Position.East,north=s.Position.North,height=s.Position.Height,odometer=s.OdometerMetres,version=s.Version});string path=SavePath;
            try{await Task.Run(()=>{lock(fileLock){string temp=path+".tmp";File.WriteAllText(temp,text);if(File.Exists(path))File.Replace(temp,path,path+".backup");else File.Move(temp,path);}});}catch(Exception){status="Save failed";}
        }
        async void WriteResult()
        {
            frames.Sort();Func<double,float> percentile=p=>frames.Count==0?0:frames[(int)Math.Min(frames.Count-1,Math.Floor((frames.Count-1)*p))];
            var result=new Result{unity_version=Application.unityVersion,platform=Application.platform.ToString(),device=SystemInfo.deviceModel,duration_s=elapsed,
                odometer_m=entities.Get(probeId).OdometerMetres,origin_shifts=origin.Frame.Revision,peak_stream_entries=streamer.Metrics.PeakEntries,
                blocked_steps=blockedSteps,stream_failures=streamer.Metrics.Failed,p50_ms=percentile(.5),p95_ms=percentile(.95),p99_ms=percentile(.99)};
            string text=JsonUtility.ToJson(result,true),path=Path.Combine(Application.persistentDataPath,"yardman-proof-result.json");
            await Save();try{await Task.Run(()=>File.WriteAllText(path,text));}catch(Exception){status="Result write failed";}
        }
        void OnApplicationPause(bool paused){if(paused)_ = Save();}
        void OnDestroy(){lifetime?.Cancel();streamer?.Dispose();presentation?.Dispose();lifetime?.Dispose();}
    }
}
