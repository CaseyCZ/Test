package cz.caseycz.movietv;
import org.junit.Test;
import static org.junit.Assert.*;
public class TranslationCacheTest {
 @Test public void normalizesWhitespace(){assertEquals("hello world",TranslationCache.normalize(" hello\n world "));}
 @Test public void reusesTranslation(){TranslationCache c=new TranslationCache();c.put("hello","ahoj");assertEquals("ahoj",c.get(" hello "));}
 @Test public void boundedCache(){TranslationCache c=new TranslationCache();for(int i=0;i<129;i++)c.put("key"+i,"value");assertNull(c.get("key0"));assertEquals("value",c.get("key128"));}
 @Test public void ignoresEmptyTranslation(){TranslationCache c=new TranslationCache();c.put("hello","");assertNull(c.get("hello"));}
}
