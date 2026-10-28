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
import java.util.zip.*;

public class B extends Activity {
  static final String OBB="main.279.com.CarXTech.CarXDriftRacingFull.obb";
  static final String SEED="carx_seed.obb";
  static final long EXPECTED_BYTES=512584504L;
  static final long SEED_BYTES=510792679L;
  static final String EXPECTED_SHA="7f561c6cfcb71b19ff38001f5754bbc5c2acc6239bbeecb3967f04d1b7b52c34";
  static final String REPACK_SHA="508171d4460da67201981fa8c1c00159dca9d2d604656af4b267181ca0f5e945";
  static final String BLACK_SHA="5e16bba9b414f281db0ed664c4d14a5dff2b82e282125ee0657e21652589f751";
  static final int PICK_CONTENT=77;
  TextView status,detail; EditText url; ProgressBar progress; Button download,launch,importBtn;
  volatile boolean busy=false;

  public void onCreate(Bundle b){super.onCreate(b);build();seedOrCheck();}

  void build(){
    LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),dp(18));
    TextView title=new TextView(this);title.setText("CarX Fusion Content Repair");title.setTextSize(24);title.setTypeface(null,Typeface.BOLD);root.addView(title);
    TextView sub=new TextView(this);sub.setText("This build carries a complete seeded expansion container. It installs the OBB before Unity starts, so the game never launches with zero expansion bytes.");root.addView(sub);
    status=new TextView(this);status.setTypeface(null,Typeface.BOLD);status.setTextSize(17);status.setPadding(0,dp(12),0,dp(6));root.addView(status);
    progress=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(10)));
    detail=new TextView(this);detail.setTypeface(Typeface.MONOSPACE);detail.setTextSize(12);detail.setTextIsSelectable(true);root.addView(detail);
    importBtn=new Button(this);importBtn.setAllCaps(false);importBtn.setText("Import OBB / XAPK from this device");importBtn.setOnClickListener(v->pickContent());root.addView(importBtn);
    url=new EditText(this);url.setHint("HTTPS content URL for future Wi-Fi packs");url.setSingleLine(true);url.setText(getPreferences(MODE_PRIVATE).getString("url",""));root.addView(url);
    download=new Button(this);download.setAllCaps(false);download.setText("Download / repair over Wi-Fi");download.setOnClickListener(v->download());root.addView(download);
    Button recheck=new Button(this);recheck.setAllCaps(false);recheck.setText("Recheck installed content");recheck.setOnClickListener(v->check(false));root.addView(recheck);
    launch=new Button(this);launch.setAllCaps(false);launch.setText("Launch game");launch.setEnabled(false);launch.setOnClickListener(v->startUnity());root.addView(launch);
    TextView note=new TextView(this);note.setText("Seed identity: 510,792,679 bytes / SHA-256 508171d4…; 6,126-entry container, with the critical Beta 0.15 Highway scene chunks already matched against the checkpoint.");root.addView(note);
    setContentView(root);
  }

  File obb(){File d=getObbDir();if(d!=null&&!d.exists())d.mkdirs();return new File(d,OBB);}

  void seedOrCheck(){if(busy)return;busy=true;setButtons(false);new Thread(()->{File dest=obb(),stage=new File(dest.getAbsolutePath()+".seed.part");try{
    if(dest.exists()&&dest.length()>0){ui("Existing content found",50,"Checking installed OBB before replacing it…",false);String h=sha(dest);if(EXPECTED_SHA.equalsIgnoreCase(h)||REPACK_SHA.equalsIgnoreCase(h)){showIdentity(dest,h,true);return;}}
    if(stage.exists()&&!stage.delete())throw new IOException("Could not reset seed staging file");
    ui("Installing bundled CarX content…",0,"Writing expansion data to:\n"+dest.getAbsolutePath(),false);
    try(InputStream in=new BufferedInputStream(getAssets().open(SEED),262144);OutputStream out=new BufferedOutputStream(new FileOutputStream(stage),262144)){copy(in,out,SEED_BYTES,"Installing bundled expansion");}
    if(stage.length()!=SEED_BYTES)throw new IOException("Seed byte count mismatch: "+stage.length()+" expected "+SEED_BYTES);
    ui("Verifying bundled content…",980,human(stage.length()),false);String h=sha(stage);if(!REPACK_SHA.equalsIgnoreCase(h))throw new IOException("Seed SHA-256 mismatch\nexpected "+REPACK_SHA+"\ngot "+h);
    if(dest.exists()&&!dest.delete())throw new IOException("Could not replace old OBB");if(!stage.renameTo(dest))throw new IOException("Could not commit bundled OBB");
    ui("Bundled content installed",1000,"bytes="+dest.length()+"\nSHA256="+h+"\nStarting Unity with a real OBB present.",true);sleep(700);startUnity();
  }catch(Throwable t){stage.delete();ui("Bundled content install failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void check(boolean ignored){if(busy)return;busy=true;setButtons(false);ui("Checking content…",0,"",false);new Thread(()->{try{File f=obb();if(!f.exists()){ui("Content missing",0,"Expected:\n"+f.getAbsolutePath(),false);return;}String h=sha(f);showIdentity(f,h,false);}catch(Throwable t){ui("Content check failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void showIdentity(File f,String h,boolean auto){StringBuilder d=new StringBuilder();d.append("bytes=").append(f.length()).append("\nSHA256=").append(h).append("\n");
    if(EXPECTED_SHA.equalsIgnoreCase(h)){d.append("MATCH: authoritative Beta 0.15 container");ui("Content verified",1000,d.toString(),true);if(auto){sleep(350);startUnity();}}
    else if(REPACK_SHA.equalsIgnoreCase(h)){d.append("MATCH: seeded 6,126-entry Beta 0.15 repack");ui("Seeded content verified",1000,d.toString(),true);if(auto){sleep(350);startUnity();}}
    else if(BLACK_SHA.equalsIgnoreCase(h)){d.append("FAIL: known black-screen OBB");ui("Known bad content detected",0,d.toString(),false);}
    else {d.append("FAIL: unknown expansion payload");ui("Content mismatch",0,d.toString(),false);}
  }

  void pickContent(){if(busy)return;Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.addCategory(Intent.CATEGORY_OPENABLE);i.setType("*/*");startActivityForResult(i,PICK_CONTENT);}
  protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==PICK_CONTENT&&result==RESULT_OK&&data!=null&&data.getData()!=null)importContent(data.getData());}
  void importContent(Uri uri){if(busy)return;busy=true;setButtons(false);ui("Opening selected content…",0,"",false);new Thread(()->{File dest=obb(),stage=new File(dest.getAbsolutePath()+".import.part");try{
    if(stage.exists()&&!stage.delete())throw new IOException("Could not reset import staging file");String n=displayName(uri);long sourceSize=displaySize(uri);String low=n.toLowerCase(Locale.US);
    if(low.endsWith(".xapk")||low.endsWith(".zip")){
      boolean found=false;try(InputStream raw=getContentResolver().openInputStream(uri);ZipInputStream zin=new ZipInputStream(new BufferedInputStream(raw,262144))){ZipEntry e;while((e=zin.getNextEntry())!=null){if(!e.isDirectory()&&e.getName().toLowerCase(Locale.US).endsWith(".obb")){found=true;ui("Extracting OBB from "+n,50,e.getName(),false);try(OutputStream out=new BufferedOutputStream(new FileOutputStream(stage),262144)){copy(zin,out,e.getSize(),"Extracting expansion content");}break;}zin.closeEntry();}}
      if(!found)throw new IOException("Selected archive contains no OBB payload. This is the exact 0.15 ARM packaging failure shown in the device recording; use the bundled seed instead.");
    } else {try(InputStream in=getContentResolver().openInputStream(uri);OutputStream out=new BufferedOutputStream(new FileOutputStream(stage),262144)){copy(in,out,sourceSize,"Importing expansion content");}}
    String h=sha(stage);if(EXPECTED_SHA.equalsIgnoreCase(h)||REPACK_SHA.equalsIgnoreCase(h)){if(dest.exists()&&!dest.delete())throw new IOException("Could not replace old OBB");if(!stage.renameTo(dest))throw new IOException("Could not commit imported OBB");showIdentity(dest,h,false);}else{long bytes=stage.length();stage.delete();ui("Import rejected",0,"Unrecognized payload\nbytes="+bytes+"\nSHA256="+h,false);}
  }catch(Throwable t){stage.delete();ui("Import failed",0,t.toString(),false);}finally{busy=false;setButtons(true);}}).start();}

  void download(){if(busy)return;String u=url.getText().toString().trim();if(!(u.startsWith("https://")||u.startsWith("http://"))){Toast.makeText(this,"Enter a valid HTTPS content URL",Toast.LENGTH_LONG).show();return;}getPreferences(MODE_PRIVATE).edit().putString("url",u).apply();if(!wifi()){Toast.makeText(this,"Wi-Fi is required for automatic content download",Toast.LENGTH_LONG).show();return;}busy=true;setButtons(false);new Thread(()->{File dest=obb(),part=new File(dest.getAbsolutePath()+".part");try{
    long have=part.exists()?part.length():0;ui("Connecting…",permille(have,EXPECTED_BYTES),"Resuming at "+human(have),false);HttpURLConnection c=(HttpURLConnection)new URL(u).openConnection();c.setConnectTimeout(20000);c.setReadTimeout(30000);c.setInstanceFollowRedirects(true);c.setRequestProperty("Accept-Encoding","identity");if(have>0)c.setRequestProperty("Range","bytes="+have+"-");c.connect();int code=c.getResponseCode();
    if(have>0&&code!=206){have=0;if(part.exists()&&!part.delete())throw new IOException("Could not reset partial file");c.disconnect();c=(HttpURLConnection)new URL(u).openConnection();c.setConnectTimeout(20000);c.setReadTimeout(30000);c.setInstanceFollowRedirects(true);c.setRequestProperty("Accept-Encoding","identity");c.connect();code=c.getResponseCode();}if(code<200||code>=300)throw new IOException("HTTP "+code);
    long incoming=c.getContentLengthLong();long total=incoming>0?have+incoming:EXPECTED_BYTES;try(InputStream in=new BufferedInputStream(c.getInputStream(),262144);RandomAccessFile out=new RandomAccessFile(part,"rw")){out.seek(have);byte[]buf=new byte[262144];int n;long got=have,last=0;while((n=in.read(buf))>=0){if(n==0)continue;out.write(buf,0,n);got+=n;long now=System.currentTimeMillis();if(now-last>300){last=now;ui("Downloading over Wi-Fi",permille(got,total),human(got)+" / "+human(total),false);}}out.getFD().sync();}
    String h=sha(part);if(!EXPECTED_SHA.equalsIgnoreCase(h)&&!REPACK_SHA.equalsIgnoreCase(h))throw new IOException("SHA-256 mismatch\ngot "+h);if(dest.exists()&&!dest.delete())throw new IOException("Could not replace old content");if(!part.renameTo(dest))throw new IOException("Atomic rename failed");showIdentity(dest,h,false);
  }catch(Throwable t){ui("Download/repair failed",0,t.toString()+"\nPartial download is kept for resume.",false);}finally{busy=false;setButtons(true);}}).start();}

  void copy(InputStream in,OutputStream out,long total,String label)throws IOException{if(in==null)throw new IOException("Could not open source");byte[]buf=new byte[262144];long got=0,last=0;int n;while((n=in.read(buf))>=0){if(n==0)continue;out.write(buf,0,n);got+=n;long now=System.currentTimeMillis();if(now-last>300){last=now;ui(label,permille(got,total>0?total:SEED_BYTES),human(got)+(total>0?" / "+human(total):""),false);}}out.flush();}
  String displayName(Uri u){String n="selected-content";try(Cursor c=getContentResolver().query(u,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(c!=null&&c.moveToFirst()){int i=c.getColumnIndex(OpenableColumns.DISPLAY_NAME);if(i>=0)n=c.getString(i);}}catch(Throwable ignored){}return n==null?"selected-content":n;}
  long displaySize(Uri u){try(Cursor c=getContentResolver().query(u,new String[]{OpenableColumns.SIZE},null,null,null)){if(c!=null&&c.moveToFirst()){int i=c.getColumnIndex(OpenableColumns.SIZE);if(i>=0&&!c.isNull(i))return c.getLong(i);}}catch(Throwable ignored){}return -1;}
  boolean wifi(){try{ConnectivityManager c=(ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE);Network n=c.getActiveNetwork();NetworkCapabilities k=n==null?null:c.getNetworkCapabilities(n);return k!=null&&k.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)&&k.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);}catch(Throwable t){return false;}}
  void startUnity(){runOnUiThread(()->{try{Intent i=new Intent();i.setClassName(getPackageName(),"com.prime31.UnityPlayerNativeActivity");i.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP);startActivity(i);finish();}catch(Throwable t){status.setText("Unity launch failed");detail.setText(t.toString());}});}
  void setButtons(boolean enabled){runOnUiThread(()->{if(download!=null)download.setEnabled(enabled);if(importBtn!=null)importBtn.setEnabled(enabled);});}
  void ui(String s,int p,String d,boolean allow){runOnUiThread(()->{status.setText(s);progress.setProgress(Math.max(0,Math.min(1000,p)));detail.setText(d);launch.setEnabled(allow);});}
  static int permille(long a,long b){return b<=0?0:(int)Math.max(0,Math.min(1000,(a*1000L)/b));}
  static String sha(File f)throws Exception{MessageDigest m=MessageDigest.getInstance("SHA-256");try(InputStream in=new BufferedInputStream(new FileInputStream(f),262144)){byte[]b=new byte[262144];int n;while((n=in.read(b))>0)m.update(b,0,n);}StringBuilder s=new StringBuilder();for(byte v:m.digest())s.append(String.format(Locale.US,"%02x",v&255));return s.toString();}
  static String human(long n){double v=n;String[]u={"B","KiB","MiB","GiB"};int i=0;while(v>=1024&&i<u.length-1){v/=1024;i++;}return String.format(Locale.US,"%.2f %s",v,u[i]);}
  static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException ignored){}}
  int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
