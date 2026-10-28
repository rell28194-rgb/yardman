package com.carxfusion.diagnostics;

import android.app.*;
import android.content.*;
import android.content.pm.*;
import android.database.Cursor;
import android.graphics.Typeface;
import android.net.*;
import android.os.*;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.view.View;
import android.widget.*;
import java.io.*;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.zip.*;

public class MainActivity extends Activity {
  static final String PKG="com.CarXTech.CarXDriftRacingFull";
  static final String OBB="main.279.com.CarXTech.CarXDriftRacingFull.obb";
  static final String APK15="f7bf250d1128a9e51b15def526bc3ae45f8a79ba70ed61a95285aea35faf7999";
  static final String OBB15="7f561c6cfcb71b19ff38001f5754bbc5c2acc6239bbeecb3967f04d1b7b52c34";
  static final String BADAPK="9e29114e6bf5d511676fb0435e1f5238be0f63364f22def9efc2f39762ea8a44";
  static final String BADOBB="5e16bba9b414f281db0ed664c4d14a5dff2b82e282125ee0657e21652589f751";
  static final int PICK=10, SAVE=11;
  TextView out,status; ProgressBar bar; String report="";

  public void onCreate(Bundle b){super.onCreate(b);setContentView(ui());runChecks();}
  View ui(){
    LinearLayout r=new LinearLayout(this);r.setOrientation(LinearLayout.VERTICAL);r.setPadding(dp(16),dp(16),dp(16),dp(16));
    TextView t=new TextView(this);t.setText("CarX Fusion Diagnostics");t.setTextSize(24);t.setTypeface(null,Typeface.BOLD);r.addView(t);
    TextView s=new TextView(this);s.setText("Read-only checks for the CarX black loading screen / content mismatch.");r.addView(s);
    status=new TextView(this);status.setTypeface(null,Typeface.BOLD);status.setPadding(0,dp(8),0,dp(6));r.addView(status);
    bar=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);bar.setIndeterminate(true);bar.setVisibility(View.GONE);r.addView(bar,new LinearLayout.LayoutParams(-1,dp(6)));
    btn(r,"Run diagnostics",v->runChecks());btn(r,"Analyze OBB / XAPK / APK",v->pick());btn(r,"Launch CarX",v->launchCarX());btn(r,"CarX app settings",v->settings());btn(r,"Copy report",v->copy());btn(r,"Export report",v->save());
    out=new TextView(this);out.setTypeface(Typeface.MONOSPACE);out.setTextSize(12);out.setTextIsSelectable(true);ScrollView sc=new ScrollView(this);sc.addView(out);r.addView(sc,new LinearLayout.LayoutParams(-1,0,1));return r;
  }
  void btn(LinearLayout r,String s,View.OnClickListener l){Button b=new Button(this);b.setText(s);b.setAllCaps(false);b.setOnClickListener(l);r.addView(b);}

  void runChecks(){status.setText("Running…");bar.setVisibility(View.VISIBLE);new Thread(()->{
    StringBuilder x=new StringBuilder();List<String> bad=new ArrayList<>(),warn=new ArrayList<>();
    ln(x,"CARX FUSION DIAGNOSTIC REPORT");ln(x,"UTC: "+utc());ln(x,"");
    ln(x,"== DEVICE ==");ln(x,"Android "+Build.VERSION.RELEASE+" API "+Build.VERSION.SDK_INT);ln(x,"Model: "+Build.MANUFACTURER+" "+Build.MODEL);ln(x,"ABIs: "+Arrays.toString(Build.SUPPORTED_ABIS));
    boolean a32=has(Build.SUPPORTED_ABIS,"armeabi-v7a");ln(x,(a32?"PASS":"FAIL")+": armeabi-v7a support="+a32);if(!a32)bad.add("Device lacks armeabi-v7a");
    ln(x,"");ln(x,"== STORAGE ==");storage(x,"data",Environment.getDataDirectory());storage(x,"shared",Environment.getExternalStorageDirectory());
    ln(x,"");ln(x,"== NETWORK ==");network(x,warn);
    ln(x,"");ln(x,"== CARX INSTALL ==");pkg(x,bad,warn);
    ln(x,"");ln(x,"== BETA 0.15 IDENTITY ==");ln(x,"authoritative APK="+APK15);ln(x,"authoritative OBB="+OBB15);ln(x,"black-screen ARM APK="+BADAPK);ln(x,"black-screen ARM OBB="+BADOBB);ln(x,"FAIL: saved black-screen ARM package identities differ from authoritative 0.15.");bad.add("Recorded Beta-0.15-ARM package is not the authoritative APK/OBB pair");
    File f=new File(Environment.getExternalStorageDirectory(),"Android/obb/"+PKG+"/"+OBB);ln(x,"");ln(x,"== OBB PATH PROBE ==");ln(x,f.getAbsolutePath());ln(x,"exists="+f.exists()+" readable="+f.canRead()+" bytes="+f.length());if(!f.canRead())warn.add("Direct OBB access blocked/missing; select OBB or XAPK manually");
    ln(x,"");ln(x,"== SUMMARY ==");for(String q:bad)ln(x,"FATAL: "+q);for(String q:warn)ln(x,"WARN: "+q);ln(x,"NEXT: tap Analyze OBB / XAPK / APK and select the exact file you installed.");
    report=x.toString();runOnUiThread(()->{out.setText(report);bar.setVisibility(View.GONE);status.setText(bad.isEmpty()?"Checks complete":"Problem/mismatch detected");});
  }).start();}

  void storage(StringBuilder x,String n,File f){try{StatFs s=new StatFs(f.getAbsolutePath());ln(x,n+": free="+human(s.getAvailableBytes())+" total="+human(s.getTotalBytes()));}catch(Throwable t){ln(x,n+": ERROR "+t);}}
  void network(StringBuilder x,List<String>w){try{ConnectivityManager c=(ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE);Network n=c.getActiveNetwork();NetworkCapabilities z=n==null?null:c.getNetworkCapabilities(n);boolean on=z!=null,wifi=on&&z.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),valid=on&&z.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),free=on&&z.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);ln(x,"connected="+on+" wifi="+wifi+" validated="+valid+" unmetered="+free);if(!wifi)w.add("Not on Wi-Fi");if(!valid)w.add("Internet not validated");}catch(Throwable t){ln(x,"network ERROR "+t);}}
  void pkg(StringBuilder x,List<String>b,List<String>w){try{PackageManager pm=getPackageManager();PackageInfo p=Build.VERSION.SDK_INT>=33?pm.getPackageInfo(PKG,PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES)):pm.getPackageInfo(PKG,PackageManager.GET_SIGNING_CERTIFICATES);ApplicationInfo a=p.applicationInfo;ln(x,"installed=yes version="+p.versionName+" code="+(Build.VERSION.SDK_INT>=28?p.getLongVersionCode():p.versionCode)+" targetSdk="+a.targetSdkVersion);ln(x,"sourceDir="+a.sourceDir);ln(x,"certSHA256="+cert(p));try{File q=new File(a.sourceDir);if(q.canRead()){String h=hash(new FileInputStream(q));ln(x,"installed APK SHA256="+h);if(APK15.equalsIgnoreCase(h))ln(x,"PASS: authoritative Beta 0.15 APK installed");else if(BADAPK.equalsIgnoreCase(h)){ln(x,"FAIL: black-screen ARM APK installed");b.add("Installed APK matches black-screen ARM variant");}else w.add("Installed APK hash is unknown");}else ln(x,"installed base APK not readable");}catch(Throwable t){ln(x,"APK hash ERROR "+t);}}catch(PackageManager.NameNotFoundException e){ln(x,"installed=NO");b.add("CarX package not installed");}catch(Throwable t){ln(x,"package ERROR "+t);w.add("Package inspection failed");}}

  void pick(){Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.addCategory(Intent.CATEGORY_OPENABLE);i.setType("*/*");startActivityForResult(i,PICK);}
  protected void onActivityResult(int r,int c,Intent d){super.onActivityResult(r,c,d);if(r==PICK&&c==RESULT_OK&&d!=null&&d.getData()!=null)analyze(d.getData());else if(r==SAVE&&c==RESULT_OK&&d!=null&&d.getData()!=null)write(d.getData());}
  void analyze(Uri u){bar.setVisibility(View.VISIBLE);status.setText("Analyzing file…");new Thread(()->{StringBuilder x=new StringBuilder();ln(x,"");ln(x,"== SELECTED FILE ==");String n=name(u);ln(x,"name="+n);try{String h=hash(getContentResolver().openInputStream(u));ln(x,"SHA256="+h);classify(x,h,"whole file");}catch(Throwable t){ln(x,"hash ERROR "+t);}String l=n.toLowerCase(Locale.US);if(l.endsWith(".xapk")||l.endsWith(".obb")||l.endsWith(".zip"))zip(x,u);String a=x.toString();report+=a;runOnUiThread(()->{out.setText(report);bar.setVisibility(View.GONE);status.setText("File analysis complete");});}).start();}
  void zip(StringBuilder x,Uri u){int count=0;try(InputStream raw=getContentResolver().openInputStream(u);ZipInputStream z=new ZipInputStream(new BufferedInputStream(raw,262144))){ZipEntry e;byte[]buf=new byte[262144];while((e=z.getNextEntry())!=null){count++;String n=e.getName();boolean target=n.endsWith(".apk")||n.endsWith(".obb");MessageDigest md=target?MessageDigest.getInstance("SHA-256"):null;long bytes=0;int k;while((k=z.read(buf))>0){if(md!=null)md.update(buf,0,k);bytes+=k;}if(md!=null){String h=hex(md.digest());ln(x,"member="+n+" bytes="+bytes+" SHA256="+h);classify(x,h,n);}z.closeEntry();}ln(x,"ZIP stream PASS entries="+count);}catch(Throwable t){ln(x,"ZIP stream FAIL after "+count+" entries: "+t);}}
  void classify(StringBuilder x,String h,String n){if(APK15.equalsIgnoreCase(h))ln(x,"MATCH: authoritative Beta 0.15 APK ("+n+")");if(OBB15.equalsIgnoreCase(h))ln(x,"MATCH: authoritative Beta 0.15 OBB ("+n+")");if(BADAPK.equalsIgnoreCase(h))ln(x,"MATCH/PROBLEM: black-screen ARM APK ("+n+")");if(BADOBB.equalsIgnoreCase(h))ln(x,"MATCH/PROBLEM: black-screen ARM OBB ("+n+")");}

  void launchCarX(){Intent i=getPackageManager().getLaunchIntentForPackage(PKG);if(i==null)Toast.makeText(this,"CarX not installed",Toast.LENGTH_LONG).show();else startActivity(i);}
  void settings(){try{startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:"+PKG)));}catch(Throwable t){Toast.makeText(this,t.toString(),Toast.LENGTH_LONG).show();}}
  void copy(){((ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("CarX Fusion diagnostics",report));Toast.makeText(this,"Report copied",Toast.LENGTH_SHORT).show();}
  void save(){Intent i=new Intent(Intent.ACTION_CREATE_DOCUMENT);i.addCategory(Intent.CATEGORY_OPENABLE);i.setType("text/plain");i.putExtra(Intent.EXTRA_TITLE,"carx-fusion-diagnostic.txt");startActivityForResult(i,SAVE);}
  void write(Uri u){try(OutputStream o=getContentResolver().openOutputStream(u,"wt")){o.write(report.getBytes(java.nio.charset.StandardCharsets.UTF_8));Toast.makeText(this,"Report exported",Toast.LENGTH_LONG).show();}catch(Throwable t){Toast.makeText(this,"Export failed: "+t,Toast.LENGTH_LONG).show();}}
  String name(Uri u){String n=u.getLastPathSegment();try(Cursor c=getContentResolver().query(u,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(c!=null&&c.moveToFirst()){int i=c.getColumnIndex(OpenableColumns.DISPLAY_NAME);if(i>=0)n=c.getString(i);}}catch(Throwable ignored){}return n==null?"selected-file":n;}

  static String cert(PackageInfo p)throws Exception{android.content.pm.Signature[]s;if(Build.VERSION.SDK_INT>=28&&p.signingInfo!=null)s=p.signingInfo.hasMultipleSigners()?p.signingInfo.getApkContentsSigners():p.signingInfo.getSigningCertificateHistory();else s=p.signatures;return s==null||s.length==0?"unavailable":hex(MessageDigest.getInstance("SHA-256").digest(s[0].toByteArray()));}
  static String hash(InputStream i)throws Exception{if(i==null)throw new IOException("null stream");try(InputStream q=new BufferedInputStream(i,262144)){MessageDigest m=MessageDigest.getInstance("SHA-256");byte[]b=new byte[262144];int n;while((n=q.read(b))>0)m.update(b,0,n);return hex(m.digest());}}
  static String hex(byte[]b){StringBuilder s=new StringBuilder();for(byte v:b)s.append(String.format(Locale.US,"%02x",v&255));return s.toString();}
  static boolean has(String[]a,String v){for(String s:a)if(v.equals(s))return true;return false;}
  static void ln(StringBuilder b,String s){b.append(s).append('\n');}
  static String human(long n){double v=n;String[]u={"B","KiB","MiB","GiB"};int i=0;while(v>=1024&&i<u.length-1){v/=1024;i++;}return String.format(Locale.US,"%.2f %s",v,u[i]);}
  static String utc(){SimpleDateFormat f=new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'",Locale.US);f.setTimeZone(TimeZone.getTimeZone("UTC"));return f.format(new Date());}
  int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
}
