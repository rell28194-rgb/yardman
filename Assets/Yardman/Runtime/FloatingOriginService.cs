using System.Collections.Generic;
using Jamaica.World;
using UnityEngine;

namespace Jamaica.Unity.Runtime
{
    public sealed class FloatingOriginService
    {
        public readonly OriginFrame Frame;
        readonly HashSet<Transform> roots=new HashSet<Transform>();
        public FloatingOriginService(GlobalPosition origin) { Frame=new OriginFrame(origin); }
        public void Register(Transform root) { roots.Add(root); }
        public void Unregister(Transform root) { roots.Remove(root); }
        public Vector3 Local(GlobalPosition p) { var v=Frame.Local(p);return new Vector3((float)v.East,(float)v.Height,(float)v.North); }
        public GlobalPosition Global(Vector3 p) { return Frame.Global(new GlobalPosition(p.x,p.z,p.y)); }
        public void Rebase(GlobalPosition next)
        {
            var d=Frame.Rebase(next);var delta=new Vector3((float)d.East,(float)d.Height,(float)d.North);
            foreach(Transform root in roots)
            {
                if(root==null)continue;
                var body=root.GetComponent<Rigidbody>();
                if(body!=null)
                {
                    Vector3 v=body.linearVelocity,w=body.angularVelocity;
                    body.position+=delta;
                    if(!body.isKinematic){body.linearVelocity=v;body.angularVelocity=w;}
                }
                else root.position+=delta;
            }
            Physics.SyncTransforms();
        }
    }
}
