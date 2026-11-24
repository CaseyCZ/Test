package cz.caseycz.movietv;
import java.util.LinkedHashMap;
import java.util.Map;
final class TranslationCache {
 private final Map<String,String> cache=new LinkedHashMap<String,String>(64,0.75f,true){
  @Override protected boolean removeEldestEntry(Map.Entry<String,String> e){return size()>128;}
 };
 static String normalize(String text){return text==null?"":text.trim().replaceAll("\\s+"," ");}
 String get(String source){return cache.get(normalize(source));}
 void put(String source,String target){if(target!=null&&!target.isEmpty())cache.put(normalize(source),target);}
}
