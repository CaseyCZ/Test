# TCL Caption TEST · TCL C835 / Xbox Series X

Experimentální **nezávislá** testovací aplikace pro Google TV (TCL C835) vycházející z [PlayCaption 0.22](https://github.com/AdamRuzick4/PlayCaption-app/tree/v0.22).

**Účel:** vyšetřit přerušení Xbox Remote Play a/nebo skrytí českých titulků při přepnutí Google TV na vstup HDMI. Nejde o potvrzenou opravu.

## Sestavení

1. Otevři kartu **Actions** → **Build TCL C835 Caption TEST APK**.
2. Spusť **Run workflow**. První pokus se spustí i při přidání workflow do větve `Master`.
3. Po úspěšném běhu stáhni **Artifacts → TCL-C835-Caption-TEST** a uvnitř `app-debug.apk`.
4. Na TCL přenes APK přes LocalSend; testovací aplikace má jméno **TCL Caption TEST** a vlastní package ID `cz.titulky.tv.tcl835test`.

## Bezpečný test

- Originální aplikaci nemaž. Před připojením TCL Caption TEST odpoj Remote Play v původním PlayCaption i na telefonu, aby konzoli neovládaly dvě relace současně.
- Nové aplikaci zvlášť povol oprávnění **Zobrazovat přes jiné aplikace** a znovu připoj účet Xbox; nepřenášej přihlašovací údaje ručně.
- Vyber **Jen televize**, nech ji připojit k Xboxu a přepni na HDMI.
- Pokud se po přepnutí titulky nezobrazují nebo Remote Play vypadne, otevři testovací aplikaci, diagnostiku pod logem a pošli redigovaný výpis **bez tokenů, kódů a údajů účtu**.

## Co diagnostický patch mění

- Na TV dočasně nenutí rozpoznávání aplikace v popředí schovávat titulky. Proto se mohou zobrazit i nad domovskou obrazovkou; toto **není nastavení pro běžné použití**.
- Po dobu aktivního Remote Play přidává `PARTIAL_WAKE_LOCK` pro službu překladu na TCL; po zastavení jej uvolní.
- Do místního `titulky.log` zapisuje přepnutí aplikace v popředí, `onTaskRemoved` a ukončení služby.

Patch **nemění obrazovou HDMI pipeline** ani firmware. Když Google TV aplikaci zcela ukončí, samotný zámek procesoru nemusí zabránit výpadku. Pro opravu je rozhodující diagnostika konkrétního přepnutí.

## Zdroj, licence a autorství

Původní aplikace [AdamRuzick4/PlayCaption-app](https://github.com/AdamRuzick4/PlayCaption-app) © Adam Růžička a přispěvatelé je vydána pod **GNU AGPLv3**. Toto experimentální rozšíření a jeho úpravy jsou také pod GNU AGPLv3. Odpovídající zdrojový kód testovací APK vzniká kombinací konkrétního upstream commitu [633a847](https://github.com/AdamRuzick4/PlayCaption-app/commit/633a847400b6c4bac1e7f034463e7847a53a9590) a zdejšího skriptu [tools/patch_tcl835.py](tools/patch_tcl835.py). Build workflow je součástí tohoto repozitáře. Název ani logo autora se pro označení testovací aplikace nepoužívá.

Projekt je neoficiální a nesouvisí se společnostmi Microsoft, TCL ani s autorem původního PlayCaption. Žádné přihlašovací údaje nebo tokeny Xboxu se do tohoto repozitáře neukládají.
