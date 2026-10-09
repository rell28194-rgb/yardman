using System;
using System.Threading;
using System.Threading.Tasks;
using Jamaica.Content;
using Jamaica.Streaming;
using UnityEngine.Networking;

namespace Jamaica.Unity.Runtime
{
    public sealed class UnityContentSource : IArtifactSource
    {
        readonly ContentCatalog catalog; readonly string root;
        public UnityContentSource(ContentCatalog catalog,string root) { this.catalog=catalog;this.root=root.TrimEnd('/'); }
        public bool Contains(StreamKey key) { return catalog.Artifacts.ContainsKey(key); }
        public async Task<byte[]> LoadAsync(StreamKey key,CancellationToken token)
        {
            ArtifactReference reference=catalog.Artifacts[key];
            byte[] data=await Read(root+"/"+reference.uri,token);
            await Task.Run(()=>ArtifactIntegrity.Verify(data,reference.byte_size,reference.content_hash),token);
            return data;
        }
        public static async Task<byte[]> Read(string uri,CancellationToken token)
        {
            if(!uri.Contains("://") && !uri.StartsWith("jar:"))uri=new Uri(uri).AbsoluteUri;
            using(var request=UnityWebRequest.Get(uri))
            {
                request.timeout=15;var operation=request.SendWebRequest();
                // UnitySynchronizationContext resumes this on the main thread; no thread calls Unity APIs.
                while(!operation.isDone)
                {
                    if(token.IsCancellationRequested){request.Abort();token.ThrowIfCancellationRequested();}
                    await Task.Yield();
                }
                token.ThrowIfCancellationRequested();
                if(request.result!=UnityWebRequest.Result.Success)throw new InvalidOperationException("STREAM_CONTENT_REQUEST");
                return request.downloadHandler.data;
            }
        }
    }
}
