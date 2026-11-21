# TCL Caption GPU TEST · TCL C835 / Xbox Series X

Experimentální **nezávislá** testovací aplikace pro Google TV (TCL C835) vycházející z [PlayCaption 0.22](https://github.com/AdamRuzick4/PlayCaption-app/tree/v0.22).

**Účel:** vyšetřit přerušení Xbox Remote Play a/nebo skrytí českých titulků při přepnutí Google TV na vstup HDMI. Nejde o potvrzenou opravu.

## Sestavení

1. Otevři kartu **Actions** → **Build TCL C835 Caption TEST APK**.
2. Spusť **Run workflow**. První pokus se spustí i při přidání workflow do větve `Master`.
3. Po úspěšném běhu stáhni **Artifacts → TCL-C835-Caption-GPU-TEST** a uvnitř `app-debug.apk`.
4. Na TCL přenes APK přes LocalSend; testovací aplikace má jméno **TCL Caption GPU TEST** a vlastní package ID `cz.titulky.tv.tcl835gpudiag`.

## Bezpečný test

- Originální aplikaci nemaž. Před připojením TCL Caption GPU TEST odpoj Remote Play v původním PlayCaption i na telefonu, aby konzoli neovládaly dvě relace současně.
- Nové aplikaci zvlášť povol oprávnění **Zobrazovat přes jiné aplikace** a znovu připoj účet Xbox; nepřenášej přihlašovací údaje ručně.
- Vyber **Jen televize**, nech ji připojit k Xboxu a přepni na HDMI.
- Pokud se po přepnutí titulky nezobrazují nebo Remote Play vypadne, otevři testovací aplikaci, diagnostiku pod logem a pošli redigovaný výpis **bez tokenů, kódů a údajů účtu**.

## Co diagnostický patch mění

- Na TV dočasně nenutí rozpoznávání aplikace v popředí schovávat titulky. Proto se mohou zobrazit i nad domovskou obrazovkou; toto **není nastavení pro běžné použití**.
- Po dobu aktivního Remote Play přidává `PARTIAL_WAKE_LOCK` pro službu překladu na TCL; po zastavení jej uvolní.
- Do místního `titulky.log` zapisuje přepnutí aplikace v popředí, `onTaskRemoved` a ukončení služby.

Patch **nemění obrazovou HDMI pipeline** ani firmware. Když Google TV aplikaci zcela ukončí, samotný zámek procesoru nemusí zabránit výpadku. Pro opravu je rozhodující diagnostika konkrétního přepnutí.

## Rozšířený HDMI log (testovací větev)

Ve větvi `diagnostics/tcl835-hdmi-trace` je diagnostický režim **bez změny stávajícího GPU experimentu, pravidel připojení či překryvu**. Nevztahuje se na původní PlayCaption ani na již vydanou APK; je nutné sestavit novou testovací APK z této větve.

- **Spustit TCL Caption GPU TEST → Jen televize → připojit Xbox → přepnout na HDMI 2.**
- Po výpadku se vrať do aplikace a otevři diagnostiku: najeď na **logo** a stiskni **OK**.
- Najdi blok **TCL C835 HDMI TRACE**. K přenosu použij dole **Odeslat log na GitHub**. Je v něm posledních 120 záznamů z `tcl835-diagnostic.log` s milisekundovým časem, `pid`, ID procesu a dobou běhu.
- **[INPUT]** = aplikace v popředí a výsledek původní HDMI klasifikace; GPU test ji nadále ignoruje, aby nezakrývala titulky.
- **[RP HEARTBEAT]** každých 5 sekund = stav Remote Play, počet WebRTC snímků, počet zpracovaných snímků, čas od posledního zpracování, stav překryvu a úsporného režimu.
- **[RTC]** = změny ICE, handshake, první snímek, zamrzlý obraz a ukončení Xbox streamu.
- **[RP START/CREATE/DESTROY/TASK REMOVED/TRIM MEMORY]** = životní cyklus aplikace; **[OVERLAY]** = zda bylo možné vytvořit titulkovou vrstvu.

**Interpretace:** Pokud snímky přestanou přibývat před `ICE: DISCONNECTED`, může jít o zamrznutí dekodéru nebo video transportu. Jestli `ICE` nejprve přejde na `DISCONNECTED`, je prioritou spojení. Pokud po návratu do aplikace vidíme nové `pid/sid` bez předchozího `DESTROY`, Android mohl proces násilně ukončit (není to samo o sobě důkaz). Když snímky přibývají a overlay je připraven, ale titulky nejsou vidět, je podezřelý překryv nad HDMI.

Log **nečte skutečné HDMI hardware události** a neposílá data ven. Neobsahuje titulky, účty ani tokeny, ale před veřejným sdílením i tak zkontroluj původní `titulky.log`/`xbox.log`.

## Online přepínače bez přeinstalace APK

Rozšířená testovací APK (teprve po úspěšném buildu z této větve) bude načítat
[online konfiguraci z GitHubu](https://github.com/CaseyCZ/Test/blob/Master/config/tcl835.json).
Při aktivní službě si ji kontroluje přibližně každou minutu; pokud je TV offline,
ponechá poslední načtené nastavení během aktuálního běhu. Výchozí hodnoty jsou
totožné se současným GPU experimentem.

| Klíč | Hodnoty | Účel |
| --- | --- | --- |
| `traceIntervalSeconds` | 5–60 | Interval souhrnného logu |
| `forceHdmiOverlay` | true / false | Zobrazovat překryv i tehdy, když se HDMI nerozpozná |
| `keepCpuAwake` | true / false | Diagnostické udržení CPU při Remote Play |
| `decoderMode` | `no_gpu` / `default` | Xbox dekodér bez GPU textur / standardní |

**Jak upravit:** na GitHubu otevřít odkaz na JSON → tužka **Edit** → změnit hodnotu
→ **Commit changes**. Pokud měním konfiguraci já, upravím stejný soubor;
televize si ji načte sama. Novou APK potřebujeme jen při změně skutečného
kódu, oprávnění, služeb či samotného formátu online nastavení.

Bezpečnost: HTTPS, pouze čtení veřejného konfiguračního souboru, pevný seznam
klíčů, žádné stahování ani spouštění vzdáleného kódu. Aplikace **neodesílá
logy ani Xbox přihlašovací údaje**. Pro vyhodnocení stále musíme získat
diagnostický výpis z TV. Bez znalosti výsledku testu nelze potvrdit opravu HDMI.

## Odeslání diagnostiky přímo na GitHub

Na testovací TCL C835 otevři diagnostiku přes logo a OK. V dolní liště je
tlačítko **Odeslat log na GitHub**. Po stisknutí:

1. APK vybere poslední technické události z `tcl835-diagnostic.log` – stav
   Xbox ICE, počet přijatých snímků, čas bez obrazu, rozpoznání HDMI a stav služby.
2. Otevře se nové hlášení na [GitHub Issues](https://github.com/CaseyCZ/Test/issues)
   se **samostatně předvyplněným** názvem a textem diagnostiky.
3. Přihlas se na GitHub, prohlédni výpis a potvrď **Submit new issue**.
   Hlášení pak půjde otevřít a analyzovat prostřednictvím GitHub propojení.

**Žádný server, automatický upload ani token v APK nejsou potřeba.** Protože
repozitář `CaseyCZ/Test` je **veřejný**, zveřejněné issue je také veřejné.
Do odesílaného výpisu patří pouze whitelistované technické události – ne
originální `xbox.log`, `titulky.log`, tokeny ani texty titulků.

GitHub neumožňuje neautorizované jedním požadavkem založené issues:
**jedno potvrzení přímo na GitHubu je nutné**. Televize musí mít dostupný
prohlížeč. Pokud není, otevření odkazu selže a log zůstává uložený v TV.
ChatGPT se o novém issue samo okamžitě nedozví, dokud nekontroluje GitHub
v aktivní konverzaci nebo prostřednictvím samostatného naplánovaného sledování.

## Zdroj, licence a autorství

Původní aplikace [AdamRuzick4/PlayCaption-app](https://github.com/AdamRuzick4/PlayCaption-app) © Adam Růžička a přispěvatelé je vydána pod **GNU AGPLv3**. Toto experimentální rozšíření a jeho úpravy jsou také pod GNU AGPLv3. Odpovídající zdrojový kód testovací APK vzniká kombinací konkrétního upstream commitu [633a847](https://github.com/AdamRuzick4/PlayCaption-app/commit/633a847400b6c4bac1e7f034463e7847a53a9590) a zdejšího skriptu [tools/patch_tcl835.py](tools/patch_tcl835.py). Build workflow je součástí tohoto repozitáře. Název ani logo autora se pro označení testovací aplikace nepoužívá.

Projekt je neoficiální a nesouvisí se společnostmi Microsoft, TCL ani s autorem původního PlayCaption. Žádné přihlašovací údaje nebo tokeny Xboxu se do tohoto repozitáře neukládají.
