using System;
using System.IO;
using Jamaica.Unity.Runtime;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

namespace Jamaica.Unity.Editor
{
    [InitializeOnLoad]
    public static class YardmanBuild
    {
        public const string ScenePath="Assets/Yardman/Generated/StreamingProof.unity";
        static YardmanBuild()
        {
            EditorApplication.delayCall+=()=>{if(!Application.isBatchMode&&!File.Exists(ScenePath)&&!EditorApplication.isPlayingOrWillChangePlaymode)CreateProof();};
        }
        [MenuItem("Yardman/Create streaming proof scene")]
        public static void CreateProof()
        {
            Directory.CreateDirectory("Assets/Yardman/Generated");AssetDatabase.Refresh();
            var scene=EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
            var camera=new GameObject("Main Camera").AddComponent<Camera>();camera.tag="MainCamera";camera.transform.position=new Vector3(480,20,480);camera.nearClipPlane=.1f;camera.backgroundColor=new Color(.44f,.65f,.77f);camera.clearFlags=CameraClearFlags.Skybox;
            camera.gameObject.AddComponent<AudioListener>();
            var sun=new GameObject("Tropical daylight").AddComponent<Light>();sun.type=LightType.Directional;sun.intensity=1.2f;sun.color=new Color(1,.95f,.86f);sun.shadows=LightShadows.Soft;sun.transform.rotation=Quaternion.Euler(42,-35,0);RenderSettings.sun=sun;
            RenderSettings.ambientMode=AmbientMode.Trilight;RenderSettings.ambientSkyColor=new Color(.45f,.62f,.77f);RenderSettings.ambientEquatorColor=new Color(.28f,.32f,.26f);RenderSettings.ambientGroundColor=new Color(.13f,.14f,.1f);
            RenderSettings.fog=true;RenderSettings.fogMode=FogMode.ExponentialSquared;RenderSettings.fogDensity=.00028f;RenderSettings.fogColor=new Color(.52f,.66f,.72f);
            var proof=new GameObject("Yardman streaming proof").AddComponent<ProofRuntime>();proof.View=camera;
            proof.TerrainMaterial=Material("Terrain",new Color(.3f,.4f,.22f),0,.15f);
            proof.RoadMaterial=Material("Road",new Color(.13f,.14f,.15f),0,.3f);
            proof.ProbeMaterial=Material("TraversalProbe",new Color(.93f,.61f,.12f),.55f,.7f);
            EditorSceneManager.SaveScene(scene,ScenePath);
            EditorBuildSettings.scenes=new[]{new EditorBuildSettingsScene(ScenePath,true)};
            PlayerSettings.companyName="Rell";PlayerSettings.productName="Yardman";PlayerSettings.bundleVersion="0.1.0";
            PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Android,"com.rellunfiltered.yardman");
            PlayerSettings.defaultInterfaceOrientation=UIOrientation.LandscapeLeft;
            PlayerSettings.colorSpace=ColorSpace.Linear;PlayerSettings.runInBackground=true;
            AssetDatabase.SaveAssets();
        }
        static Material Material(string name,Color color,float metallic,float smoothness)
        {
            string path="Assets/Yardman/Generated/"+name+".mat";
            var material=AssetDatabase.LoadAssetAtPath<Material>(path);
            if(material==null){material=new Material(Shader.Find("Standard"));AssetDatabase.CreateAsset(material,path);}
            material.color=color;material.SetFloat("_Metallic",metallic);material.SetFloat("_Glossiness",smoothness);EditorUtility.SetDirty(material);return material;
        }
        // Unity Build Automation pre-export method: Jamaica.Unity.Editor.YardmanBuild.PreExport
        public static void PreExport()
        {
            if(!File.Exists("Assets/StreamingAssets/Yardman/manifest.json"))throw new BuildFailedException("ARTIFACT_MANIFEST_MISSING: run Tools/build_content.sh");
            CreateProof();
            PlayerSettings.SetScriptingBackend(NamedBuildTarget.Android,ScriptingImplementation.IL2CPP);
            PlayerSettings.Android.targetArchitectures=AndroidArchitecture.ARM64;
            PlayerSettings.Android.minSdkVersion=AndroidSdkVersions.AndroidApiLevel26;
            PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android,false);
            PlayerSettings.SetGraphicsAPIs(BuildTarget.Android,new[]{GraphicsDeviceType.Vulkan,GraphicsDeviceType.OpenGLES3});
        }
        public static void Android()
        {
            PreExport();Directory.CreateDirectory("Builds/Android");
            EditorUserBuildSettings.buildAppBundle=false;
            BuildReport report=BuildPipeline.BuildPlayer(new BuildPlayerOptions{scenes=new[]{ScenePath},locationPathName="Builds/Android/Yardman-Proof.apk",target=BuildTarget.Android,options=BuildOptions.Development});
            string summary="{\"result\":\""+report.summary.result+"\",\"total_errors\":"+report.summary.totalErrors+",\"total_bytes\":"+report.summary.totalSize+"}";
            File.WriteAllText("Builds/Android/build-result.json",summary);
            if(report.summary.result!=BuildResult.Succeeded)throw new BuildFailedException(summary);
        }
    }
}
