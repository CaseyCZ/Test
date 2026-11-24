package cz.caseycz.movietv;
import android.content.*;
import android.graphics.*;
import android.view.*;
import android.widget.*;

final class SubtitleSettings {
 final SharedPreferences prefs;
 SubtitleSettings(Context c){prefs=c.getSharedPreferences("movie_subtitles",0);}
 int get(String key,int fallback){return prefs.getInt(key,fallback);}
 void put(String key,int value){prefs.edit().putInt(key,value).apply();}
 int size(){return get("size",24);}
 int color(){return get("color",0)==1?Color.YELLOW:get("color",0)==2?0xff99ddff:Color.WHITE;}
 int background(){return Color.argb(get("opacity",80)*255/100,0,0,0);}
 int position(){return get("position",0);}
 Rect region(int w,int h){
  int x=Math.min(90,Math.max(0,get("x",5))),y=Math.min(90,Math.max(0,get("y",70)));
  int rw=Math.min(100-x,Math.max(10,get("width",90))),rh=Math.min(100-y,Math.max(10,get("height",25)));
  return new Rect(w*x/100,h*y/100,Math.max(w*x/100+1,w*(x+rw)/100),Math.max(h*y/100+1,h*(y+rh)/100));
 }
 void style(TextView v){v.setTextSize(size());v.setTextColor(color());v.setBackgroundColor(background());v.setGravity(Gravity.CENTER);v.setPadding(20,8,20,8);}
 void place(WindowManager.LayoutParams p,boolean ocr){
  int pos=position();if(pos==0)pos=ocr&&get("y",70)>=50?1:2;
  p.gravity=(pos==1?Gravity.TOP:Gravity.BOTTOM)|Gravity.CENTER_HORIZONTAL;p.y=40;
 }
 // The output is marked secure by the services to prevent OCR reading its own text.
}
