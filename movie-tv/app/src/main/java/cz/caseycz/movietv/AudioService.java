package cz.caseycz.movietv;
import android.app.*;
import android.content.*;
import android.graphics.*;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import com.google.mlkit.nl.translate.*;
import org.vosk.Model;
import org.vosk.Recognizer;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.util.zip.*;

public class AudioService extends Service {
 private final Handler main=new Handler(Looper.getMainLooper());
 private volatile boolean closed;
 private MediaProjection projection;
 private volatile AudioRecord record;
 private Translator translator;
 private WindowManager wm;
 private TextView overlay;
 private Thread worker;
 private long sequence;
 @Override public IBinder onBind(Intent i){return null;}
 @Override public int onStartCommand(Intent i,int flags,int id){
  if(i==null||worker!=null||projection!=null)return START_NOT_STICKY;
  NotificationManager nm=getSystemService(NotificationManager.class);
  nm.createNotificationChannel(new NotificationChannel("audio","Překlad zvuku",NotificationManager.IMPORTANCE_LOW));
  startForeground(2,new Notification.Builder(this,"audio").setSmallIcon(android.R.drawable.ic_btn_speak_now).setContentTitle("Překlad interního zvuku").setContentIntent(PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE)).build());
  try{
   wm=getSystemService(WindowManager.class);overlay=new TextView(this);overlay.setTextSize(24);overlay.setTextColor(Color.WHITE);overlay.setBackgroundColor(0xcc000000);overlay.setGravity(Gravity.CENTER);overlay.setPadding(20,8,20,8);
   WindowManager.LayoutParams p=new WindowManager.LayoutParams(-1,-2,WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,PixelFormat.TRANSLUCENT);p.gravity=Gravity.BOTTOM;p.y=40;wm.addView(overlay,p);
   projection=getSystemService(MediaProjectionManager.class).getMediaProjection(i.getIntExtra("result",0),(Intent)i.getParcelableExtra("permission"));
   projection.registerCallback(new MediaProjection.Callback(){@Override public void onStop(){stopSelf();}},main);
   translator=Translation.getClient(new TranslatorOptions.Builder().setSourceLanguage(TranslateLanguage.ENGLISH).setTargetLanguage(TranslateLanguage.CZECH).build());
   show("Příprava jazykových modelů…");
   translator.downloadModelIfNeeded().addOnSuccessListener(v->{if(!closed){worker=new Thread(this::capture,"movie-audio");worker.start();}}).addOnFailureListener(e->fail("Model překladu není dostupný"));
  }catch(Exception e){fail("Interní zvuk nelze spustit");}
  return START_NOT_STICKY;
 }
 private File model() throws Exception{
  File root=new File(getFilesDir(),"vosk-en"),ready=new File(root,"vosk-model-small-en-us-0.15"),marker=new File(root,"ready");
  if(marker.isFile()&&new File(ready,"am/final.mdl").isFile())return ready;
  root.mkdirs();
  URLConnection connection=new URL("https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip").openConnection();connection.setConnectTimeout(15000);connection.setReadTimeout(15000);
  long total=0;
  try(ZipInputStream zip=new ZipInputStream(new BufferedInputStream(connection.getInputStream()))){
   ZipEntry entry;byte[] buffer=new byte[8192];String prefix=root.getCanonicalPath()+File.separator;
   while((entry=zip.getNextEntry())!=null){
    if(closed)throw new InterruptedIOException();
    File out=new File(root,entry.getName());if(!out.getCanonicalPath().startsWith(prefix))throw new IOException("Invalid model path");
    if(entry.isDirectory()){out.mkdirs();continue;}
    out.getParentFile().mkdirs();
    try(OutputStream stream=new FileOutputStream(out)){int n;while((n=zip.read(buffer))!=-1){if(closed)throw new InterruptedIOException();total+=n;if(total>250L*1024*1024)throw new IOException("Model too large");stream.write(buffer,0,n);}}
   }
  }
  if(!new File(ready,"am/final.mdl").isFile())throw new IOException("Incomplete model");
  marker.createNewFile();return ready;
 }
 private void capture(){
  AudioRecord local=null;
  try(Model m=new Model(model().getAbsolutePath());Recognizer recognizer=new Recognizer(m,16000f)){
   if(closed)return;
   AudioPlaybackCaptureConfiguration config=new AudioPlaybackCaptureConfiguration.Builder(projection).addMatchingUsage(AudioAttributes.USAGE_MEDIA).build();
   int min=AudioRecord.getMinBufferSize(16000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT);
   if(min<=0)throw new IOException("Unsupported audio format");
   local=new AudioRecord.Builder().setAudioPlaybackCaptureConfig(config).setAudioFormat(new AudioFormat.Builder().setSampleRate(16000).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()).setBufferSizeInBytes(Math.max(min,8192)).build();
   record=local;if(closed)return;
   local.startRecording();main.post(()->show("Čekám na interní zvuk…"));
   short[] buffer=new short[2048];long lastSignal=SystemClock.elapsedRealtime();boolean silent=false;
   while(!closed){
    int n=local.read(buffer,0,buffer.length);if(n<0)throw new IOException("Audio read failed");if(n==0)continue;
    boolean signal=false;for(int k=0;k<n;k++){if(Math.abs((int)buffer[k])>32){signal=true;break;}}
    if(signal){lastSignal=SystemClock.elapsedRealtime();if(silent){silent=false;main.post(()->show(""));}}
    else if(!silent&&SystemClock.elapsedRealtime()-lastSignal>12000){silent=true;main.post(()->{sequence++;show("Zvuk není dostupný nebo je ticho");});}
    if(recognizer.acceptWaveForm(buffer,n)){String source=new JSONObject(recognizer.getResult()).optString("text").trim();if(!source.isEmpty())main.post(()->translate(source));}
   }
  }catch(Exception|LinkageError e){if(!closed)main.post(()->fail("Zvuk nebo rozpoznávání není dostupné"));}
  finally{if(local!=null){try{local.stop();}catch(Exception ignored){}local.release();}record=null;}
 }
 private void translate(String source){
  if(closed)return;long current=++sequence;
  translator.translate(source).addOnSuccessListener(text->{if(!closed&&current==sequence){show(text);main.postDelayed(()->{if(!closed&&current==sequence)show("");},4500);}});
 }
 private void show(String text){if(!closed&&overlay!=null){overlay.setText(text);overlay.setVisibility(text.isEmpty()?View.GONE:View.VISIBLE);}}
 private void fail(String message){if(!closed){Toast.makeText(this,message,Toast.LENGTH_LONG).show();stopSelf();}}
 @Override public void onDestroy(){
  closed=true;main.removeCallbacksAndMessages(null);AudioRecord r=record;if(r!=null)try{r.stop();}catch(Exception ignored){}
  if(worker!=null)worker.interrupt();if(projection!=null)projection.stop();if(translator!=null)translator.close();if(overlay!=null&&wm!=null)wm.removeView(overlay);super.onDestroy();
 }
}
