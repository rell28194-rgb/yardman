using UnityEngine;

namespace Jamaica.Unity.Runtime
{
    public enum YardmanQuality { Performance, Balanced, Quality, Ultra, Custom }
    public static class QualityProfiles
    {
        public static YardmanQuality Current { get; private set; }=YardmanQuality.Balanced;
        public static void Apply(YardmanQuality profile,Camera camera)
        {
            Current=profile;if(profile==YardmanQuality.Custom)return;
            int tier=(int)profile;
            QualitySettings.shadows=ShadowQuality.All;
            QualitySettings.shadowResolution=tier<2?ShadowResolution.Medium:ShadowResolution.High;
            QualitySettings.shadowDistance=new[]{100f,180f,300f,500f}[tier];
            QualitySettings.shadowCascades=tier<2?2:4;
            QualitySettings.antiAliasing=tier<2?2:4;
            QualitySettings.lodBias=new[]{.75f,1f,1.5f,2f}[tier];
            QualitySettings.anisotropicFiltering=AnisotropicFiltering.ForceEnable;
            Application.targetFrameRate=tier==0?30:60;
            camera.farClipPlane=new[]{1600f,2200f,2800f,3500f}[tier];
        }
    }
}
