#!/usr/bin/env python3
"""
privacy_audit.py — Auto-audit della privacy per macOS.

Scansiona (in SOLA LETTURA) il tuo Mac e elenca le informazioni sensibili
o rilevanti per la privacy che vi sono memorizzate: cronologia dei siti
visitati, file aperti di recente, cronologia della shell, credenziali e
chiavi lasciate in chiaro, reti Wi-Fi salvate, download, ecc.

Lo scopo è farti vedere cosa è esposto sulla TUA macchina, così da poter
decidere cosa ripulire. Lo script NON cancella e NON modifica nulla, e NON
invia dati da nessuna parte: stampa un report e, se richiesto, lo salva in
un file JSON locale.

Uso:
    python3 privacy_audit.py                 # report a schermo
    python3 privacy_audit.py --json out.json # salva anche un report JSON
    python3 privacy_audit.py --limit 5       # max 5 esempi per categoria
    python3 privacy_audit.py --full          # mostra i valori completi dei segreti

Nota: alcune cartelle (es. ~/Library/Safari) possono richiedere il permesso
"Full Disk Access" per Terminale/Python in Impostazioni di Sistema >
Privacy e sicurezza. Senza quel permesso alcune sezioni risulteranno vuote.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()


# --------------------------------------------------------------------------- #
# Strutture dati
# --------------------------------------------------------------------------- #
@dataclass
class Finding:
    """Un singolo elemento rilevato."""
    detail: str
    extra: str = ""


@dataclass
class Section:
    """Un gruppo di risultati per una categoria."""
    title: str
    sensitivity: str            # "alta" | "media" | "bassa"
    note: str = ""
    items: list[Finding] = field(default_factory=list)
    error: str = ""             # motivo per cui la sezione è vuota (es. permessi)

    def add(self, detail: str, extra: str = "") -> None:
        self.items.append(Finding(detail=detail, extra=extra))


# --------------------------------------------------------------------------- #
# Utility
# --------------------------------------------------------------------------- #
def _copy_locked_db(db_path: Path) -> Path | None:
    """Copia un DB SQLite (che potrebbe essere bloccato dall'app) in una
    posizione temporanea per poterlo leggere senza interferire."""
    if not db_path.exists():
        return None
    try:
        tmp = Path(tempfile.gettempdir()) / f"pa_{os.getpid()}_{db_path.name}"
        shutil.copy2(db_path, tmp)
        # copia anche eventuali file WAL/SHM per una lettura coerente
        for suffix in ("-wal", "-shm"):
            side = db_path.with_name(db_path.name + suffix)
            if side.exists():
                shutil.copy2(side, tmp.with_name(tmp.name + suffix))
        return tmp
    except (OSError, PermissionError):
        return None


def _query(db_copy: Path, sql: str) -> list[tuple]:
    try:
        con = sqlite3.connect(f"file:{db_copy}?mode=ro", uri=True)
        try:
            return con.execute(sql).fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return []


def _cleanup_tmp(db_copy: Path | None) -> None:
    if not db_copy:
        return
    for p in (db_copy, db_copy.with_name(db_copy.name + "-wal"),
              db_copy.with_name(db_copy.name + "-shm")):
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def _mask(value: str, full: bool) -> str:
    """Nasconde parzialmente un valore sensibile a meno che --full sia attivo."""
    if full:
        return value
    value = value.strip()
    if len(value) <= 8:
        return value[0] + "…" if value else ""
    return f"{value[:4]}…{value[-4:]} ({len(value)} caratteri)"


def _apple_time(ts: float) -> str:
    """Converte un timestamp Apple Cocoa (secondi dal 2001-01-01)."""
    try:
        base = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
        return datetime.fromtimestamp(base + ts).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return ""


def _webkit_time(ts: float) -> str:
    """Converte un timestamp WebKit/Chrome (microsecondi dal 1601-01-01)."""
    try:
        seconds = ts / 1_000_000 - 11_644_473_600
        return datetime.fromtimestamp(seconds).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return ""


# --------------------------------------------------------------------------- #
# Scanner
# --------------------------------------------------------------------------- #
def scan_safari_history(limit: int) -> Section:
    s = Section("Cronologia Safari (siti visitati)", "alta",
                "Elenco degli ultimi URL visitati in Safari.")
    db = HOME / "Library/Safari/History.db"
    if not db.exists():
        s.error = "Safari non in uso o percorso non accessibile."
        return s
    copy = _copy_locked_db(db)
    if not copy:
        s.error = "Impossibile leggere il DB (serve Full Disk Access?)."
        return s
    rows = _query(copy, f"""
        SELECT i.url, v.title, v.visit_time
        FROM history_visits v JOIN history_items i ON i.id = v.history_item
        ORDER BY v.visit_time DESC LIMIT {int(limit)}
    """)
    for url, title, vt in rows:
        when = _apple_time(vt) if vt else ""
        s.add(url, f"{title or ''}  {when}".strip())
    _cleanup_tmp(copy)
    if not rows and not s.error:
        s.error = "Nessun dato (o permessi insufficienti)."
    return s


def scan_chromium_history(limit: int) -> Section:
    s = Section("Cronologia browser Chromium (Chrome/Edge/Brave/Arc)", "alta",
                "Siti visitati nei browser basati su Chromium.")
    bases = {
        "Chrome": "Library/Application Support/Google/Chrome",
        "Edge": "Library/Application Support/Microsoft Edge",
        "Brave": "Library/Application Support/BraveSoftware/Brave-Browser",
        "Arc": "Library/Application Support/Arc/User Data",
        "Chromium": "Library/Application Support/Chromium",
    }
    found_any = False
    for name, rel in bases.items():
        root = HOME / rel
        if not root.exists():
            continue
        for hist in root.glob("*/History"):
            copy = _copy_locked_db(hist)
            if not copy:
                continue
            rows = _query(copy, f"""
                SELECT url, title, last_visit_time
                FROM urls ORDER BY last_visit_time DESC LIMIT {int(limit)}
            """)
            for url, title, lvt in rows:
                found_any = True
                when = _webkit_time(lvt) if lvt else ""
                profile = hist.parent.name
                s.add(url, f"[{name}/{profile}] {title or ''}  {when}".strip())
            _cleanup_tmp(copy)
    if not found_any and not s.items:
        s.error = "Nessun browser Chromium trovato o dati non leggibili."
    return s


def scan_firefox_history(limit: int) -> Section:
    s = Section("Cronologia Firefox", "alta", "Siti visitati in Firefox.")
    base = HOME / "Library/Application Support/Firefox/Profiles"
    if not base.exists():
        s.error = "Firefox non installato."
        return s
    for places in base.glob("*/places.sqlite"):
        copy = _copy_locked_db(places)
        if not copy:
            continue
        rows = _query(copy, f"""
            SELECT url, title, last_visit_date
            FROM moz_places WHERE last_visit_date IS NOT NULL
            ORDER BY last_visit_date DESC LIMIT {int(limit)}
        """)
        for url, title, lvd in rows:
            when = ""
            if lvd:
                try:
                    when = datetime.fromtimestamp(lvd / 1_000_000).strftime("%Y-%m-%d %H:%M")
                except (OverflowError, OSError, ValueError):
                    pass
            s.add(url, f"{title or ''}  {when}".strip())
        _cleanup_tmp(copy)
    if not s.items and not s.error:
        s.error = "Nessun dato leggibile."
    return s


def scan_shell_history(limit: int) -> Section:
    s = Section("Cronologia della shell (comandi digitati)", "alta",
                "I comandi possono contenere password, token o percorsi privati.")
    files = [HOME / ".zsh_history", HOME / ".bash_history",
             HOME / ".local/share/fish/fish_history"]
    secret_re = re.compile(r"(password|passwd|token|secret|api[_-]?key|"
                           r"-p\s|AWS_|BEARER|PRIVATE)", re.IGNORECASE)
    for f in files:
        if not f.exists():
            continue
        try:
            lines = f.read_text(errors="replace").splitlines()
        except (OSError, PermissionError):
            continue
        flagged = [ln for ln in lines if secret_re.search(ln)]
        s.add(f"{f.name}: {len(lines)} righe, {len(flagged)} potenzialmente sensibili",
              f.as_posix())
        for ln in flagged[-limit:]:
            # rimuove prefissi timestamp zsh (": 123456:0;")
            clean = re.sub(r"^: \d+:\d+;", "", ln).strip()
            s.add("⚠︎ " + clean[:200], "")
    if not s.items:
        s.error = "Nessun file di cronologia shell trovato."
    return s


def scan_recent_documents(limit: int) -> Section:
    s = Section("Documenti aperti di recente", "media",
                "File recenti registrati dalle app e dal sistema.")
    # plist condivisi / per-app contenenti liste di recenti
    patterns = [
        HOME / "Library/Preferences/com.apple.recentitems.plist",
        *glob.glob(str(HOME / "Library/Application Support/com.apple.sharedfilelist/*.sfl*")),
    ]
    count = 0
    for p in patterns:
        p = Path(p)
        if not p.exists():
            continue
        s.add(f"Elenco presente: {p.name}", p.as_posix())
        count += 1
        if count >= limit:
            break
    # NSRecentDocuments nei plist delle singole app
    app_prefs = glob.glob(str(HOME / "Library/Preferences/*.plist"))
    shown = 0
    for pref in app_prefs:
        if shown >= limit:
            break
        try:
            with open(pref, "rb") as fh:
                data = plistlib.load(fh)
        except Exception:
            continue
        rec = data.get("NSRecentDocumentRecords") or data.get("recentFiles")
        if rec:
            s.add(f"{Path(pref).stem}: {len(rec)} documenti recenti", pref)
            shown += 1
    if not s.items:
        s.error = "Nessuna lista di documenti recenti leggibile."
    return s


def scan_downloads(limit: int) -> Section:
    s = Section("Download recenti", "media",
                "File scaricati (spesso rivelano acquisti, documenti, allegati).")
    d = HOME / "Downloads"
    if not d.exists():
        s.error = "Cartella Downloads non trovata."
        return s
    try:
        files = sorted(d.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    except (OSError, PermissionError):
        s.error = "Accesso negato alla cartella Downloads."
        return s
    for f in files[:limit]:
        try:
            when = datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
            size = f.stat().st_size
        except OSError:
            when, size = "", 0
        s.add(f.name, f"{when}  {size/1024:.0f} KB")
    s.add(f"Totale elementi nella cartella: {len(files)}", "")
    return s


def scan_credentials(limit: int, full: bool) -> Section:
    s = Section("Credenziali e chiavi in chiaro", "alta",
                "File di configurazione che tipicamente contengono segreti.")
    targets = {
        "~/.aws/credentials": HOME / ".aws/credentials",
        "~/.ssh (chiavi private)": HOME / ".ssh",
        "~/.netrc": HOME / ".netrc",
        "~/.docker/config.json": HOME / ".docker/config.json",
        "~/.npmrc": HOME / ".npmrc",
        "~/.pypirc": HOME / ".pypirc",
        "~/.git-credentials": HOME / ".git-credentials",
        "~/.kube/config": HOME / ".kube/config",
    }
    secret_re = re.compile(
        r"(?P<key>aws_secret_access_key|aws_access_key_id|password|_token|"
        r"authToken|secret|api[_-]?key|BEGIN [A-Z ]*PRIVATE KEY)",
        re.IGNORECASE)
    for label, path in targets.items():
        if not path.exists():
            continue
        if path.is_dir():  # ~/.ssh
            keys = [p for p in path.glob("id_*") if not p.name.endswith(".pub")]
            for k in keys:
                s.add(f"{label}: {k.name}", "chiave privata SSH presente")
            continue
        try:
            text = path.read_text(errors="replace")
        except (OSError, PermissionError):
            s.add(f"{label}: presente (non leggibile)", path.as_posix())
            continue
        hits = 0
        for line in text.splitlines():
            if secret_re.search(line):
                hits += 1
                if hits <= limit:
                    # maschera il valore dopo '=' o ':'
                    m = re.split(r"[:=]", line, maxsplit=1)
                    if len(m) == 2:
                        shown = f"{m[0].strip()} = {_mask(m[1], full)}"
                    else:
                        shown = _mask(line, full)
                    s.add(f"{label}: ⚠︎ {shown}", "")
        if hits:
            s.add(f"{label}: {hits} righe sensibili totali", path.as_posix())
    # scansione .env nei progetti sotto la home (superficiale)
    env_files = glob.glob(str(HOME / "*/.env")) + glob.glob(str(HOME / "*/*/.env"))
    for env in env_files[:limit]:
        s.add("File .env di progetto: " + env, "potenziali segreti d'ambiente")
    if not s.items:
        s.error = "Nessun file di credenziali comune trovato."
    return s


def scan_wifi(limit: int) -> Section:
    s = Section("Reti Wi-Fi conosciute", "media",
                "Le reti salvate rivelano luoghi frequentati (casa, lavoro, viaggi).")
    try:
        out = subprocess.run(
            ["/usr/sbin/networksetup", "-listpreferredwirelessnetworks", "en0"],
            capture_output=True, text=True, timeout=10)
        lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()
                 and not ln.startswith("Preferred")]
        for ln in lines[:limit]:
            s.add(ln, "")
        if lines:
            s.add(f"Totale reti preferite: {len(lines)}", "")
    except (OSError, subprocess.SubprocessError):
        pass
    if not s.items:
        s.error = "Elenco reti non disponibile (interfaccia diversa da en0?)."
    return s


def scan_terminal_state(limit: int) -> Section:
    s = Section("Vari artefatti di privacy", "bassa",
                "Tracce residue che spesso restano sul sistema.")
    checks = {
        "Quick Look thumbnails": HOME / "Library/Caches/com.apple.QuickLook.thumbnailcache",
        "Cache Spotlight recenti": HOME / "Library/Metadata/CoreSpotlight",
        "Messaggi (Messages) DB": HOME / "Library/Messages/chat.db",
        "Mail scaricata": HOME / "Library/Mail",
        "Note (NoteStore)": HOME / "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
        "Calendario": HOME / "Library/Calendars",
        "Appunti/Clipboard history (se app)": HOME / "Library/Application Support",
    }
    for label, path in checks.items():
        if path.exists():
            s.add(f"{label}: presente", path.as_posix())
    return s


# --------------------------------------------------------------------------- #
# Pulizia tracce (configurabile per macro-aree)
# --------------------------------------------------------------------------- #
# PRINCIPI DI SICUREZZA:
#   - Dry-run di default: senza --apply nulla viene toccato, si mostra solo
#     cosa verrebbe rimosso.
#   - Backup automatico dei file prima di modificarli (salvo --no-backup).
#   - Le credenziali NON vengono mai toccate automaticamente: troppo rischioso.
#   - I download vecchi vengono spostati nel Cestino, non eliminati.

DEFAULT_CONFIG_PATH = HOME / ".privacy_audit.json"

DEFAULT_CONFIG = {
    "_help": "Config per la pulizia tracce. Metti 'enabled': true solo nelle aree "
             "che vuoi ripulire. La pulizia è in dry-run finché non passi --apply.",
    "backup": True,
    "areas": {
        "browser_history": {
            "enabled": False,
            "targets": ["safari", "chromium", "firefox"],
            "_desc": "Cancella la cronologia di navigazione (richiede browser chiuso).",
        },
        "shell_history": {
            "enabled": False,
            "mode": "secrets_only",
            "_desc": "Pulisce ~/.zsh_history e ~/.bash_history. "
                     "mode: 'secrets_only' (solo righe con segreti) o 'all' (tutto).",
        },
        "quicklook_cache": {
            "enabled": False,
            "_desc": "Svuota la cache delle anteprime Quick Look (si rigenera da sola).",
        },
        "downloads_old": {
            "enabled": False,
            "older_than_days": 90,
            "_desc": "Sposta nel Cestino i download più vecchi di N giorni (recuperabili).",
        },
        "orphan_app_data": {
            "enabled": False,
            "_desc": "Sposta nel Cestino i residui di app DISINSTALLATE (solo quelli ad "
                     "alta confidenza, identificati per bundle id). Recuperabili.",
        },
    },
}

SECRET_LINE_RE = re.compile(
    r"(password|passwd|token|secret|api[_-]?key|-p\s|AWS_|BEARER|PRIVATE|"
    r"sk-[A-Za-z0-9]|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20})", re.IGNORECASE)


@dataclass
class CleanResult:
    area: str
    removed: int = 0          # elementi/righe che sono (o sarebbero) rimossi
    messages: list[str] = field(default_factory=list)

    def log(self, msg: str) -> None:
        self.messages.append(msg)


def _backup_file(path: Path, backup_root: Path | None) -> None:
    """Copia path dentro backup_root preservando la struttura."""
    if backup_root is None or not path.exists():
        return
    dest = backup_root / path.relative_to(HOME) if path.is_relative_to(HOME) \
        else backup_root / path.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)


def _sql_delete(db_path: Path, statements: list[str],
                dry_run: bool, backup_root: Path | None) -> tuple[int, str]:
    """Esegue DELETE sul DB reale. Ritorna (righe_interessate, messaggio)."""
    if not db_path.exists():
        return 0, "non presente"
    # conta prima quante righe verrebbero toccate
    total = 0
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
        for stmt in statements:
            tbl = stmt.split("FROM", 1)[1].strip().rstrip(";")
            try:
                total += con.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
            except sqlite3.Error:
                pass
        con.close()
    except sqlite3.Error as e:
        return 0, f"non leggibile ({e})"
    if dry_run:
        return total, f"{total} righe verrebbero cancellate (dry-run)"
    _backup_file(db_path, backup_root)
    try:
        con = sqlite3.connect(db_path, timeout=3)
        for stmt in statements:
            con.execute(stmt)
        con.commit()            # chiude la transazione prima del VACUUM
        con.execute("VACUUM")   # VACUUM non è consentito dentro una transazione
        con.close()
        return total, f"{total} righe cancellate"
    except sqlite3.OperationalError as e:
        if "lock" in str(e).lower():
            return 0, "DB bloccato: chiudi il browser e riprova"
        return 0, f"errore: {e}"
    except sqlite3.Error as e:
        return 0, f"errore: {e}"


def clean_browser_history(cfg: dict, dry_run: bool, backup_root: Path | None) -> CleanResult:
    r = CleanResult("browser_history")
    targets = cfg.get("targets", [])
    if "safari" in targets:
        n, msg = _sql_delete(
            HOME / "Library/Safari/History.db",
            ["DELETE FROM history_visits", "DELETE FROM history_items"],
            dry_run, backup_root)
        r.removed += n
        r.log(f"Safari: {msg}")
    if "chromium" in targets:
        bases = [
            "Library/Application Support/Google/Chrome",
            "Library/Application Support/Microsoft Edge",
            "Library/Application Support/BraveSoftware/Brave-Browser",
            "Library/Application Support/Arc/User Data",
            "Library/Application Support/Chromium",
        ]
        for rel in bases:
            root = HOME / rel
            if not root.exists():
                continue
            for hist in root.glob("*/History"):
                n, msg = _sql_delete(
                    hist, ["DELETE FROM visits", "DELETE FROM urls"],
                    dry_run, backup_root)
                r.removed += n
                r.log(f"{rel.split('/')[-1]}/{hist.parent.name}: {msg}")
    if "firefox" in targets:
        base = HOME / "Library/Application Support/Firefox/Profiles"
        for places in base.glob("*/places.sqlite"):
            # cancella solo la cronologia, preservando i segnalibri
            n, msg = _sql_delete(
                places, ["DELETE FROM moz_historyvisits"], dry_run, backup_root)
            r.removed += n
            r.log(f"Firefox/{places.parent.name}: {msg}")
    if not r.messages:
        r.log("nessun browser trovato")
    return r


def clean_shell_history(cfg: dict, dry_run: bool, backup_root: Path | None) -> CleanResult:
    r = CleanResult("shell_history")
    mode = cfg.get("mode", "secrets_only")
    for name in (".zsh_history", ".bash_history"):
        f = HOME / name
        if not f.exists():
            continue
        try:
            lines = f.read_text(errors="replace").splitlines(keepends=True)
        except (OSError, PermissionError):
            r.log(f"{name}: non leggibile")
            continue
        if mode == "all":
            to_remove = len(lines)
            new_lines: list[str] = []
        else:  # secrets_only
            new_lines = [ln for ln in lines if not SECRET_LINE_RE.search(ln)]
            to_remove = len(lines) - len(new_lines)
        r.removed += to_remove
        if dry_run:
            r.log(f"{name}: {to_remove} righe verrebbero rimosse (dry-run)")
            continue
        if to_remove == 0:
            r.log(f"{name}: nessuna riga da rimuovere")
            continue
        _backup_file(f, backup_root)
        try:
            f.write_text("".join(new_lines))
            r.log(f"{name}: {to_remove} righe rimosse")
        except OSError as e:
            r.log(f"{name}: errore in scrittura ({e})")
    if not r.messages:
        r.log("nessun file di cronologia shell trovato")
    return r


def clean_quicklook_cache(cfg: dict, dry_run: bool, backup_root: Path | None) -> CleanResult:
    r = CleanResult("quicklook_cache")
    d = HOME / "Library/Caches/com.apple.QuickLook.thumbnailcache"
    if not d.exists():
        r.log("cache non presente")
        return r
    files = [p for p in d.rglob("*") if p.is_file()]
    r.removed = len(files)
    if dry_run:
        r.log(f"{len(files)} file di cache verrebbero rimossi (dry-run)")
        return r
    errors = 0
    for p in files:
        try:
            p.unlink()
        except OSError:
            errors += 1
    r.log(f"{len(files) - errors} file rimossi" + (f", {errors} errori" if errors else ""))
    return r


def _move_to_trash(path: Path) -> None:
    trash = HOME / ".Trash"
    trash.mkdir(exist_ok=True)
    dest = trash / path.name
    i = 1
    while dest.exists():
        dest = trash / f"{path.stem}_{i}{path.suffix}"
        i += 1
    shutil.move(str(path), str(dest))


def clean_downloads_old(cfg: dict, dry_run: bool, backup_root: Path | None) -> CleanResult:
    r = CleanResult("downloads_old")
    days = int(cfg.get("older_than_days", 90))
    cutoff = datetime.now().timestamp() - days * 86400
    d = HOME / "Downloads"
    if not d.exists():
        r.log("cartella Downloads non trovata")
        return r
    try:
        old = [p for p in d.iterdir()
               if p.name != ".DS_Store" and p.stat().st_mtime < cutoff]
    except (OSError, PermissionError):
        r.log("accesso negato alla cartella Downloads")
        return r
    r.removed = len(old)
    if dry_run:
        for p in old[:20]:
            r.log(f"→ Cestino: {p.name} (dry-run)")
        r.log(f"totale: {len(old)} elementi più vecchi di {days} giorni")
        return r
    moved = 0
    for p in old:
        try:
            _move_to_trash(p)
            moved += 1
        except OSError as e:
            r.log(f"errore su {p.name}: {e}")
    r.log(f"{moved} elementi spostati nel Cestino (recuperabili)")
    return r


# --------------------------------------------------------------------------- #
# Residui di app disinstallate (file "orfani")
# --------------------------------------------------------------------------- #
_BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}$")

# Nomi/identificatori di sistema da non segnalare mai come orfani.
_SYSTEM_SKIP = {
    "crashreporter", "mobilesync", "syncservices", "addressbook", "knowledge",
    "icdd", "clouddocs", "apple", "com.apple", "fontcollections", "metadata",
    "caches", "logs", "preferences", "containers", "coreservices",
}


def _is_bundle_id(name: str) -> bool:
    return bool(_BUNDLE_ID_RE.match(name)) and not name.lower().startswith(
        ("com.apple", "group.com.apple"))


def _path_size(p: Path) -> int:
    try:
        if p.is_file():
            return p.stat().st_size
        total = 0
        for dp, _, fs in os.walk(p):
            for f in fs:
                try:
                    total += os.path.getsize(os.path.join(dp, f))
                except OSError:
                    pass
        return total
    except OSError:
        return 0


def _installed_app_identity() -> tuple[set[str], set[str]]:
    """Ritorna (bundle_ids, nomi) di tutte le app installate sul sistema."""
    bundle_ids: set[str] = set()
    names: set[str] = set()
    app_paths: list[str] = []

    for root in ("/Applications", str(HOME / "Applications"), "/System/Applications"):
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, _ in os.walk(root):
            keep = []
            for dn in dirnames:
                if dn.endswith(".app"):
                    app_paths.append(os.path.join(dirpath, dn))
                else:
                    keep.append(dn)
            dirnames[:] = keep  # non scendere dentro i bundle .app

    try:  # Spotlight: trova tutte le app ovunque siano
        out = subprocess.run(
            ["mdfind", "kMDItemContentTypeTree == 'com.apple.application-bundle'c"],
            capture_output=True, text=True, timeout=20)
        app_paths += [l for l in out.stdout.splitlines() if l.endswith(".app")]
    except (OSError, subprocess.SubprocessError):
        pass

    for app in list(dict.fromkeys(app_paths))[:3000]:
        names.add(Path(app).stem.lower())
        try:
            with open(Path(app) / "Contents/Info.plist", "rb") as fh:
                d = plistlib.load(fh)
        except Exception:
            continue
        bid = d.get("CFBundleIdentifier")
        if bid:
            bundle_ids.add(str(bid).lower())
        for k in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
            if d.get(k):
                names.add(str(d[k]).lower())
    return bundle_ids, names


def _bundle_installed(ident: str, bundle_ids: set[str]) -> bool:
    """True se ident è di un'app installata, o un suo sotto-identificatore
    (es. 'com.microsoft.VSCode.ShipIt' quando 'com.microsoft.VSCode' è installato)."""
    low = ident.lower()
    if low in bundle_ids:
        return True
    return any(low.startswith(b + ".") or b.startswith(low + ".") for b in bundle_ids)


def _name_is_known(name: str, names: set[str]) -> bool:
    low = name.lower()
    if low in _SYSTEM_SKIP or low.startswith((".", "com.apple")):
        return True
    if low in names:
        return True
    if len(low) >= 3:
        return any(low in n for n in names)
    return False


def find_orphan_app_data(cap: int = 300) -> list[dict]:
    """Individua dati in ~/Library che appartengono ad app non più installate."""
    bundle_ids, names = _installed_app_identity()
    results: list[dict] = []

    # Posizioni i cui elementi sono nominati con un bundle id (alta precisione).
    bundle_locs = {
        "Containers": HOME / "Library/Containers",
        "Saved Application State": HOME / "Library/Saved Application State",
        "HTTPStorages": HOME / "Library/HTTPStorages",
        "WebKit": HOME / "Library/WebKit",
    }
    for loc, base in bundle_locs.items():
        if not base.exists():
            continue
        for entry in base.iterdir():
            ident = entry.name.replace(".savedState", "")
            if not _is_bundle_id(ident):
                continue
            if _bundle_installed(ident, bundle_ids):
                continue
            results.append({"path": entry, "ident": ident, "location": loc,
                            "confidence": "alta"})

    # Preferences: file <bundleid>.plist
    prefs = HOME / "Library/Preferences"
    if prefs.exists():
        for entry in prefs.glob("*.plist"):
            ident = entry.name[:-6]  # togli ".plist"
            if not _is_bundle_id(ident) or _bundle_installed(ident, bundle_ids):
                continue
            results.append({"path": entry, "ident": ident, "location": "Preferences",
                            "confidence": "alta"})

    # Posizioni miste: possono usare bundle id o nome leggibile dell'app.
    for loc in ("Application Support", "Caches", "Logs"):
        base = HOME / "Library" / loc
        if not base.exists():
            continue
        for entry in base.iterdir():
            name = entry.name
            if name.startswith("."):
                continue
            if _is_bundle_id(name):
                if _bundle_installed(name, bundle_ids):
                    continue
                conf = "alta"
            else:
                if _name_is_known(name, names):
                    continue
                conf = "bassa"  # match per nome: meno affidabile
            results.append({"path": entry, "ident": name, "location": loc,
                            "confidence": conf})

    for r in results:
        r["size"] = _path_size(r["path"])
    results.sort(key=lambda r: (r["confidence"] != "alta", -r["size"]))
    return results[:cap]


def scan_orphan_app_data(limit: int) -> Section:
    s = Section("Residui di app disinstallate", "media",
                "Dati in ~/Library che sembrano appartenere ad app non più installate. "
                "'alta' = quasi certo (bundle id); 'bassa' = da verificare (match per nome).")
    try:
        orphans = find_orphan_app_data(cap=limit * 4)
    except Exception as e:  # difensivo: non far fallire l'intero audit
        s.error = f"analisi non riuscita ({e})"
        return s
    if not orphans:
        s.error = "nessun residuo evidente trovato."
        return s
    shown_high = [o for o in orphans if o["confidence"] == "alta"][:limit]
    shown_low = [o for o in orphans if o["confidence"] == "bassa"][:limit]
    for o in shown_high + shown_low:
        mb = o["size"] / (1024 * 1024)
        s.add(f"[{o['confidence']}] {o['ident']}  ({mb:.1f} MB)",
              f"{o['location']}: {o['path']}")
    s.add("(mostrati i più grandi; usa --clean per l'elenco completo ad alta confidenza)", "")
    return s


def clean_orphan_app_data(cfg: dict, dry_run: bool, backup_root: Path | None) -> CleanResult:
    r = CleanResult("orphan_app_data")
    # Per sicurezza il cleaner agisce SOLO sugli orfani ad alta confidenza.
    orphans = [o for o in find_orphan_app_data(cap=1000) if o["confidence"] == "alta"]
    if not orphans:
        r.log("nessun residuo ad alta confidenza da rimuovere")
        return r
    r.removed = len(orphans)
    if dry_run:
        for o in orphans[:30]:
            r.log(f"→ Cestino: {o['ident']} [{o['location']}] "
                  f"({o['size']/1024/1024:.1f} MB) (dry-run)")
        if len(orphans) > 30:
            r.log(f"… e altri {len(orphans) - 30}")
        r.log(f"totale: {len(orphans)} residui verrebbero spostati nel Cestino")
        return r
    moved = 0
    for o in orphans:
        try:
            _move_to_trash(o["path"])
            moved += 1
        except OSError as e:
            r.log(f"errore su {o['ident']}: {e}")
    r.log(f"{moved} residui spostati nel Cestino (recuperabili)")
    return r


CLEANERS = {
    "browser_history": clean_browser_history,
    "shell_history": clean_shell_history,
    "quicklook_cache": clean_quicklook_cache,
    "downloads_old": clean_downloads_old,
    "orphan_app_data": clean_orphan_app_data,
}


def load_config(path: Path) -> dict:
    if not path.exists():
        return DEFAULT_CONFIG
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"Config non valida ({e}); uso i valori di default.", file=sys.stderr)
        return DEFAULT_CONFIG


def run_clean(config_path: Path, apply: bool, assume_yes: bool, no_backup: bool) -> int:
    cfg = load_config(config_path)
    areas = cfg.get("areas", {})
    enabled = {k: v for k, v in areas.items() if v.get("enabled")}

    print("=" * 72)
    print("  PULIZIA TRACCE" + ("  —  MODALITÀ REALE (--apply)" if apply
                                 else "  —  DRY-RUN (nessuna modifica)"))
    print(f"  Config: {config_path}")
    print("=" * 72)

    if not enabled:
        print("\nNessuna area attiva nel config. Imposta 'enabled': true nelle aree "
              "desiderate\n(genera un config con --init-config).")
        return 0

    print("\nAree attive: " + ", ".join(enabled))

    backup_root: Path | None = None
    if apply and cfg.get("backup", True) and not no_backup:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_root = HOME / "privacy_audit_backups" / stamp
        backup_root.mkdir(parents=True, exist_ok=True)
        print(f"Backup in: {backup_root}")

    if apply and not assume_yes:
        print("\n⚠️  Stai per MODIFICARE/RIMUOVERE dati in modo irreversibile.")
        resp = input("Digita 'si' per procedere: ").strip().lower()
        if resp != "si":
            print("Annullato.")
            return 1

    dry_run = not apply
    total = 0
    for area, acfg in enabled.items():
        cleaner = CLEANERS.get(area)
        if not cleaner:
            print(f"\n• {area}: sconosciuta, saltata")
            continue
        res = cleaner(acfg, dry_run, backup_root)
        total += res.removed
        print(f"\n• {area}:")
        for m in res.messages:
            print(f"    {m}")

    print("\n" + "=" * 72)
    if dry_run:
        print(f"DRY-RUN: {total} elementi verrebbero rimossi. "
              "Rilancia con --apply per eseguire.")
    else:
        print(f"Completato: {total} elementi elaborati."
              + (f" Backup in {backup_root}" if backup_root else ""))
    print("=" * 72)
    return 0


# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #
SENS_ICON = {"alta": "🔴", "media": "🟠", "bassa": "🟡"}


def print_report(sections: list[Section], limit: int) -> None:
    print("=" * 72)
    print("  AUDIT PRIVACY — macOS   (sola lettura, nessun dato inviato)")
    print(f"  Utente: {HOME.name}   Data: {datetime.now():%Y-%m-%d %H:%M}")
    print("=" * 72)
    for sec in sections:
        icon = SENS_ICON.get(sec.sensitivity, "•")
        print(f"\n{icon} {sec.title}  [sensibilità: {sec.sensitivity}]")
        if sec.note:
            print(f"   {sec.note}")
        if sec.error:
            print(f"   (—) {sec.error}")
        shown = sec.items[:limit * 3]  # un po' di margine, già limitato a monte
        for it in shown:
            line = f"   • {it.detail}"
            if it.extra:
                line += f"   —  {it.extra}"
            print(line)
        if len(sec.items) > len(shown):
            print(f"   … e altri {len(sec.items) - len(shown)} elementi")
    print("\n" + "=" * 72)
    print("Suggerimenti: svuota la cronologia dei browser, rimuovi i segreti dai")
    print("file di configurazione usando un gestore di credenziali, cancella la")
    print("cronologia della shell con 'history -c' / svuota ~/.zsh_history, e")
    print("rivedi i permessi app in Impostazioni > Privacy e sicurezza.")
    print("=" * 72)


def main() -> int:
    if sys.platform != "darwin":
        print("Questo script è pensato per macOS.", file=sys.stderr)
    ap = argparse.ArgumentParser(
        description="Audit della privacy su macOS. Senza opzioni: report in sola lettura. "
                    "Con --clean: pulizia tracce guidata da config (dry-run di default).")
    ap.add_argument("--limit", type=int, default=10,
                    help="Numero massimo di esempi per categoria (default 10).")
    ap.add_argument("--json", metavar="FILE", help="Salva il report anche in JSON.")
    ap.add_argument("--full", action="store_true",
                    help="Mostra i valori completi dei segreti (ATTENZIONE: li stampa in chiaro).")
    # --- pulizia ---
    ap.add_argument("--init-config", nargs="?", const=str(DEFAULT_CONFIG_PATH),
                    metavar="FILE",
                    help="Crea un file di configurazione di esempio ed esci.")
    ap.add_argument("--clean", action="store_true",
                    help="Esegue la pulizia tracce secondo il config (dry-run senza --apply).")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), metavar="FILE",
                    help=f"Percorso del config (default {DEFAULT_CONFIG_PATH}).")
    ap.add_argument("--apply", action="store_true",
                    help="Esegue DAVVERO la pulizia (altrimenti è solo dry-run).")
    ap.add_argument("--yes", action="store_true",
                    help="Salta la richiesta di conferma su --apply.")
    ap.add_argument("--no-backup", action="store_true",
                    help="Non creare backup prima di modificare (sconsigliato).")
    args = ap.parse_args()

    if args.init_config:
        dest = Path(args.init_config)
        if dest.exists():
            print(f"Esiste già: {dest} (non sovrascrivo).", file=sys.stderr)
            return 1
        dest.write_text(json.dumps(DEFAULT_CONFIG, indent=2, ensure_ascii=False))
        print(f"Config creata in: {dest}\nModifica 'enabled': true nelle aree che vuoi "
              "ripulire, poi lancia:\n  python3 privacy_audit.py --clean            # anteprima\n"
              "  python3 privacy_audit.py --clean --apply    # esegue")
        return 0

    if args.clean:
        return run_clean(Path(args.config), args.apply, args.yes, args.no_backup)

    limit = max(1, args.limit)
    sections = [
        scan_safari_history(limit),
        scan_chromium_history(limit),
        scan_firefox_history(limit),
        scan_shell_history(limit),
        scan_recent_documents(limit),
        scan_downloads(limit),
        scan_credentials(limit, args.full),
        scan_wifi(limit),
        scan_orphan_app_data(limit),
        scan_terminal_state(limit),
    ]

    print_report(sections, limit)

    if args.json:
        payload = {
            "generated_at": datetime.now().isoformat(),
            "user": HOME.name,
            "sections": [asdict(s) for s in sections],
        }
        try:
            Path(args.json).write_text(json.dumps(payload, indent=2, ensure_ascii=False))
            print(f"\nReport JSON salvato in: {args.json}")
        except OSError as e:
            print(f"Impossibile scrivere il JSON: {e}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
