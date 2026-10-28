package com.CarXTech.CarXDriftRacingFull;

import android.app.*;
import android.content.*;
import android.database.Cursor;
import android.graphics.Typeface;
import android.net.*;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.security.MessageDigest;
import java.util.*;

public class B extends Activity {
  static final String OBB="main.279.com.CarXTech.CarXDriftRacingFull.obb";
  static final long REPACK_BYTES=510792679L;
  static final String REPACK_SHA="508171d4460da67201981fa8c1c00159dca9d2d604656af4b267181ca0f5e945";
  static final String EXPECTED_SHA="7f561c6cfcb71b19ff38001f5754bbc5c2acc6239bbeecb3967f04d1b7b52c34";
  static final int PICK_PARTS=77;
  TextView status,detail; ProgressBar progress; Button pick,launch,recheck;
  volatile boolean busy=false;

  static class Item { Uri uri; String name; long size; Item(Uri u,String n,long s){uri=u;name=n;size=s;} }

  public void onCreate(Bundle b){super.onCreate(b);build();check(false);}

  void build(){
    ScrollView sc=new ScrollView(this);LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),dp(18));sc.addView(root);
    TextView title=new TextView(this);title.setText("CarX Fusion OBB Repair");title.setTextSize(24);title.setTypeface(null,Typeface.BOLD);root.addView(title);
    TextView sub=new TextView(this);sub.setText("Select all seven Dropbox OBB parts (part00 through part06). This app rebuilds the real OBB inside CarX's own OBB folder, verifies it, then starts Unity.");root.addView(sub);
    status=new TextView(this);status.setTypeface(null,Typeface.BOLD);status.setTextSize(17);status.setPadding(0,dp(12),0,dp(6));root.addView(status);
    progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(10)));
    detail=new TextView(this);detail.setTypeface(Typeface.MONOSPACE);detail.setTextSize(12);detail.setTextIsSelectable(true);root.addView(detail);
    pick=new Button(this);pick.setAllCaps(false);pick.setText("Select part00 – part06 from Dropbox");pick.setOnClickListener(v->pickParts());root.addView(pick);
    recheck=new Button(this);recheck.setAllCaps(false);recheck.setText("Recheck installed OBB");recheck.setOnClickListener(v->check(false));root.addView(recheck);
    launch=new Button(this);launch.setAllCaps(false);launch.setText("Launch CarX");launch.setEnabled(false);launch.setOnClickListener(v->startUnity());root.addView(launch);
    TextView note=new TextView(this);note.setText("Required final identity: 510,792,679 bytes\nSHA-256: 508171d4460da67201981fa8c1c00159dca9d2d604656af4b267181ca0f5e945");root.addView(note);
    setContentView(sc);
  }

  File obb(){File d=getObbDir();if(d!=null&&!d.exists())d.mkdirs();return new File(d,OBB);}

  void pickParts(){if(busy)return;Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.addCategory(Intent.CATEGORY_OPENABLE);i.setType("*/*");i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);startActivityForResult(i,PICK_PARTS);}

  protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request!=PICK_PARTS||result!=RESULT_OK||data==null)return;ArrayList<Uri> uris=new ArrayList<>();ClipData c=data.getClipData();if(c!=null){for(int i=0;i<c.getItemCount();i++)uris.add(c.getItemAt(i).getUri());}else if(data.getData()!=null)uris.add(data.getData());if(!uris.isEmpty())assemble(uris);}

  void assemble(ArrayList<Uri> uris){if(busy)return;busy=true;setButtons(false);new Thread(()->{File dest=obb(),stage=new File(dest.getAbsolutePath()+".parts.tmp");try{
    ArrayList<Item> items=new ArrayList<>();for(Uri u:uris){items.add(new Item(u,displayName(u),displaySize(u)));}
    Collections.sort(items,(a,b)->a.name.compareToIgnoreCase(b.name));
    if(items.size()!=7)throw new IOException("Select exactly seven files: part00 through part06. Selected="+items.size());
    long expectedParts=0;StringBuilder names=new StringBuilder();for(int i=0;i<7;i++){String suffix=String.format(Locale.US,".part%02d",i);Item it=items.get(i);if(!it.name.toLowerCase(Locale.US).endsWith(suffix))throw new IOException("Missing or out-of-order "+suffix+". Found: "+it.name);if(it.size>0)expectedParts+=it.size;names.append(it.name).append("  ").append(human(it.size)).append("\n");}
    if(stage.exists()&&!stage.delete())throw new IOException("Could not reset staging file");ui("Combining seven OBB parts…",0,names.toString(),false);
    long done=0,total=expectedParts>0?expectedParts:REPACK_BYTES;try(OutputStream out=new BufferedOutputStream(new FileOutputStream(stage),262144)){byte[] buf=new byte[262144];for(int idx=0;idx<7;idx++){Item it=items.get(idx);try(InputStream in=new BufferedInputStream(getContentResolver().openInputStream(it.uri),262144)){if(in==null)throw new IOException("Could not open "+it.name);int n;long last=0;while((n=in.read(buf))>=0){if(n==0)continue;out.write(buf,0,n);done+=n;long now=System.currentTimeMillis();if(now-last>250){last=now;ui("Combining part"+String.format(Locale.US,"%02d",idx),permille(done,total),human(done)+" / "+human(total),false);}}}}out.flush();}
    if(stage.length()!=REPACK_BYTES)throw new IOException("Combined size mismatch: "+stage.length()+" expected "+REPACK_BYTES);
    ui("Verifying rebuilt OBB…",980,human(stage.length()),false);String h=sha(stage);if(!REPACK_SHA.equalsIgnoreCase(h))throw new IOException("Combined SHA-256 mismatch\nexpected "+REPACK_SHA+"\ngot "+h);
    if(dest.exists()&&!dest.delete())throw new IOException("Could not replace existing OBB");if(!stage.renameTo(dest))throw new IOException("Could not install rebuilt OBB");
    ui("OBB installed and verified",1000,"Path:\n"+dest.getAbsolutePath()+"\nbytes="+dest.length()+"\nSHA256="+h,true);sleep(700);startUnity();
  }catch(Throwable t){stage.delete();ui("OBB rebuild failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void check(boolean auto){if(busy)return;busy=true;setButtons(false);new Thread(()->{try{File f=obb();if(!f.exists()){ui("OBB missing",0,"Expected path:\n"+f.getAbsolutePath()+"\nSelect the seven Dropbox parts above.",false);return;}ui("Hashing installed OBB…",80,human(f.length()),false);String h=sha(f);if(REPACK_SHA.equalsIgnoreCase(h)){ui("OBB verified",1000,"bytes="+f.length()+"\nSHA256="+h,true);if(auto){sleep(350);startUnity();}}else if(EXPECTED_SHA.equalsIgnoreCase(h)){ui("Authoritative OBB verified",1000,"bytes="+f.length()+"\nSHA256="+h,true);if(auto){sleep(350);startUnity();}}else ui("Installed OBB mismatch",0,"bytes="+f.length()+"\nSHA256="+h,false);}catch(Throwable t){ui("OBB check failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  String displayName(Uri u){String n="selected";try(Cursor c=getContentResolver().query(u,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(c!=null&&c.moveToFirst()){int i=c.getColumnIndex(OpenableColumns.DISPLAY_NAME);if(i>=0&&!c.isNull(i))n=c.getString(i);}}catch(Throwable ignored){}return n==null?"selected":n;}
  long displaySize(Uri u){try(Cursor c=getContentResolver().query(u,new String[]{OpenableColumns.SIZE},null,null,null)){if(c!=null&&c.moveToFirst()){int i=c.getColumnIndex(OpenableColumns.SIZE);if(i>=0&&!c.isNull(i))return c.getLong(i);}}catch(Throwable ignored){}return -1;}
  void startUnity(){runOnUiThread(()->{try{Intent i=new Intent();i.setClassName(getPackageName(),"com.prime31.UnityPlayerNativeActivity");i.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP);startActivity(i);finish();}catch(Throwable t){status.setText("Unity launch failed");detail.setText(t.toString());}});}
  void setButtons(boolean enabled){runOnUiThread(()->{if(pick!=null)pick.setEnabled(enabled);if(recheck!=null)recheck.setEnabled(enabled);});}
  void ui(String s,int p,String d,boolean allow){runOnUiThread(()->{status.setText(s);progress.setProgress(Math.max(0,Math.min(1000,p)));detail.setText(d);launch.setEnabled(allow);});}
  static int permille(long a,long b){return b<=0?0:(int)Math.max(0,Math.min(1000,(a*1000L)/b));}
  static String sha(File f)throws Exception{MessageDigest m=MessageDigest.getInstance("SHA-256");try(InputStream in=new BufferedInputStream(new FileInputStream(f),262144)){byte[] b=new byte[262144];int n;while((n=in.read(b))>0)m.update(b,0,n);}StringBuilder s=new StringBuilder();for(byte v:m.digest())s.append(String.format(Locale.US,"%02x",v&255));return s.toString();}
  static String human(long n){if(n<0)return "unknown";double v=n;String[]u={"B","KiB","MiB","GiB"};int i=0;while(v>=1024&&i<u.length-1){v/=1024;i++;}return String.format(Locale.US,"%.2f %s",v,u[i]);}
  static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException ignored){}}
  int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
