package com.CarXTech.CarXDriftRacingFull;

import android.app.*;
import android.os.*;
import android.graphics.Typeface;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

public class B extends Activity {
  static final String OBB="main.279.com.CarXTech.CarXDriftRacingFull.obb";
  static final String PATCH_ASSET="beta09_patch.zip";
  static final int EXPECTED_ENTRIES=6126;
  static final String PREFIX="assets/bin/Data/";
  static final String[] NAMES={
    "2fb2fa54f997f86408d510d9fd42b6db",
    "45da11b113f2b3349bc578886d3b6f80",
    "82192ea98dfaf75448a0b08bc9af3976",
    "d90c24e7aec11584e8b87034a6c9c5cf",
    "db2bc6f333c1ce6449a030da89cfad66",
    "e8d15f77838b2194194789905c74b2f0"};
  static final String[] SHAS={
    "16bc010ae9e2be89d9bd4eb26912637e9ae93dd121c5322c46388b6943f5591b",
    "8b4260e5b65cf2d1b1e83f2bbed218e77c6650e1d00692ae5ad1066c5fd42cac",
    "647f54c556dd956df9da9e750bca15fde3b102303331e5178816c9b9f1351e3b",
    "e7c0122a820bb507441210ecbb8e4934ad9d63c6f4a40ee00c5e3fa338e80f5a",
    "37439c7314246584033c30b07579df58d11c3a7da4d41fb08343e69a07f06602",
    "3f1e57dc498d06560d17f05d8b61e98c2f53397c8f4198d0e92b915e260c19ab"};

  TextView status,detail; ProgressBar progress; Button repair,launch,recheck;
  volatile boolean busy=false;

  public void onCreate(Bundle b){super.onCreate(b);build();checkAndRepair(true);}

  void build(){
    ScrollView sc=new ScrollView(this);LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),dp(18));sc.addView(root);
    TextView title=new TextView(this);title.setText("CarX Fusion Beta 0.22 OBB Hotfix");title.setTextSize(24);title.setTypeface(null,Typeface.BOLD);root.addView(title);
    TextView sub=new TextView(this);sub.setText("Repairs the six stale ChevyPickup/Peterbilt dependency members found in the 0.21 OBB, verifies them, then launches CarX.");root.addView(sub);
    status=new TextView(this);status.setTypeface(null,Typeface.BOLD);status.setTextSize(17);status.setPadding(0,dp(12),0,dp(6));root.addView(status);
    progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(10)));
    detail=new TextView(this);detail.setTypeface(Typeface.MONOSPACE);detail.setTextSize(12);detail.setTextIsSelectable(true);root.addView(detail);
    repair=new Button(this);repair.setAllCaps(false);repair.setText("Repair installed OBB");repair.setOnClickListener(v->checkAndRepair(true));root.addView(repair);
    recheck=new Button(this);recheck.setAllCaps(false);recheck.setText("Verify six repaired members");recheck.setOnClickListener(v->checkAndRepair(false));root.addView(recheck);
    launch=new Button(this);launch.setAllCaps(false);launch.setText("Launch CarX");launch.setEnabled(false);launch.setOnClickListener(v->startUnity());root.addView(launch);
    TextView note=new TextView(this);note.setText("This update expects the OBB already installed by Beta 0.21. It does not redownload or split the OBB.");root.addView(note);
    setContentView(sc);
  }

  File obb(){File d=getObbDir();if(d!=null&&!d.exists())d.mkdirs();return new File(d,OBB);}

  void checkAndRepair(boolean doRepair){if(busy)return;busy=true;setButtons(false);new Thread(()->{try{
    File f=obb();if(!f.exists()||f.length()==0){ui("OBB missing",0,"Beta 0.21 must install the OBB first.\nExpected:\n"+f.getAbsolutePath(),false);return;}
    ui("Checking six known-bad members…",40,human(f.length()),false);
    int good=verifySix(f);if(good==6){ui("OBB hotfix already verified",1000,"6 / 6 repaired members match Beta 0.15 checkpoints.",true);if(doRepair){sleep(500);startUnity();}return;}
    if(!doRepair){ui("OBB still needs repair",0,good+" / 6 members match. Tap Repair installed OBB.",false);return;}
    repairObb(f);
  }catch(Throwable t){ui("OBB hotfix failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void repairObb(File source)throws Exception{
    HashMap<String,byte[]> patch=loadPatch();if(patch.size()!=6)throw new IOException("Embedded patch is incomplete: "+patch.size()+" / 6");
    File stage=new File(source.getAbsolutePath()+".beta022.tmp");if(stage.exists()&&!stage.delete())throw new IOException("Could not reset staging OBB");
    ui("Rebuilding OBB with six corrected members…",80,"Keep the app open. Existing OBB stays intact until verification passes.",false);
    int entries=0,replaced=0;
    try(ZipInputStream zin=new ZipInputStream(new BufferedInputStream(new FileInputStream(source),262144));ZipOutputStream zout=new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(stage),262144))){
      zout.setLevel(Deflater.BEST_SPEED);ZipEntry e;byte[] buf=new byte[262144];
      while((e=zin.getNextEntry())!=null){entries++;String name=e.getName();ZipEntry ne=new ZipEntry(name);if(e.getTime()>0)ne.setTime(e.getTime());zout.putNextEntry(ne);
        byte[] repl=patch.get(name);if(repl!=null){zout.write(repl);replaced++;}else if(!e.isDirectory()){int n;while((n=zin.read(buf))>0)zout.write(buf,0,n);}zout.closeEntry();zin.closeEntry();
        if((entries&127)==0)ui("Rebuilding OBB",Math.min(900,80+(entries*800/EXPECTED_ENTRIES)),"entries="+entries+" / "+EXPECTED_ENTRIES+"\nreplaced="+replaced+" / 6",false);
      }
    }catch(Throwable t){stage.delete();throw t;}
    if(entries!=EXPECTED_ENTRIES){stage.delete();throw new IOException("OBB entry-count mismatch: "+entries+" expected "+EXPECTED_ENTRIES);}
    if(replaced!=6){stage.delete();throw new IOException("Only replaced "+replaced+" / 6 required members");}
    ui("Verifying repaired members…",930,human(stage.length()),false);int good=verifySix(stage);if(good!=6){stage.delete();throw new IOException("Post-repair verification failed: "+good+" / 6");}
    if(source.exists()&&!source.delete()){stage.delete();throw new IOException("Could not replace stale OBB");}
    if(!stage.renameTo(source)){stage.delete();throw new IOException("Could not commit repaired OBB");}
    ui("OBB repaired and verified",1000,"6 / 6 corrected members match.\nentries="+entries+"\nbytes="+source.length()+"\nStarting CarX…",true);sleep(700);startUnity();
  }

  HashMap<String,byte[]> loadPatch()throws Exception{
    HashMap<String,byte[]> m=new HashMap<>();try(ZipInputStream z=new ZipInputStream(new BufferedInputStream(getAssets().open(PATCH_ASSET),65536))){ZipEntry e;byte[] buf=new byte[65536];while((e=z.getNextEntry())!=null){String n=e.getName();if(!e.isDirectory()&&n.startsWith("patched/")){String base=n.substring("patched/".length());if(indexOf(base)>=0){ByteArrayOutputStream o=new ByteArrayOutputStream();int k;while((k=z.read(buf))>0)o.write(buf,0,k);m.put(PREFIX+base,o.toByteArray());}}z.closeEntry();}}return m;
  }

  int verifySix(File f)throws Exception{
    int good=0;ZipFile z=new ZipFile(f);try{for(int i=0;i<NAMES.length;i++){ZipEntry e=z.getEntry(PREFIX+NAMES[i]);if(e==null)continue;try(InputStream in=new BufferedInputStream(z.getInputStream(e),65536)){if(SHAS[i].equalsIgnoreCase(sha(in)))good++;}}}finally{z.close();}return good;
  }
  static int indexOf(String n){for(int i=0;i<NAMES.length;i++)if(NAMES[i].equals(n))return i;return -1;}
  static String sha(InputStream in)throws Exception{MessageDigest m=MessageDigest.getInstance("SHA-256");byte[] b=new byte[65536];int n;while((n=in.read(b))>0)m.update(b,0,n);StringBuilder s=new StringBuilder();for(byte v:m.digest())s.append(String.format(Locale.US,"%02x",v&255));return s.toString();}
  void startUnity(){runOnUiThread(()->{try{android.content.Intent i=new android.content.Intent();i.setClassName(getPackageName(),"com.prime31.UnityPlayerNativeActivity");i.addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP);startActivity(i);finish();}catch(Throwable t){status.setText("Unity launch failed");detail.setText(t.toString());}});}
  void setButtons(boolean enabled){runOnUiThread(()->{if(repair!=null)repair.setEnabled(enabled);if(recheck!=null)recheck.setEnabled(enabled);});}
  void ui(String s,int p,String d,boolean allow){runOnUiThread(()->{status.setText(s);progress.setProgress(Math.max(0,Math.min(1000,p)));detail.setText(d);launch.setEnabled(allow);});}
  static String human(long n){double v=n;String[]u={"B","KiB","MiB","GiB"};int i=0;while(v>=1024&&i<u.length-1){v/=1024;i++;}return String.format(Locale.US,"%.2f %s",v,u[i]);}
  static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException ignored){}}
  int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
