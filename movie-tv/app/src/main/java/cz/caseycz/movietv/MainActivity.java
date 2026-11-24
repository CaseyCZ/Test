package cz.caseycz.movietv;
import android.app.*;
import android.content.*;
import android.media.projection.MediaProjectionManager;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.*;

public class MainActivity extends Activity {
 private Spinner region, language;
 @Override public void onCreate(Bundle state) {
  super.onCreate(state);
  LinearLayout root=new LinearLayout(this); root.setOrientation(1); root.setPadding(48,32,48,32);
  TextView title=new TextView(this); title.setText("Překlad filmů a seriálů"); title.setTextSize(28); root.addView(title);
  TextView info=new TextView(this); info.setText("OCR: překlad viditelných titulků do češtiny. Chráněný obraz nemusí být dostupný. Při prvním spuštění se stáhne jazykový model."); root.addView(info);
  region=new Spinner(this); region.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"Spodních 25 %","Spodních 40 %","Horních 25 %"})); root.addView(region);
  language=new Spinner(this); language.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"English","Deutsch","Français","Español"})); root.addView(language);
  Button start=new Button(this); start.setText("Spustit OCR překlad"); root.addView(start); start.setOnClickListener(v->{
   if(!Settings.canDrawOverlays(this)){startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:"+getPackageName())));return;}
   startActivityForResult(getSystemService(MediaProjectionManager.class).createScreenCaptureIntent(),42);
  });
  Button stop=new Button(this); stop.setText("Zastavit překlad"); root.addView(stop); stop.setOnClickListener(v->stopService(new Intent(this,OcrService.class)));
  setContentView(root); start.requestFocus();
 }
 @Override protected void onActivityResult(int request,int result,Intent data){
  super.onActivityResult(request,result,data);
  if(request==42&&result==RESULT_OK&&data!=null){
   Intent i=new Intent(this,OcrService.class).putExtra("result",result).putExtra("permission",data).putExtra("region",region.getSelectedItemPosition()).putExtra("language",new String[]{"en","de","fr","es"}[language.getSelectedItemPosition()]);
   startForegroundService(i); moveTaskToBack(true);
  }
 }
}
