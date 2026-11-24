package cz.caseycz.movietv;
import android.app.*;
import android.content.*;
import android.media.projection.MediaProjectionManager;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.*;

public class MainActivity extends Activity {
 private Spinner language; private boolean audio;
 @Override public void onCreate(Bundle state) {
  super.onCreate(state);
  LinearLayout root=new LinearLayout(this); root.setOrientation(1); root.setPadding(48,32,48,32);
  TextView title=new TextView(this); title.setText("Překlad filmů a seriálů"); title.setTextSize(28); root.addView(title);
  TextView info=new TextView(this); info.setText("OCR: překlad viditelných titulků do češtiny. Chráněný obraz nemusí být dostupný. Při prvním spuštění se stáhne jazykový model."); root.addView(info);
  Button settings=new Button(this);settings.setText("Nastavení titulků a oblasti OCR");root.addView(settings);settings.setOnClickListener(v->startActivity(new Intent(this,SettingsActivity.class)));
  language=new Spinner(this); language.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"English","Deutsch","Français","Español"})); root.addView(language);
  Button start=new Button(this); start.setText("Spustit OCR překlad"); root.addView(start); start.setOnClickListener(v->{audio=false; requestCapture();});
  Button sound=new Button(this); sound.setText("Spustit AUDIO překlad (angličtina)");root.addView(sound);sound.setOnClickListener(v->{audio=true;requestCapture();});
  Button stop=new Button(this); stop.setText("Zastavit překlad"); root.addView(stop); stop.setOnClickListener(v->{stopService(new Intent(this,OcrService.class));stopService(new Intent(this,AudioService.class));});
  setContentView(root); start.requestFocus();
 }
 private void requestCapture(){
   stopService(new Intent(this,OcrService.class));stopService(new Intent(this,AudioService.class));
   if(!Settings.canDrawOverlays(this)){startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:"+getPackageName())));return;}
   if(audio&&checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)!=android.content.pm.PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{android.Manifest.permission.RECORD_AUDIO},43);return;}
   startActivityForResult(getSystemService(MediaProjectionManager.class).createScreenCaptureIntent(),audio?44:42);
 }
 @Override public void onRequestPermissionsResult(int r,String[] p,int[] g){super.onRequestPermissionsResult(r,p,g);if(r==43&&g.length>0&&g[0]==0){audio=true;requestCapture();}}
 @Override protected void onActivityResult(int request,int result,Intent data){
  super.onActivityResult(request,result,data);
  if((request==42||request==44)&&result==RESULT_OK&&data!=null){
   Intent i=new Intent(this,request==44?AudioService.class:OcrService.class).putExtra("result",result).putExtra("permission",data).putExtra("language",new String[]{"en","de","fr","es"}[language.getSelectedItemPosition()]);
   try{startForegroundService(i); moveTaskToBack(true);}catch(RuntimeException e){Toast.makeText(this,"Překlad nelze spustit",Toast.LENGTH_LONG).show();}
  }else if(request==42||request==44){Toast.makeText(this,"Snímání nebylo povoleno",Toast.LENGTH_SHORT).show();}
 }
}
