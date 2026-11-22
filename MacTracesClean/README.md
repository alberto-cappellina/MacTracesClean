# MacTracesClean

Utility privacy personale per macOS (SwiftUI nativa). È la versione con interfaccia
grafica dello script `privacy_audit.py`: analizza in **sola lettura** cosa è esposto sul
tuo Mac e, opzionalmente, ripulisce le tracce.

## Funzioni

**Analisi privacy** (sola lettura, nessun dato esce dal Mac)
- Cronologia Safari / Chromium (Chrome, Edge, Brave, Arc) / Firefox
- Cronologia della shell con evidenza di comandi contenenti segreti
- Documenti aperti di recente
- Download recenti
- Credenziali e chiavi in chiaro (`~/.aws`, `~/.ssh`, `.env`, ecc.) — valori mascherati
- Reti Wi-Fi conosciute
- Residui di app disinstallate in `~/Library`
- Vari artefatti di privacy (Quick Look, Spotlight, Messages, Mail, Note…)

**Pulizia tracce** (dry-run di default, backup opzionale, file nel Cestino)
- Cronologia browser · Cronologia shell (solo segreti o tutta) · Cache Quick Look
- Download più vecchi di N giorni · Residui di app disinstallate (solo alta confidenza)
- Le credenziali non vengono **mai** toccate automaticamente.

## Build e avvio

```bash
cd MacTracesClean
./build.sh
```

Lo script genera il progetto con XcodeGen, compila con `xcodebuild` e apre l'app.
Il file `.xcodeproj` è generato da XcodeGen (`xcodegen generate`) e non è
versionato: rigeneralo con `./build.sh` o `xcodegen generate`, poi aprilo in
Xcode e premi Run.

## Full Disk Access

Per leggere Safari, Mail, Messaggi e simili, aggiungi **MacTracesClean** in
Impostazioni di Sistema › Privacy e sicurezza › **Accesso completo al disco**,
poi riavvia l'app. Senza questo permesso le sezioni relative risultano vuote;
l'app lo segnala e offre un pulsante per aprire le impostazioni.

## Note tecniche
- Non in sandbox (serve per leggere `~/Library`).
- SQLite letto tramite copia temporanea del DB (come lo script Python), così
  non interferisce con il browser aperto.
- Nessuna dipendenza esterna: solo SwiftUI + SQLite3 di sistema.
