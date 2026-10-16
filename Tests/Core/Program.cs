using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Jamaica.World;
using Jamaica.Streaming;
using Jamaica.Simulation;
using Jamaica.Content;

class Program
{
    static int passed, failed;
    static void Check(bool value, string message = "assertion") { if (!value) throw new Exception(message); }
    static void Near(double a, double b, double tolerance = 1e-8) { Check(Math.Abs(a-b) <= tolerance, a+" != "+b); }
    static void Throws(Action action) { bool threw=false; try { action(); } catch { threw=true; } Check(threw,"expected exception"); }
    static void Test(string name, Action test)
    { try { test();passed++;Console.WriteLine("PASS "+name); } catch(Exception e) { failed++;Console.WriteLine("FAIL "+name+": "+e.Message); } }
    class Source : IArtifactSource
    {
        public bool Immediate=true, Fails;
        public readonly Dictionary<StreamKey,List<TaskCompletionSource<byte[]>>> Pending = new Dictionary<StreamKey,List<TaskCompletionSource<byte[]>>>();
        public bool Contains(StreamKey key) { return true; }
        public Task<byte[]> LoadAsync(StreamKey key,CancellationToken token)
        {
            if(Fails) return Task.FromException<byte[]>(new Exception("injected"));
            if(Immediate)return Task.FromResult(new byte[]{1,2,3});
            var completion=new TaskCompletionSource<byte[]>();
            if(!Pending.ContainsKey(key))Pending[key]=new List<TaskCompletionSource<byte[]>>();Pending[key].Add(completion);
            return completion.Task; // Intentionally ignores cancellation to test late completion safety.
        }
    }
    static StreamKey Key(int x,StreamLayer layer=StreamLayer.Terrain) { return new StreamKey(new CellId(CellLevel.W1,x,0),layer); }
    static StreamRequest Request(StreamKey key,double deadline=10) { return new StreamRequest(key,100,deadline); }
    static WorldManifest Manifest()
    {
        string terrain="sha256:"+new string('a',64),road="sha256:"+new string('b',64);
        Func<string,string,string[],ArtifactReference> artifact=(hash,kind,deps)=>new ArtifactReference{artifact_id=hash,content_hash=hash,uri="objects/"+hash.Substring(7)+".json",byte_size=100,compression="none",dependencies=deps,kind=kind};
        return new WorldManifest{manifest_version=1,minimum_client_protocol=1,schema_version="0.1",world_id="JM",world_version="synthetic-test",evidence_class="SYNTHETIC_TEST_ONLY",vertical_datum_id="SYNTHETIC_METRES",cells=new[]{new CellEntry{cell_id="JM:W1:0:0",revision=1,bounds=new CellBounds{min_e=0,min_n=0,max_e=1000,max_n=1000},layers=new CellLayers{terrain=new[]{artifact(terrain,"terrain.mesh",new string[0])},roads=new[]{artifact(road,"roads.mesh",new[]{terrain})}}}}};
    }
    static int Main()
    {
        Test("half-open and negative indexing",()=>{var g=new WorldGrid(0,0);Check(g.At(new GlobalPosition(-.001,-1000)).ToString()=="JM:W1:-1:-1");Check(g.At(new GlobalPosition(1000,999.999)).ToString()=="JM:W1:1:0");});
        Test("floor parent across zero",()=>{Check(new CellId(CellLevel.W1,-1,-9).Parent(CellLevel.M8).ToString()=="JM:M8:-1:-2");});
        Test("noncanonical IDs rejected",()=>{foreach(string s in new[]{"JM:1000:0:0","JM:W1:01:0","JM:W1:-0:0","JM:W1:0:0 "})Throws(()=>CellId.Parse(s));});
        Test("culture-independent identity",()=>{var old=CultureInfo.CurrentCulture;try{CultureInfo.CurrentCulture=new CultureInfo("ar-SA");Check(CellId.Parse("JM:W1:-99:200").ToString()=="JM:W1:-99:200");}finally{CultureInfo.CurrentCulture=old;}});
        Test("finite coordinate enforcement",()=>{Throws(()=>new GlobalPosition(double.NaN,0));Throws(()=>new GlobalPosition(0,double.PositiveInfinity));});
        Test("entity ID stable roundtrip",()=>{var id=EntityId.Parse("715139ea-8735-4308-a537-fbe3af866ed9");Check(EntityId.Parse(id.ToString()).Equals(id));Throws(()=>new EntityId(Guid.Empty));});
        Test("10000 rebases preserve world position",()=>{var p=new GlobalPosition(789123.456,234567.891,2256.2);var f=new OriginFrame(new GlobalPosition(700000,200000));for(int i=0;i<10000;i++){var local=f.Local(p);var delta=f.Rebase(new GlobalPosition(700000+i*7,200000+i*3));var shifted=new GlobalPosition(local.East+delta.East,local.North+delta.North,local.Height+delta.Height);var restored=f.Global(shifted);Near(restored.East,p.East);Near(restored.North,p.North);Near(restored.Height,p.Height);}});
        Test("SHA256 known vector and corruption",()=>{byte[] data=Encoding.UTF8.GetBytes("abc");Check(ArtifactIntegrity.Hash(data)=="sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");Throws(()=>ArtifactIntegrity.Verify(data,4,ArtifactIntegrity.Hash(data)));});
        Test("physics readiness requires both layers",()=>{using(var s=new CellStreamer(new Source())){s.SetDesired(new[]{Request(Key(0)),Request(Key(0,StreamLayer.Roads))});Check(!s.PhysicsReady(Key(0).Cell));s.Tick(0);s.Tick(.1);Check(s.PhysicsReady(Key(0).Cell));}});
        Test("cancelled stale completion never activates",()=>{var source=new Source{Immediate=false};int count=0;using(var s=new CellStreamer(source)){s.Activate=(k,b)=>count++;s.SetDesired(new[]{Request(Key(0))});s.Tick(0);s.SetDesired(new StreamRequest[0]);s.SetDesired(new[]{Request(Key(0))});s.Tick(1);source.Pending[Key(0)][0].SetResult(new byte[]{1});s.Tick(2);Check(count==0);source.Pending[Key(0)][1].SetResult(new byte[]{2});s.Tick(3);Check(count==1);}});
        Test("integration budget is enforced",()=>{using(var s=new CellStreamer(new Source()){Concurrency=8,IntegrationBudget=1}){s.SetDesired(Enumerable.Range(0,5).Select(x=>Request(Key(x))));s.Tick(0);s.Tick(1);Check(s.Metrics.Active==1);s.Tick(2);Check(s.Metrics.Active==2);}});
        Test("failed integration is not physics ready",()=>{using(var s=new CellStreamer(new Source())){s.Activate=(k,b)=>{throw new Exception();};s.SetDesired(new[]{Request(Key(0))});s.Tick(0);s.Tick(1);Check(!s.IsActive(Key(0)));Check(s.Metrics.Failed==1);}});
        Test("replanning cannot reset deadline",()=>{using(var s=new CellStreamer(new Source{Immediate=false})){s.SetDesired(new[]{Request(Key(0),1)});s.Tick(0);s.SetDesired(new[]{Request(Key(0),100)});s.Tick(2);s.Tick(3);Check(s.Metrics.DeadlineMisses==1);}});
        Test("bounded retry after failure",()=>{using(var s=new CellStreamer(new Source{Fails=true})){s.SetDesired(new[]{Request(Key(0))});for(int t=0;t<100;t++)s.Tick(t);Check(s.Metrics.Failed==3);}});
        Test("noncooperative load still times out",()=>{var source=new Source{Immediate=false};using(var s=new CellStreamer(source){LoadTimeoutSeconds=1}){s.SetDesired(new[]{Request(Key(0))});s.Tick(0);s.Tick(2);Check(s.Metrics.Failed==1&&s.Metrics.Loading==0);source.Pending[Key(0)][0].SetResult(new byte[]{1});s.Tick(2.1);Check(!s.IsActive(Key(0)));}});
        Test("dependent integration waits for terrain",()=>{using(var s=new CellStreamer(new Source()){IntegrationBudget=1}){s.CanActivate=k=>k.Layer==StreamLayer.Terrain||s.IsActive(new StreamKey(k.Cell,StreamLayer.Terrain));s.SetDesired(new[]{new StreamRequest(Key(0,StreamLayer.Roads),101,10),Request(Key(0))});s.Tick(0);s.Tick(1);Check(s.IsActive(Key(0))&&!s.PhysicsReady(Key(0).Cell));s.Tick(2);Check(s.PhysicsReady(Key(0).Cell));}});
        Test("capacity stays bounded across churn",()=>{using(var s=new CellStreamer(new Source()){Capacity=12}){for(int i=0;i<100;i++){s.SetDesired(Enumerable.Range(i,20).Select(x=>Request(Key(x))));s.Tick(i);s.Tick(i+.1);Check(s.Count<=12);}Check(s.Metrics.Evicted>0);}});
        Test("deactivation releases every active entry",()=>{int release=0;var s=new CellStreamer(new Source());s.Deactivate=k=>release++;s.SetDesired(new[]{Request(Key(0)),Request(Key(1))});s.Tick(0);s.Tick(1);s.Dispose();s.Dispose();Check(release==2);Check(s.Count==0);});
        Test("stopping distance grows quadratically",()=>{var p=new PredictivePlanner(new WorldGrid(0,0));Check(p.Lookahead(80)>2*p.Lookahead(40));Throws(()=>p.Lookahead(-1));});
        Test("high-speed planner requests forward cells",()=>{var p=new PredictivePlanner(new WorldGrid(0,0));var keys=p.Plan(new GlobalPosition(990,500),100,0,0).Select(x=>x.Key).ToArray();Check(keys.Any(k=>k.Cell.X>=2));Check(keys.Any(k=>k.Cell.X==-1));});
        Test("persistent state survives tier changes",()=>{var id=EntityId.Parse("715139ea-8735-4308-a537-fbe3af866ed9");var store=new EntityStore();store.Add(new EntityState(id,new GlobalPosition(0,0)));store.SetTier(id,FidelityTier.Hero);store.Move(id,new GlobalPosition(1000,0),0);store.SetTier(id,FidelityTier.PersistentBackground);store.SetTier(id,FidelityTier.Hero);Check(store.Count==1);Near(store.Get(id).OdometerMetres,1000);Check(store.Get(id).Version==1);Throws(()=>store.Move(id,new GlobalPosition(2000,0),0));});
        Test("event order is deterministic with budget",()=>{var s=new EventScheduler();var seen=new List<int>();for(int i=0;i<100;i++){int value=i;s.Schedule("e"+i,10,()=>seen.Add(value));}s.Advance(100,3);Check(s.Now==10);while(s.Count>0)s.Advance(100,3);Check(seen.SequenceEqual(Enumerable.Range(0,100)));Check(s.Now==100);});
        Test("bad event isolated and cancelled event absent",()=>{var s=new EventScheduler();int runs=0;s.Schedule("a",1,()=>{throw new Exception();});s.Schedule("b",1,()=>runs++);s.Schedule("c",1,()=>runs+=100);s.Cancel("c");s.Advance(2);Check(runs==1&&s.Failed==1&&s.Count==0);});
        Test("past and duplicate events rejected",()=>{var s=new EventScheduler();s.Schedule("x",1,()=>{});Throws(()=>s.Schedule("x",2,()=>{}));s.Advance(5);Throws(()=>s.Schedule("past",1,()=>{}));});
        Test("valid proof manifest has two addressable layers",()=>{var c=new ContentCatalog(Manifest());Check(c.Cells.Count==1&&c.Artifacts.Count==2);});
        Test("manifest rejects unsupported or geographic data",()=>{var m=Manifest();m.minimum_client_protocol=2;Throws(()=>new ContentCatalog(m));m=Manifest();m.evidence_class="ACCEPTED_GEOGRAPHY";Throws(()=>new ContentCatalog(m));});
        Test("manifest rejects incorrect bounds and duplicate cells",()=>{var m=Manifest();m.cells[0].bounds.max_e=999;Throws(()=>new ContentCatalog(m));m=Manifest();m.cells=new[]{m.cells[0],m.cells[0]};Throws(()=>new ContentCatalog(m));});
        Test("manifest rejects path escape and size bombs",()=>{var m=Manifest();m.cells[0].layers.terrain[0].uri="../secret";Throws(()=>new ContentCatalog(m));m=Manifest();m.cells[0].layers.roads[0].byte_size=100000000;Throws(()=>new ContentCatalog(m));});
        Test("manifest rejects missing or cyclic dependencies",()=>{var m=Manifest();m.cells[0].layers.roads[0].dependencies=new string[0];Throws(()=>new ContentCatalog(m));m=Manifest();m.cells[0].layers.terrain[0].dependencies=new[]{m.cells[0].layers.roads[0].artifact_id};Throws(()=>new ContentCatalog(m));});
        Test("30 simulated minute traversal keeps bounded working set",()=>
        {
            var grid=new WorldGrid(0,0);var planner=new PredictivePlanner(grid);var frame=new OriginFrame(new GlobalPosition(0,0));
            var store=new EntityStore();var id=EntityId.Parse("715139ea-8735-4308-a537-fbe3af866ed9");store.Add(new EntityState(id,new GlobalPosition(500,500)));int direction=1,holds=0,rebases=0;
            using(var s=new CellStreamer(new Source()){Capacity=96,IntegrationBudget=1})
            {
                s.CanActivate=k=>k.Layer==StreamLayer.Terrain||s.IsActive(new StreamKey(k.Cell,StreamLayer.Terrain));
                for(int step=0;step<90000;step++)
                {
                    double now=step*.02;var state=store.Get(id);if(state.Position.East>6500)direction=-1;else if(state.Position.East< -2500)direction=1;
                    if(step%5==0)s.SetDesired(planner.Plan(state.Position,direction*70,0,now));s.Tick(now);
                    var next=new GlobalPosition(state.Position.East+direction*1.4,500);
                    if(!s.PhysicsReady(grid.At(state.Position))||!s.PhysicsReady(grid.At(next))){holds++;continue;}
                    store.Move(id,next,state.Version);var local=frame.Local(next);
                    if(Math.Abs(local.East)>2000){frame.Rebase(new GlobalPosition(Math.Floor(next.East/1000)*1000,0));rebases++;}
                    Check(s.Count<=96);Near(frame.Global(frame.Local(next)).East,next.East);Check(store.Count==1);
                }
                Check(store.Get(id).OdometerMetres>125000,"distance="+store.Get(id).OdometerMetres);Check(holds<100,"holds="+holds);Check(rebases>=30,"rebases="+rebases);Check(s.Metrics.Failed==0&&s.Metrics.Evicted>100,"failed="+s.Metrics.Failed+" evicted="+s.Metrics.Evicted);
                Console.WriteLine("SOAK {\"simulated_seconds\":1800,\"odometer_m\":"+store.Get(id).OdometerMetres.ToString("F2",CultureInfo.InvariantCulture)+",\"rebases\":"+rebases+",\"safety_holds\":"+holds+",\"peak_entries\":"+s.Metrics.PeakEntries+"}");
            }
        });
        Console.WriteLine("RESULT {\"passed\":"+passed+",\"failed\":"+failed+"}");return failed==0?0:1;
    }
}
