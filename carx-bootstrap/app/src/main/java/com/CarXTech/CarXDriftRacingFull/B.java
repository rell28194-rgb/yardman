package com.CarXTech.CarXDriftRacingFull;

import android.app.*;
import android.os.*;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;

public class B extends Activity {
  static final String OBB="main.279.com.CarXTech.CarXDriftRacingFull.obb";
  static final String SEED="carx_seed.obb";
  static final long EXPECTED_BYTES=512575234L;
  static final String EXPECTED_SHA="3e85274bc609e43751615c025a047b0c0fddd64c53fba54530a02d3dbe180337";
  TextView status,detail; ProgressBar progress; Button launch,reinstall;
  volatile boolean busy=false;

  public void onCreate(Bundle b){super.onCreate(b);build();ensureExactObb();}

  void build(){
    LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),dp(18));
    TextView title=new TextView(this);title.setText("CarX Fusion 0.24 Clean Fusion");title.setTextSize(24);title.setTypeface(null,Typeface.BOLD);root.addView(title);
    TextView sub=new TextView(this);sub.setText("Clean managed-code patch + validated Fusion content: Crown, Highway Corvette/HotRod/ChevyPickup, Highway hub/audio/road texture, RR3 R8 and BMW M4 DTM.");root.addView(sub);
    status=new TextView(this);status.setTypeface(null,Typeface.BOLD);status.setTextSize(17);status.setPadding(0,dp(12),0,dp(6));root.addView(status);
    progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(10)));
    detail=new TextView(this);detail.setTypeface(Typeface.MONOSPACE);detail.setTextSize(12);detail.setTextIsSelectable(true);root.addView(detail);
    reinstall=new Button(this);reinstall.setAllCaps(false);reinstall.setText("Reinstall validated Fusion OBB");reinstall.setOnClickListener(v->installSeed(true));root.addView(reinstall);
    launch=new Button(this);launch.setAllCaps(false);launch.setText("Launch CarX Fusion");launch.setEnabled(false);launch.setOnClickListener(v->startUnity());root.addView(launch);
    TextView note=new TextView(this);note.setText("Validated Fusion OBB: 6,126 entries\n34 intended modified members / 0 checkpoint mismatches\nSHA-256: 3e85274bc609e43751615c025a047b0c0fddd64c53fba54530a02d3dbe180337");root.addView(note);
    setContentView(root);
  }

  File obb(){File d=getObbDir();if(d!=null&&!d.exists())d.mkdirs();return new File(d,OBB);}

  void ensureExactObb(){if(busy)return;busy=true;setButtons(false);new Thread(()->{try{
    File f=obb();if(f.exists()&&f.length()==EXPECTED_BYTES){ui("Hashing installed Fusion OBB…",60,human(f.length()),false);String h=sha(f);if(EXPECTED_SHA.equalsIgnoreCase(h)){ui("Validated Fusion OBB verified",1000,"bytes="+f.length()+"\nSHA256="+h,true);sleep(500);startUnity();return;}}
    installSeedInternal(false);
  }catch(Throwable t){ui("Fusion OBB verification failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void installSeed(boolean force){if(busy)return;busy=true;setButtons(false);new Thread(()->{try{installSeedInternal(force);}catch(Throwable t){ui("Fusion OBB install failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void installSeedInternal(boolean force)throws Exception{
    File dest=obb(),stage=new File(dest.getAbsolutePath()+".fusion024.tmp");if(stage.exists()&&!stage.delete())throw new IOException("Could not reset staging file");
    ui("Installing validated Fusion OBB…",0,"Writing to:\n"+dest.getAbsolutePath(),false);
    MessageDigest md=MessageDigest.getInstance("SHA-256");long done=0,last=0;
    try(InputStream in=new BufferedInputStream(getAssets().open(SEED),262144);OutputStream out=new BufferedOutputStream(new FileOutputStream(stage),262144)){
      byte[]buf=new byte[262144];int n;while((n=in.read(buf))>0){out.write(buf,0,n);md.update(buf,0,n);done+=n;long now=System.currentTimeMillis();if(now-last>250){last=now;ui("Installing validated Fusion OBB",permille(done,EXPECTED_BYTES),human(done)+" / "+human(EXPECTED_BYTES),false);}}out.flush();
    }
    if(stage.length()!=EXPECTED_BYTES){stage.delete();throw new IOException("OBB size mismatch: "+stage.length()+" expected "+EXPECTED_BYTES);}
    String h=hex(md.digest());if(!EXPECTED_SHA.equalsIgnoreCase(h)){stage.delete();throw new IOException("OBB SHA mismatch\nexpected "+EXPECTED_SHA+"\ngot "+h);}
    if(dest.exists()&&!dest.delete()){stage.delete();throw new IOException("Could not replace existing OBB");}
    if(!stage.renameTo(dest)){stage.delete();throw new IOException("Could not commit validated Fusion OBB");}
    ui("Validated Fusion OBB installed",1000,"bytes="+dest.length()+"\nSHA256="+h+"\nLaunching clean Fusion runtime…",true);sleep(700);startUnity();
  }

  void startUnity(){runOnUiThread(()->{try{android.content.Intent i=new android.content.Intent();i.setClassName(getPackageName(),"com.prime31.UnityPlayerNativeActivity");i.addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP);startActivity(i);finish();}catch(Throwable t){status.setText("Unity launch failed");detail.setText(t.toString());}});}
  void setButtons(boolean enabled){runOnUiThread(()->{if(reinstall!=null)reinstall.setEnabled(enabled);});}
  void ui(String s,int p,String d,boolean allow){runOnUiThread(()->{status.setText(s);progress.setProgress(Math.max(0,Math.min(1000,p)));detail.setText(d);launch.setEnabled(allow);});}
  static int permille(long a,long b){return b<=0?0:(int)Math.max(0,Math.min(1000,(a*1000L)/b));}
  static String sha(File f)throws Exception{MessageDigest m=MessageDigest.getInstance("SHA-256");try(InputStream in=new BufferedInputStream(new FileInputStream(f),262144)){byte[]b=new byte[262144];int n;while((n=in.read(b))>0)m.update(b,0,n);}return hex(m.digest());}
  static String hex(byte[]d){StringBuilder s=new StringBuilder();for(byte v:d)s.append(String.format(Locale.US,"%02x",v&255));return s.toString();}
  static String human(long n){double v=n;String[]u={"B","KiB","MiB","GiB"};int i=0;while(v>=1024&&i<u.length-1){v/=1024;i++;}return String.format(Locale.US,"%.2f %s",v,u[i]);}
  static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException ignored){}}
  int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
