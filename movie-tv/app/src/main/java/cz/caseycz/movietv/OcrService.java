package cz.caseycz.movietv;
import android.app.*;
import android.content.*;
import android.graphics.*;
import android.hardware.display.*;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.*;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;
import com.google.mlkit.nl.translate.*;

public class OcrService extends Service {
 private final Handler main=new Handler(Looper.getMainLooper());
 private MediaProjection projection; private VirtualDisplay display; private ImageReader reader;
 private TextRecognizer recognizer; private Translator translator; private WindowManager wm; private TextView overlay;
 private boolean busy,closed; private long lastFrame,lastText; private String previous=""; private SubtitleSettings settings; private final TranslationCache cache=new TranslationCache(); private long darkSince; private boolean darkWarning;
 private final Runnable expiry=new Runnable(){public void run(){if(closed)return;if(!darkWarning&&SystemClock.elapsedRealtime()-lastText>3500){previous="";show("");} main.postDelayed(this,500);}};
 @Override public IBinder onBind(Intent i){return null;}
 @Override public int onStartCommand(Intent i,int flags,int id){
  if(i==null||projection!=null)return START_NOT_STICKY;
  NotificationManager nm=getSystemService(NotificationManager.class);
  nm.createNotificationChannel(new NotificationChannel("ocr","Překlad titulků",NotificationManager.IMPORTANCE_LOW));
  PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE);
  startForeground(1,new Notification.Builder(this,"ocr").setSmallIcon(android.R.drawable.ic_menu_view).setContentTitle("OCR překlad aktivní").setContentIntent(open).build());
  try{
   settings=new SubtitleSettings(this);
   wm=getSystemService(WindowManager.class);
   overlay=new TextView(this); settings.style(overlay);
   WindowManager.LayoutParams p=new WindowManager.LayoutParams(-1,-2,WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE|WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE|WindowManager.LayoutParams.FLAG_SECURE,PixelFormat.TRANSLUCENT);
   // Output is opposite the input region to avoid reading our own translation.
   settings.place(p,true);wm.addView(overlay,p);
   show("Stahuji jazykový model…");
   recognizer=TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
   translator=Translation.getClient(new TranslatorOptions.Builder().setSourceLanguage(i.getStringExtra("language")).setTargetLanguage(TranslateLanguage.CZECH).build());
   projection=getSystemService(MediaProjectionManager.class).getMediaProjection(i.getIntExtra("result",0),(Intent)i.getParcelableExtra("permission"));
   projection.registerCallback(new MediaProjection.Callback(){@Override public void onStop(){stopSelf();}},main);
   translator.downloadModelIfNeeded().addOnSuccessListener(v->{if(!closed){show("");try{begin();main.post(expiry);}catch(Exception e){fail("Snímání nelze spustit");}}}).addOnFailureListener(e->fail("Jazykový model není dostupný"));
  }catch(Exception e){fail("Překlad nelze spustit");}
  return START_NOT_STICKY;
 }
 private void begin(){
  android.util.DisplayMetrics m=new android.util.DisplayMetrics();wm.getDefaultDisplay().getRealMetrics(m);
  int w=m.widthPixels,h=m.heightPixels;
  if(w>1920){h=Math.max(1,h*1920/w);w=1920;}
  final int captureWidth=w,captureHeight=h;
  reader=ImageReader.newInstance(w,h,PixelFormat.RGBA_8888,2);
  reader.setOnImageAvailableListener(r->frame(r,captureWidth,captureHeight),main);
  display=projection.createVirtualDisplay("MovieOCR",w,h,m.densityDpi,DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,reader.getSurface(),null,main);
 }
 private void frame(ImageReader r,int w,int h){
  Bitmap crop=null;
  try(Image image=r.acquireLatestImage()){
   if(image==null||closed||busy||SystemClock.elapsedRealtime()-lastFrame<700)return;
   lastFrame=SystemClock.elapsedRealtime();
   Image.Plane p=image.getPlanes()[0];int padded=p.getRowStride()/p.getPixelStride();
   Bitmap full=Bitmap.createBitmap(padded,h,Bitmap.Config.ARGB_8888);
   try{full.copyPixelsFromBuffer(p.getBuffer());Rect area=settings.region(w,h);crop=Bitmap.createBitmap(full,area.left,area.top,area.width(),area.height());if(crop==full)crop=full.copy(Bitmap.Config.ARGB_8888,false);}finally{full.recycle();}
  }catch(Exception e){return;}
  if(crop==null)return;
  long now=SystemClock.elapsedRealtime();
  if(isDark(crop)){
   crop.recycle();if(darkSince==0)darkSince=now;
   if(now-darkSince>8000&&!darkWarning){darkWarning=true;previous="";show("Oblast OCR je tmavá nebo není dostupná");}
   return;
  }
  darkSince=0;if(darkWarning){darkWarning=false;show("");}
  final Bitmap input=crop;busy=true;
  recognizer.process(InputImage.fromBitmap(input,0)).addOnCompleteListener(task->{
   input.recycle();if(closed)return;
   if(!task.isSuccessful()){busy=false;return;}
   String source=TranslationCache.normalize(task.getResult().getText());
   if(source.isEmpty()){busy=false;return;}
   lastText=SystemClock.elapsedRealtime();
   if(source.equals(previous)){busy=false;return;}
   String cached=cache.get(source);if(cached!=null){previous=source;show(cached);busy=false;return;}
   translator.translate(source).addOnCompleteListener(t->{busy=false;if(!closed&&t.isSuccessful()){cache.put(source,t.getResult());previous=source;show(t.getResult());}});
  });
 }
 private boolean isDark(Bitmap b){
  for(int y=0;y<b.getHeight();y+=Math.max(1,b.getHeight()/24))
   for(int x=0;x<b.getWidth();x+=Math.max(1,b.getWidth()/48)){
    int p=b.getPixel(x,y);if(Color.red(p)>16||Color.green(p)>16||Color.blue(p)>16)return false;
   }
  return true;
 }
 private void show(String text){if(overlay!=null){overlay.setText(text);overlay.setVisibility(text.isEmpty()?View.GONE:View.VISIBLE);}}
 private void fail(String text){if(!closed){Toast.makeText(this,text,Toast.LENGTH_LONG).show();stopSelf();}}
 @Override public void onDestroy(){
  closed=true;main.removeCallbacksAndMessages(null);
  if(display!=null)display.release();if(reader!=null)reader.close();
  if(projection!=null)projection.stop();if(recognizer!=null)recognizer.close();if(translator!=null)translator.close();
  if(overlay!=null&&wm!=null)wm.removeView(overlay);
  super.onDestroy();
 }
}
