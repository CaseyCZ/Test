# Soukromý sběrač diagnostiky pro TCL C835

Tento modul funguje **jen na vlastním serveru**. Nenasazuje se do veřejného GitHub Pages.
Na televizi není žádný GitHub token a nic se neodesílá, dokud není
`logUploadEnabled=true` a platné HTTPS `logUploadEndpoint`.

## Jak funguje

1. Testovací PlayCaption zaznamená pouze technické události v souboru
   `tcl835-diagnostic.log` (žádný snímek obrazovky, text titulků, IP adresa
   Xboxu, přístupový token, účet ani původní `xbox.log`).
2. Při výpadku ICE nebo periodicky pošle výběr posledních událostí přes
   HTTPS (`POST /v1/logs`).
3. Pro každý TV install Android Keystore vytvoří neexportovatelný
   podepisovací EC klíč. Přijímač dovolí jednorázově zaregistrovat první
   zařízení jen během **10minutového párovacího okna** a pak ověřuje
   digitální podpis každé zprávy.
4. Příjemce ukládá zprávy do soukromého souboru ve formátu JSONL.
   Není zde veřejné rozhraní pro čtení logů. Záznamy se čistí po 14 dnech
   při startu serveru. Při neúspěšném odeslání zůstávají data v TV.

## Oracle Ubuntu + PM2 (příklad nasazení)

Na svém Oracle Ubuntu VM použij **Node.js 20+**, samostatného uživatele
a privátní adresář. Před odesláním z TV musí běžet zabezpečená HTTPS
adresa pod vlastní doménou.

```bash
cd /opt/tcl-diagnostics
mkdir -p private-logs
chmod 700 private-logs
TCL_LOG_DIR=/opt/tcl-diagnostics/private-logs \
PORT=41690 TCL_PAIR_FIRST_DEVICE=yes node collector/server.cjs
```

Služba poslouchá **jen 127.0.0.1:41690**, proto potřebuje reverzní HTTPS
proxy (např. Nginx s platným TLS certifikátem).

Příklad relevantní části bloku `server` v Nginxu (název domény a TLS
certifikát musíš nastavit na svůj skutečný server):

```nginx
location = /v1/logs {
    client_max_body_size 100k;
    limit_except POST { deny all; }
    proxy_pass http://127.0.0.1:41690;
    proxy_set_header Host $host;
    proxy_connect_timeout 5s;
    proxy_read_timeout 10s;
}
location = /health {
    proxy_pass http://127.0.0.1:41690;
}
```

**Párování:** spusť server s `TCL_PAIR_FIRST_DEVICE=yes` jen při prvním
zapnutí uploadu a zkontroluj, že se spárovalo **tvé** zařízení. Párovací okno
trvá 10 minut od startu procesu, a přijímá se jen první identita v úložišti.
Potom spusť službu trvale **bez** `TCL_PAIR_FIRST_DEVICE=yes`, například
přes PM2. Mimo párovací okno se nová zařízení odmítají. Nestahuj zde
žádné tokeny z veřejných souborů.

## Přepnutí TV na odesílání

Na GitHubu v `config/tcl835.json` nastav:

```json
{
  "schema": 1,
  "traceIntervalSeconds": 5,
  "forceHdmiOverlay": true,
  "keepCpuAwake": true,
  "decoderMode": "no_gpu",
  "logUploadEnabled": true,
  "logUploadEndpoint": "https://YOUR-OWN-HOSTNAME/v1/logs"
}
```

`YOUR-OWN-HOSTNAME` je jen příklad, neexistující přednastavená služba.
Nikdy do veřejného JSONu nevkládej hesla nebo tajné klíče. TV obnovuje
konfiguraci přibližně jednou za minutu.

## Jak číst výsledky

Na serveru:

```bash
ls -lah /opt/tcl-diagnostics/private-logs
tail -n 3 /opt/tcl-diagnostics/private-logs/tcl-*.jsonl
```

Tyto soubory **nejsou veřejně přístupné**, přístup drž jen na serveru.
Případný výpis můžeš zpřístupnit v tomto chatu nebo jej uložit do
privátního GitHub repozitáře, ke kterému máš připojený GitHub konektor;
teprve pak ho můžu analyzovat. Nemám samovolný přístup do tvého
serveru ani možnost přijmout automatické oznámení přímo v chatu.

## Bezpečnostní omezení

- Sběrač ověřuje ECDSA podpis každé zprávy a ukládá do souborů jen
  události z povolené diagnostické sady.
- Nemá API pro mazání, spuštění kódu nebo vzdálené ovládání TV.
- Nestahuje žádný vzdálený kód a nesdílí data veřejně.
- Protože každá nově instalovaná APK generuje vlastní klíč, pro
  přechod na jiný TV profil je potřeba párování ověřit znovu.
- Online přepínače diagnostiky **nemění zdrojový kód**. Skutečné
  změny aplikace dál vyžadují novou APK.

