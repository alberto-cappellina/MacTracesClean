# MacTracesClean

Utility di privacy **locale** per macOS: ti mostra in **sola lettura** cosa hai
lasciato esposto sul tuo Mac (cronologie, credenziali in chiaro, reti Wi-Fi,
residui di app disinstallate…) e, opzionalmente, ripulisce le tracce. Nessun
dato lascia la macchina.

Il progetto ha due componenti che condividono lo stesso scopo:

## 1. `privacy_audit.py` — CLI Python

Scansione e pulizia da riga di comando, senza dipendenze esterne.

```bash
python3 privacy_audit.py                 # report a schermo (sola lettura)
python3 privacy_audit.py --json out.json # salva anche un report JSON
python3 privacy_audit.py --limit 5       # max 5 esempi per categoria
python3 privacy_audit.py --full          # mostra i valori completi dei segreti
```

La pulizia è guidata da `config.json` ed è in **dry-run** finché non passi
`--apply`. I file vengono spostati nel Cestino (recuperabili); le credenziali
non vengono mai toccate automaticamente.

## 2. `MacTracesClean/` — app macOS nativa (SwiftUI)

Versione con interfaccia grafica dello script. Vedi
[MacTracesClean/README.md](MacTracesClean/README.md) per build e dettagli.

```bash
cd MacTracesClean
./build.sh        # richiede XcodeGen: brew install xcodegen
```

## Sicurezza e privacy

- Analisi in sola lettura, nessun dato esce dal Mac.
- Pulizia in dry-run di default, con backup opzionale e rimozione nel Cestino.
- I database SQLite dei browser vengono letti su una copia temporanea in sola
  lettura, per non interferire con l'app aperta.
- Per leggere Safari, Mail, Messaggi ecc. serve **Full Disk Access**.

## Licenza

Distribuito sotto licenza [MIT](LICENSE).
