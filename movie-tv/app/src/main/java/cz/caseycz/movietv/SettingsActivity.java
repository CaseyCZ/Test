package cz.caseycz.movietv;
import android.app.Activity;
import android.os.Bundle;
import android.graphics.*;
import android.view.*;
import android.widget.*;

public class SettingsActivity extends Activity {
 private SubtitleSettings settings;private TextView sample;private RegionPreview diagram;
 @Override public void onCreate(Bundle b){
  super.onCreate(b);settings=new SubtitleSettings(this);
  ScrollView scroll=new ScrollView(this);LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setPadding(48,24,48,32);scroll.addView(root);
  TextView title=new TextView(this);title.setText("Nastavení titulků");title.setTextSize(28);root.addView(title);
  sample=new TextView(this);sample.setText("Tohle je ukázka českých titulků.");root.addView(sample);settings.style(sample);
  slider(root,"Velikost písma","size",16,48,24);
  choice(root,"Barva textu","color",new String[]{"Bílá","Žlutá","Světle modrá"});
  slider(root,"Krytí pozadí (%)","opacity",0,100,80);
  choice(root,"Umístění","position",new String[]{"Automaticky","Nahoře","Dole"});
  TextView label=new TextView(this);label.setText("Oblast OCR (v procentech obrazovky)");label.setTextSize(22);root.addView(label);
  diagram=new RegionPreview();root.addView(diagram,new LinearLayout.LayoutParams(400,225));
  slider(root,"Levý okraj (%)","x",0,90,5);slider(root,"Horní okraj (%)","y",0,90,70);
  slider(root,"Šířka (%)","width",10,100,90);slider(root,"Výška (%)","height",10,100,25);
  TextView hint=new TextView(this);hint.setText("Šířka a výška se omezí na okraje obrazovky. Změny se použijí při dalším spuštění překladu.");root.addView(hint);
  Button reset=new Button(this);reset.setText("Obnovit výchozí nastavení");root.addView(reset);reset.setOnClickListener(v->{settings.prefs.edit().clear().apply();recreate();});
  Button done=new Button(this);done.setText("Hotovo");root.addView(done);done.setOnClickListener(v->finish());setContentView(scroll);
 }
 private void refresh(){settings.style(sample);if(diagram!=null)diagram.invalidate();}
 private void slider(LinearLayout root,String label,String key,int min,int max,int fallback){
  TextView value=new TextView(this);value.setText(label+": "+settings.get(key,fallback));root.addView(value);
  SeekBar bar=new SeekBar(this);bar.setMax(max-min);bar.setProgress(settings.get(key,fallback)-min);bar.setKeyProgressIncrement(1);bar.setFocusable(true);root.addView(bar);
  bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){}public void onProgressChanged(SeekBar b,int n,boolean user){if(user){settings.put(key,n+min);value.setText(label+": "+(n+min));refresh();}}});
 }
 private void choice(LinearLayout root,String label,String key,String[] choices){
  TextView text=new TextView(this);text.setText(label);root.addView(text);Spinner s=new Spinner(this);s.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,choices));s.setSelection(settings.get(key,0));root.addView(s);
  s.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int index,long id){settings.put(key,index);refresh();}});
 }
 private class RegionPreview extends View{
  private final Paint p=new Paint(3);RegionPreview(){super(SettingsActivity.this);}
  @Override protected void onDraw(Canvas c){super.onDraw(c);c.drawColor(0xff252b35);Rect r=settings.region(getWidth(),getHeight());p.setStyle(Paint.Style.FILL);p.setColor(0x44ffcc00);c.drawRect(r,p);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(3);p.setColor(0xffffcc00);c.drawRect(r,p);p.setStyle(Paint.Style.FILL);}
 }
}
