package com.CarXTech.CarXDriftRacingFull;

import android.app.*;
import android.os.*;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.security.MessageDigest;
import java.util.Locale;

public class B extends Activity {
  static final String OBB="main.279.com.CarXTech.CarXDriftRacingFull.obb";
  static final String SEED="carx_seed.obb";
  static final long REPAIRED_BYTES=510699654L;
  static final String REPAIRED_SHA="e264227952d91ddbc49f8f13527caac823405a07320b284678b6c3bee872ee4b";
  static final String AUTHORITATIVE_SHA="7f561c6cfcb71b19ff38001f5754bbc5c2acc6239bbeecb3967f04d1b7b52c34";
  static final String OLD_SEED_SHA="508171d4460da67201981fa8c1c00159dca9d2d604656af4b267181ca0f5e945";
  TextView status,detail; ProgressBar progress; Button repair,launch,recheck;
  volatile boolean busy=false;

  public void onCreate(Bundle b){super.onCreate(b);build();repairOrCheck(true);}

  void build(){
    ScrollView sc=new ScrollView(this);
    LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),dp(18));sc.addView(root);
    TextView title=new TextView(this);title.setText("CarX Fusion Beta 0.22 Repair");title.setTextSize(24);title.setTypeface(null,Typeface.BOLD);root.addView(title);
    TextView sub=new TextView(this);sub.setText("This APK carries the repaired Beta 0.15 expansion. It replaces the stale 0.21 OBB before Unity starts.");root.addView(sub);
    status=new TextView(this);status.setTypeface(null,Typeface.BOLD);status.setTextSize(17);status.setPadding(0,dp(12),0,dp(6));root.addView(status);
    progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(10)));
    detail=new TextView(this);detail.setTypeface(Typeface.MONOSPACE);detail.setTextSize(12);detail.setTextIsSelectable(true);root.addView(detail);
    repair=new Button(this);repair.setAllCaps(false);repair.setText("Repair / reinstall embedded OBB");repair.setOnClickListener(v->repairOrCheck(true));root.addView(repair);
    recheck=new Button(this);recheck.setAllCaps(false);recheck.setText("Recheck installed OBB");recheck.setOnClickListener(v->repairOrCheck(false));root.addView(recheck);
    launch=new Button(this);launch.setAllCaps(false);launch.setText("Launch CarX");launch.setEnabled(false);launch.setOnClickListener(v->startUnity());root.addView(launch);
    TextView note=new TextView(this);note.setText("Repaired OBB: 510,699,654 bytes\nSHA-256: e264227952d91ddbc49f8f13527caac823405a07320b284678b6c3bee872ee4b\nCheckpoint audit: 38/38 documented Beta 0.15 members match.");root.addView(note);
    setContentView(sc);
  }

  File obb(){File d=getObbDir();if(d!=null&&!d.exists())d.mkdirs();return new File(d,OBB);}

  void repairOrCheck(boolean repairIfNeeded){if(busy)return;busy=true;setButtons(false);new Thread(()->{File dest=obb();try{
    if(dest.exists()&&dest.length()>0){ui("Checking installed OBB…",80,human(dest.length()),false);String h=sha(dest);
      if(REPAIRED_SHA.equalsIgnoreCase(h)){ui("Repaired OBB verified",1000,"bytes="+dest.length()+"\nSHA256="+h,true);if(repairIfNeeded){sleep(500);startUnity();}return;}
      if(AUTHORITATIVE_SHA.equalsIgnoreCase(h)){ui("Authoritative Beta 0.15 OBB verified",1000,"bytes="+dest.length()+"\nSHA256="+h,true);if(repairIfNeeded){sleep(500);startUnity();}return;}
      if(!repairIfNeeded){ui("OBB mismatch",0,"bytes="+dest.length()+"\nSHA256="+h+"\nUse Repair / reinstall embedded OBB.",false);return;}
      if(OLD_SEED_SHA.equalsIgnoreCase(h))ui("Old 0.21 OBB detected",120,"Replacing stale expansion…",false);else ui("Unknown OBB detected",120,"Replacing expansion before Unity starts…",false);
    } else if(!repairIfNeeded){ui("OBB missing",0,"Expected path:\n"+dest.getAbsolutePath(),false);return;}
    installSeed(dest);
  }catch(Throwable t){ui("OBB repair failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void installSeed(File dest)throws Exception{
    File stage=new File(dest.getAbsolutePath()+".repair.tmp");if(stage.exists()&&!stage.delete())throw new IOException("Could not reset staging file");
    ui("Installing repaired Beta 0.15 OBB…",0,"Destination:\n"+dest.getAbsolutePath(),false);
    try(InputStream in=new BufferedInputStream(getAssets().open(SEED),262144);OutputStream out=new BufferedOutputStream(new FileOutputStream(stage),262144)){
      byte[] buf=new byte[262144];long got=0,last=0;int n;while((n=in.read(buf))>=0){if(n==0)continue;out.write(buf,0,n);got+=n;long now=System.currentTimeMillis();if(now-last>250){last=now;ui("Installing repaired OBB",permille(got,REPAIRED_BYTES),human(got)+" / "+human(REPAIRED_BYTES),false);}}out.flush();
    }
    if(stage.length()!=REPAIRED_BYTES){stage.delete();throw new IOException("Embedded OBB size mismatch: "+stage.length()+" expected "+REPAIRED_BYTES);}
    ui("Verifying repaired OBB…",980,human(stage.length()),false);String h=sha(stage);if(!REPAIRED_SHA.equalsIgnoreCase(h)){stage.delete();throw new IOException("Embedded OBB SHA-256 mismatch\nexpected "+REPAIRED_SHA+"\ngot "+h);}
    if(dest.exists()&&!dest.delete()){stage.delete();throw new IOException("Could not replace old OBB");}
    if(!stage.renameTo(dest)){stage.delete();throw new IOException("Could not commit repaired OBB");}
    ui("Repaired OBB installed",1000,"bytes="+dest.length()+"\nSHA256="+h+"\nStarting Unity.",true);sleep(700);startUnity();
  }

  void startUnity(){runOnUiThread(()->{try{android.content.Intent i=new android.content.Intent();i.setClassName(getPackageName(),"com.prime31.UnityPlayerNativeActivity");i.addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP);startActivity(i);finish();}catch(Throwable t){status.setText("Unity launch failed");detail.setText(t.toString());}});}
  void setButtons(boolean enabled){runOnUiThread(()->{if(repair!=null)repair.setEnabled(enabled);if(recheck!=null)recheck.setEnabled(enabled);});}
  void ui(String s,int p,String d,boolean allow){runOnUiThread(()->{status.setText(s);progress.setProgress(Math.max(0,Math.min(1000,p)));detail.setText(d);launch.setEnabled(allow);});}
  static int permille(long a,long b){return b<=0?0:(int)Math.max(0,Math.min(1000,(a*1000L)/b));}
  static String sha(File f)throws Exception{MessageDigest m=MessageDigest.getInstance("SHA-256");try(InputStream in=new BufferedInputStream(new FileInputStream(f),262144)){byte[] b=new byte[262144];int n;while((n=in.read(b))>0)m.update(b,0,n);}StringBuilder s=new StringBuilder();for(byte v:m.digest())s.append(String.format(Locale.US,"%02x",v&255));return s.toString();}
  static String human(long n){double v=n;String[]u={"B","KiB","MiB","GiB"};int i=0;while(v>=1024&&i<u.length-1){v/=1024;i++;}return String.format(Locale.US,"%.2f %s",v,u[i]);}
  static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException ignored){}}
  int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
