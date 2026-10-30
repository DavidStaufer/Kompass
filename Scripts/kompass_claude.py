#!/usr/bin/env python3
"""Kompass ↔ Claude: Lernmaterial über das Claude-Abo statt über eine API.

Das Skript erledigt alles, wofür keine KI nötig ist (planen, Texte vorbereiten, prüfen,
Buch führen), damit Claude nur das eigentliche Schreiben übernimmt – sparsam fürs Nutzungslimit.

  plan            Aufträge aus der App, geänderte und neue Materialien → Arbeitspakete (kompaktes JSON)
  show <job>      Regeln, Ausgabeformat und Materialtext für genau ein Paket
  submit <job>    Ergebnis-JSON (stdin oder --file) prüfen und an Kompass übergeben
  finish          Durchlauf abschließen (Status für die App, Zusammenfassung)

Datenordner: iCloud Drive „Kompass“ (falls vorhanden), sonst ~/Library/Application Support/Kompass,
oder --data-dir. Austausch mit der App in <Daten>/Claude/ (Auftraege, Eingang, status.json).
Nur Standardbibliothek.
"""
import argparse
import datetime as dt
import difflib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import uuid
from contextlib import contextmanager
from pathlib import Path

SCRIPT = Path(__file__).resolve()
HOME = Path.home()
ICLOUD = HOME / "Library/Mobile Documents/com~apple~CloudDocs/Kompass"
LOCAL = HOME / "Library/Application Support/Kompass"
WORK = HOME / "Library/Caches/Kompass-Claude"
# Text jedes verarbeiteten Materials (nur auf diesem Mac) – zum Erkennen späterer Änderungen
SNAPSHOTS = HOME / "Library/Application Support/Kompass-Claude/Texte"

# Textmengen je Paket (Zeichen) – Haiku bekommt höchstens so viel Material auf einmal
PART_CHARS = 40_000
REQUEST_CHARS = {"haiku": 50_000, "sonnet": 70_000}
MAX_REQUESTS_PER_RUN = 5
MAX_SYNTH_PER_RUN = 2
SYNTH_EVERY_DAYS = 6
# Geänderte Materialien: darunter gilt eine Änderung als Kleinigkeit (z. B. Tippfehler) und kostet nichts
MINOR_CHANGE_CHARS = 300
MINOR_CHANGE_RATIO = 0.03
UPDATE_CHARS = 15_000
# Übungen, die mit ihrer Vorlesung in einem Paket aufbereitet werden (spart den Grundaufwand eines zweiten Agenten)
EXERCISE_CHARS = 8_000
SOLUTION_CHARS = 4_000
MAX_EXERCISES_PER_LECTURE = 3
UPDATE_MAX_CARDS = 3        # geänderte Datei: Karten nur für neue Inhalte

LECTURE_KINDS = {"vorlesung", "skript", "zusammenfassung", "notiz", "sonstiges"}
EXERCISE_KINDS = {"uebung", "loesung"}
EXAM_KINDS = {"altklausur", "probeklausur"}
KIND_LABEL = {"vorlesung": "Vorlesung", "skript": "Skript", "zusammenfassung": "Zusammenfassung", "notiz": "Notiz",
              "sonstiges": "Material", "uebung": "Übung", "loesung": "Lösung", "altklausur": "Altklausur",
              "probeklausur": "Probeklausur"}


# ---------------------------------------------------------------- Hilfen

def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_date(s):
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def new_id():
    return str(uuid.uuid4()).upper()


def data_dir(arg):
    if arg:
        return Path(arg).expanduser()
    env = os.environ.get("KOMPASS_DATA_DIR")
    if env:
        return Path(env).expanduser()
    return ICLOUD if (ICLOUD / "kompass.json").exists() else LOCAL


def ensure_downloaded(path: Path, wait=20):
    """iCloud: ausgelagerte Dateien („.name.icloud“) erst herunterladen."""
    if path.exists():
        return True
    placeholder = path.with_name("." + path.name + ".icloud")
    if not placeholder.exists():
        return False
    subprocess.run(["brctl", "download", str(path)], capture_output=True)
    for _ in range(wait):
        if path.exists():
            return True
        time.sleep(1)
    return False


def read_json(path: Path, default=None):
    try:
        ensure_downloaded(path)
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json_atomic(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


@contextmanager
def locked():
    WORK.mkdir(parents=True, exist_ok=True)
    with open(WORK / ".lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


class Ctx:
    def __init__(self, root: Path):
        self.root = root
        self.claude = root / "Claude"
        self.requests = self.claude / "Auftraege"
        self.inbox = self.claude / "Eingang"
        self.status_file = self.claude / "status.json"
        self.data = read_json(root / "kompass.json")
        if self.data is None:
            sys.exit(f"Keine Kompass-Daten gefunden in {root}")
        self.prefs = self.data.get("prefs", {})

    def pref(self, key, default):
        v = self.prefs.get(key)
        return default if v is None else v

    def status(self):
        s = read_json(self.status_file, {}) or {}
        s.setdefault("version", 1)
        s.setdefault("processed", {})
        s.setdefault("modules", {})
        return s

    def save_status(self, s):
        write_json_atomic(self.status_file, s)

    def module(self, mid):
        return next((m for m in self.data.get("modules", []) if m.get("id", "").upper() == str(mid).upper()), None)

    def text(self, module_id, material_id):
        p = self.root / "Materialien" / module_id / f"{material_id}.txt"
        if not ensure_downloaded(p):
            return None
        try:
            return p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            return None

    def exam_date(self, module_id):
        exams = [parse_date(d["date"]) for d in self.data.get("deadlines", [])
                 if d.get("moduleID", "").upper() == module_id.upper() and d.get("kind") == "klausur" and not d.get("done")]
        exams = [e for e in exams if e]
        return min(exams) if exams else None


def fingerprint(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def save_snapshot(material_id, text):
    SNAPSHOTS.mkdir(parents=True, exist_ok=True)
    (SNAPSHOTS / f"{material_id}.txt").write_text(text, encoding="utf-8")


def load_snapshot(material_id):
    p = SNAPSHOTS / f"{material_id}.txt"
    return p.read_text(encoding="utf-8") if p.exists() else None


def text_changes(old, new):
    """Vergleicht zwei Fassungen zeilenweise. Liefert neue/geänderte Stellen (mit etwas Kontext),
    entfernte Zeilen und wie viele Zeichen sich geändert haben."""
    norm = lambda t: [ln for ln in (re.sub(r"\s+", " ", x).strip() for x in t.split("\n")) if ln]
    a, b = norm(old), norm(new)
    added, removed, changed = [], [], 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag in ("replace", "insert"):
            block = b[j1:j2]
            changed += sum(len(x) for x in block)
            added.append("\n".join(["…"] + b[max(0, j1 - 2):j1] + [">> " + x for x in block] + b[j2:j2 + 1]))
        if tag in ("replace", "delete"):
            removed += a[i1:i2]
            changed += sum(len(x) for x in a[i1:i2])
    return {"added": added, "removed": removed, "changed": changed, "ratio": changed / max(1, len(new))}


def clean(text):
    text = text.replace("\r", "")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def split_parts(text, size=PART_CHARS):
    if len(text) <= size * 1.15:
        return [text]
    parts, start = [], 0
    while start < len(text):
        end = min(len(text), start + size)
        if end < len(text):
            cut = text.rfind("\n\n", start + size // 2, end)
            end = cut if cut > 0 else end
        parts.append(text[start:end].strip())
        start = end
    return [p for p in parts if p]


def short(module):
    return module.get("code") or module.get("name", "")[:24]


def model_for(kind_heavy, ctx):
    return "sonnet" if kind_heavy and ctx.pref("claudeBetterModel", True) else "haiku"


# ---------------------------------------------------------------- Regeln für Claude

COMMON_RULES = """ALLGEMEINE REGELN
- Deutsch. Englische Fachbegriffe aus dem Material beibehalten.
- Halte dich an das Material; erfinde keine Fakten. Ergänze nur, was zum Verständnis zwingend nötig ist.
- Formeln in Unicode (x², xᵢ, ∑, ∫, √, ≤, ≠, →, ∀, ∈, griechische Buchstaben), kein LaTeX.
- Markdown: ##-Überschriften, Listen, **fett** für Begriffe, Tabellen wo sinnvoll. Keine Floskeln oder Einleitungssätze.
- Der Text kann aus Folien/OCR stammen (Bruchstücke, Seitenzahlen) – rekonstruiere den Sinn."""

RULES = {
    "summary": """ZUSAMMENFASSUNG ("summary": {"title": "...", "markdown": "..."})
- 2–3 Sätze Überblick, dann pro Abschnitt eine ##-Überschrift mit Kernaussagen als Stichpunkte, **Definitionen**, Formeln (Variablen erklären), kurzes Beispiel wo hilfreich.
- Am Ende „## Prüfungsrelevant“ (3–6 Punkte) und „## Selbsttest“ (3–5 Fragen ohne Lösung).
- Länge etwa 10–15 % des Materials, höchstens ~1200 Wörter.""",
    "flashcards": """KARTEIKARTEN ("flashcards": [{"front": "...", "back": "...", "topic": "..."}], Anzahl: {n})
- Eine Sache pro Karte. Vorderseite: Frage oder Begriff (≤ 120 Zeichen). Rückseite: knapp und vollständig (1–4 Sätze oder Formel + Bedeutung).
- Mischung: Definitionen, Formeln, Zusammenhänge („Warum …?“, „Unterschied zwischen …?“), Rechen-/Lösungsschritte.
- Nichts Triviales, keine Duplikate (auch nicht zu den vorhandenen Karten unten). "topic" = passender Thementitel.""",
    "quiz": """QUIZ ("quiz": {"title": "...", "questions": [...]}, Anzahl: {n})
- Etwa {open} % offene Fragen, sonst Single-Choice. Prüfe Verständnis, nicht Folienwortlaut.
- Single-Choice: {"type": "single", "prompt": "...", "options": ["…","…","…","…"], "correctIndex": 0–3, "explanation": "1–2 Sätze", "topic": "..."} – genau eine richtig, plausible Distraktoren, Position der richtigen Antwort variieren.
- Offen: {"type": "open", "prompt": "...", "answer": "Musterlösung", "explanation": "...", "topic": "..."}""",
    "topics": """THEMEN ("topics": ["...", ...], 2–8 Einträge)
- Kapitel-Ebene, prägnante Titel. Passt ein vorhandenes Thema (Liste unten), übernimm dessen Titel exakt; neue nur, wenn wirklich neu.""",
    "exerciseCards": "",  # Text entsteht in job_spec (je nach beigefügten Übungen)
    "kernpunkte": """KERNPUNKTE ("kernpunkte": ["...", ...], 6–15 Einträge)
- Das Wichtigste in knappen Stichpunkten (Definitionen, Formeln, zentrale Aussagen). Grundlage für das Cheat Sheet des Moduls.""",
    "mockExam": """PROBEKLAUSUR ("mockExam": {"title": "...", "markdown": "..."})
- Neue Aufgaben im Stil der Vorlage (Aufbau, Aufgabentypen, Umfang, Punkteverteilung) – nicht abschreiben. Bearbeitungszeit: {minutes} Minuten, Schwierigkeit: {difficulty}.
- Titel, Hinweise (Zeit, Hilfsmittel, Gesamtpunkte), dann „## Aufgabe 1 (x Punkte)“ mit Teilaufgaben a), b) …
- Am Ende „## Lösungen“ mit vollständigen Musterlösungen und Punkteschema.""",
    "examNotes": """KLAUSURNOTIZEN ("examNotes": ["...", ...], 4–10 Einträge)
- Aufgabentypen, Gewichtung, wiederkehrende Themen, typische Fallen – Grundlage für „Das musst du können“.""",
    "cheatSheet": """CHEAT SHEET ("cheatSheet": "Markdown")
- Höchstens so viel, wie auf zwei Seiten passt. Pro Thema eine ##-Überschrift, darunter nur knappe Stichpunkte:
  Definitionen, Formeln (Variablen erklärt), Regeln/Sätze, Merksätze, typische Fallen. Kein Fließtext.""",
    "mustKnow": """DAS MUSST DU KÖNNEN ("mustKnow": "Markdown")
- „## Unverzichtbar“: die 5–10 wichtigsten Fähigkeiten/Inhalte, je ein Satz warum.
- „## Typische Aufgabentypen“: aus Altklausuren/Übungen, jeweils mit kurzem Lösungsrezept (fehlen Altklausuren: aus Übungen ableiten und so kennzeichnen).
- „## Häufige Fehler“ und „## Selbsttest“ (8–12 kurze Fragen ohne Lösungen).""",
    "studyPlan": """LERNPLAN ("studyPlan": {"title": "...", "markdown": "..."})
- Kurze Strategie; dann pro Woche „## KW xx (Datum–Datum)“ mit Zielen, Themen, Übungen/Altklausuren, Wiederholungen.
- Schwache Themen zuerst und öfter, letzte Woche vor der Klausur als Prüfungssimulation. Realistisch: der Student arbeitet nebenbei als Werkstudent.""",
}


SKELETON = {
    "summary": {"title": "…", "markdown": "…"},
    "flashcards": [{"front": "…", "back": "…", "topic": "…"}],
    "exerciseCards": [{"exercise": "Titel der Übung", "cards": [{"front": "…", "back": "…", "topic": "…"}]}],
    "quiz": {"title": "…", "questions": [{"type": "single", "prompt": "…", "options": ["…", "…", "…", "…"], "correctIndex": 2,
                                          "explanation": "…", "topic": "…"},
                                         {"type": "open", "prompt": "…", "answer": "…", "explanation": "…", "topic": "…"}]},
    "topics": ["…"],
    "kernpunkte": ["…"],
    "mockExam": {"title": "…", "markdown": "…"},
    "examNotes": ["…"],
    "cheatSheet": "…Markdown…",
    "mustKnow": "…Markdown…",
    "studyPlan": {"title": "…", "markdown": "…"},
}

# ---------------------------------------------------------------- Planen

def wanted_outputs(kind, ctx, text_len):
    """Welche Teile ein automatisches Materialpaket liefern soll."""
    cards = int(ctx.pref("claudeCardsPerLecture", 10))  # genau so viele Hauptkarten – mehr nur auf Wunsch
    questions = max(4, min(10, text_len // 5000))
    out = {"topics": True, "kernpunkte": True}
    if kind in EXAM_KINDS:
        out = {"topics": True, "examNotes": True}
        if ctx.pref("claudeMockExams", True):
            out["mockExam"] = True
        return out
    if ctx.pref("claudeCards", True):
        out["flashcards"] = cards
    if ctx.pref("claudeQuizzes", True) and kind not in {"notiz"}:
        out["quiz"] = questions
    if ctx.pref("claudeSummaries", True) and kind in {"vorlesung", "skript", "sonstiges"}:
        out["summary"] = True
    return out


REQUEST_LABEL = {"flashcards": "Karteikarten", "summary": "Zusammenfassung", "quiz": "Quiz", "topics": "Themen",
                 "mockExam": "Probeklausur", "cheatSheet": "Cheat Sheet", "mustKnow": "Das musst du können",
                 "studyPlan": "Lernplan"}


def nfc(text):
    """macOS speichert Umlaute in Dateinamen oft zerlegt (U + ¨) – für Vergleiche vereinheitlichen."""
    return unicodedata.normalize("NFC", text or "")


def natural_key(title):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", title)]


def unique_materials(mod, status):
    """Offene Materialien eines Moduls ohne Doppelungen (z. B. Notebook + HTML-Export, mit/ohne Widgets).
    Allgemeines („Sonstiges“) und sehr Kurzes wird nicht automatisch aufbereitet – nur per Auftrag."""
    keep = {m["id"] for m in distinct_materials(mod) if m.get("charCount", 0) >= 400 and m.get("kind") != "sonstiges"}
    return [m for m in mod.get("materials", []) if m["id"] in keep and not status["processed"].get(m["id"], {}).get("complete")]


def distinct_materials(mod):
    """Fertig eingelesene Materialien ohne Doppelungen (Notebook + HTML/PDF-Export, mit/ohne Widgets …)."""
    ext_rank = {"ipynb": 0, "pdf": 1, "pptx": 2, "docx": 3, "md": 4, "txt": 5, "html": 9}
    best = {}
    for m in mod.get("materials", []):
        if m.get("status") != "ready":
            continue
        key = re.sub(r"\s*\((html|pdf|ipynb)\)\s*$", "", nfc(m.get("title", "")), flags=re.I)
        key = re.sub(r"\s*[-–]\s*(mit|ohne) widgets\s*$", "", key, flags=re.I)
        key = re.sub(r"\s*[-–]\s*(jupyter|pdf|html|notebook)[- ]?version\s*$", "", key, flags=re.I).strip().lower()
        rank = ext_rank.get(m.get("fileName", "").rsplit(".", 1)[-1].lower(), 6)
        if key not in best or rank < best[key][0]:
            best[key] = (rank, m)
    keep = {m["id"] for _, m in best.values()}
    return [m for m in mod.get("materials", []) if m["id"] in keep]


LECTURE_NO = re.compile(r"(?:^|\b)(?:l|vl|lecture|vorlesung|kap(?:itel)?\.?|chapter)\s*0*(\d{1,2})(?![\d.])", re.I)
EXERCISE_NO = re.compile(r"(?:^|\b)(?:übung(?:sblatt)?|uebung(?:sblatt)?|exercise(?:\s*sheet)?|blatt|sheet|assignment|tutorial|ü)\s*0*(\d{1,2})(?![\d.])", re.I)


TITLE_DATE = re.compile(r"(\d{1,2})\s*[.\-/]\s*(\d{1,2})\s*[.\-/]\s*(\d{4})")


def material_date(m):
    return parse_date(m.get("sourceModified") or "") or parse_date(m.get("addedAt") or "")


def title_date(m):
    hit = TITLE_DATE.search(m.get("title", ""))
    if not hit:
        return None
    try:
        return dt.datetime(int(hit.group(3)), int(hit.group(2)), int(hit.group(1)), tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def lecture_day(m):
    """Tag der Vorlesung: Datum im Titel („Vorlesung 13.10.2026“), sonst Hochlade-Datum."""
    return title_date(m) or material_date(m)


def sheet_number(m):
    """Nummer eines Übungsblatts bzw. einer Lösung („Übungsblatt 2“, „Exercise 2“, „Aufgabe P2.1“)."""
    title = nfc(m.get("title", ""))
    hit = EXERCISE_NO.search(title) or re.search(r"\baufgabe\s*p?(\d{1,2})\.\d", title, re.I)
    return int(hit.group(1)) if hit else None


def exercise_group(m):
    """Was zu einer Übung gehört, bekommt denselben Schlüssel: gleiche Blattnummer (Titel oder Dateiname wie
    „01 - Präsentation.pdf“) oder alle Anhänge derselben WueCampus-Abgabe."""
    n = sheet_number(m)
    if n is None and m.get("kind") in EXERCISE_KINDS:
        hit = re.match(r"\s*0*(\d{1,2})\s*[-_.]", nfc(m.get("originalName", "")))
        n = int(hit.group(1)) if hit else None
    if n is not None:
        return ("blatt", n)
    src = m.get("sourceKey") or ""
    if src.startswith("wue:assignfile:"):
        return ("abgabe", src.split(":")[2])
    return ("einzeln", m["id"])


def is_exercise_material(m):
    return m.get("kind") in EXERCISE_KINDS or (m.get("sourceKey") or "").startswith("wue:assignfile:")


def primary_score(m):
    """Welche Datei einer Übung ist das eigentliche Aufgabenblatt?"""
    t = nfc(m.get("title", "")).lower()
    score = 0
    if re.search(r"blatt|(?<!cheat )sheet|description|angabe|aufgabenstellung|assignment", t):
        score += 2
    if m.get("kind") == "uebung":
        score += 1
    if m.get("kind") == "loesung" or re.search(r"lösung|loesung|solution", t):
        score -= 5
    return (score, m.get("charCount", 0))


def match_exercises(mod):
    """Bildet Übungs-Einheiten (Aufgabenblatt + Beilagen wie Folien, Code, Musterlösungen) und ordnet sie ihrer
    Vorlesung zu – über die Nummer („Übungsblatt 2“ ↔ „L2“, „Kap.2“, „lecture 2“), sonst über das Datum
    (bis 10 Tage nach der Vorlesung). Liefert ({Übung: Vorlesung}, {Beilage: Übung oder Vorlesung}, {Übungen})."""
    mats = distinct_materials(mod)
    exercise_mats = [m for m in mats if is_exercise_material(m)]
    lectures = [m for m in mats if m.get("kind") in {"vorlesung", "skript"} and not is_exercise_material(m)]
    numbered, ordinal, last_day = {}, 0, None
    far = dt.datetime.max.replace(tzinfo=dt.timezone.utc)
    for m in sorted([m for m in lectures if m.get("kind") == "vorlesung"],
                    key=lambda m: (lecture_day(m) or far, natural_key(m.get("title", "")))):
        day = (lecture_day(m) or far).date()
        if day != last_day:  # „Teil 1/Teil 2“ am selben Tag = eine Vorlesung
            ordinal += 1
            last_day = day
        hit = LECTURE_NO.search(nfc(m.get("title", "")))
        # Eine Nummer aus einem Datum im Titel („13.10.“) ist keine Vorlesungsnummer
        number = int(hit.group(1)) if hit else (None if title_date(m) else m.get("lectureNumber"))
        numbered.setdefault(number or ordinal, m["id"])
    for m in lectures:
        hit = LECTURE_NO.search(nfc(m.get("title", "")))
        if m.get("kind") == "skript" and hit:
            numbered.setdefault(int(hit.group(1)), m["id"])

    def lecture_for(m, number=None):
        n = number if number is not None else sheet_number(m)
        if n is not None and n in numbered:
            return numbered[n]
        d = material_date(m)
        before = [(lecture_day(l), l) for l in lectures
                  if d and lecture_day(l) and lecture_day(l) <= d and (d - lecture_day(l)).days <= 10]
        return max(before, key=lambda b: b[0])[1]["id"] if before else None

    groups = {}
    for m in exercise_mats:
        groups.setdefault(exercise_group(m), []).append(m)
    lecture_of, attach_of, primaries = {}, {}, set()
    for key, members in groups.items():
        best = max(members, key=primary_score)
        number = key[1] if key[0] == "blatt" else None
        if primary_score(best)[0] < -1:  # nur Musterlösungen, kein Blatt: Beilage der Vorlesung
            for sol in members:
                if (l := lecture_for(sol, number)):
                    attach_of[sol["id"]] = l
            continue
        primaries.add(best["id"])
        if (l := lecture_for(best, number)):
            lecture_of[best["id"]] = l
        for other in members:
            if other is not best:
                attach_of[other["id"]] = best["id"]
    return lecture_of, attach_of, primaries


def known_docs(ctx):
    """Dokumente in Kompass – inklusive solcher, die noch im Eingang auf die Übernahme warten."""
    docs = {d["id"].upper(): d for d in ctx.data.get("docs", [])}
    for f in ctx.inbox.glob("*.json") if ctx.inbox.exists() else []:
        for d in (read_json(f) or {}).get("docs", []):
            docs[d["id"].upper()] = d
    return docs


def summary_docs(ctx, docs, material_id, state):
    """Vorhandene Zusammenfassungen eines Materials (gelöschte werden nicht wiederbelebt)."""
    ids = [i.upper() for i in (state.get("summaryDocIDs") or {}).values()]
    found = [docs[i] for i in ids if i in docs]
    if not found and not ids:
        found = [d for d in docs.values() if d.get("kind") == "zusammenfassung"
                 and material_id.upper() in {x.upper() for x in d.get("sourceMaterialIDs", [])}]
    return found


def write_job(job):
    d = WORK / job["id"]
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    text = job.pop("text", "")
    (d / "text.txt").write_text(text, encoding="utf-8")
    write_json_atomic(d / "job.json", job)


def agent_prompt(job_id):
    s = f"python3 {SCRIPT}"
    return (
        "Du erstellst Lernmaterial für die Lern-App Kompass. Arbeite genau so – nutze nur diese beiden Befehle, "
        "lies keine weiteren Dateien und verwende keine anderen Werkzeuge:\n"
        f"1. Führe aus: {s} show {job_id}\n"
        "   Das zeigt Auftrag, Regeln, Ausgabeformat und den Materialtext. Steht am Ende „Weiter mit: … --seite 2“,\n"
        "   lies auch alle weiteren Seiten mit genau diesem Befehl.\n"
        "2. Erstelle das Ergebnis und übergib es mit EINEM Befehl (das JSON zwischen den Markern):\n"
        f"   {s} submit {job_id} <<'KOMPASS_JSON'\n   {{ … }}\n   KOMPASS_JSON\n"
        "3. Meldet submit einen Fehler, behebe nur diesen und übergib erneut.\n"
        "Antworte am Ende mit einer einzigen Zeile, was erstellt wurde."
    )


def cmd_plan(ctx, args):
    status = ctx.status()
    jobs = []
    if WORK.exists():
        shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True, exist_ok=True)
    with open(WORK / "run.json", "w") as f:
        json.dump({"started": now_iso(), "done": []}, f)

    # 1) Aufträge aus der App
    req_files = sorted(ctx.requests.glob("*.json"), key=lambda p: p.stat().st_mtime) if ctx.requests.exists() else []
    for rf in req_files[:MAX_REQUESTS_PER_RUN]:
        r = read_json(rf)
        if not r:
            continue
        mod = ctx.module(r.get("moduleID", ""))
        if not mod:
            rf.unlink(missing_ok=True)
            continue
        kind = r.get("kind")
        heavy = kind in {"mockExam", "cheatSheet", "mustKnow", "studyPlan"}
        model = model_for(heavy, ctx)
        texts, used = [], 0
        budget = REQUEST_CHARS[model]
        mats = [m for m in mod.get("materials", []) if m.get("id", "").upper() in {x.upper() for x in r.get("materialIDs", [])}]
        for m in mats:
            t = ctx.text(mod["id"], m["id"])
            if not t:
                continue
            t = clean(t)
            share = max(4000, budget // max(1, len(mats)))
            take = t[:min(share, budget - used)]
            if not take:
                break
            used += len(take)
            texts.append(f"=== {KIND_LABEL.get(m.get('kind'), 'Material')}: {m.get('title')} ===\n{take}"
                         + ("\n[… gekürzt]" if len(take) < len(t) else ""))
        job = {"id": f"a-{r['id'][:8].lower()}", "type": "request", "model": model, "requestID": r["id"],
               "requestFile": str(rf), "moduleID": mod["id"], "kind": kind, "options": r,
               "materialIDs": [m["id"] for m in mats],
               "label": f"{short(mod)} · {REQUEST_LABEL.get(kind, kind)} (Auftrag)", "text": "\n\n".join(texts)}
        write_job(job)
        jobs.append(job)

    remaining = 0
    limit = args.limit or int(ctx.pref("claudeBatchLimit", 50))
    planned = 0
    baselines = {}  # Material-ID → (Fingerabdruck, Text): Stand merken, ohne etwas zu erstellen

    # 2) Geänderte Materialien (z. B. korrigierte Folien aus WueCampus) – nur die Änderungen nacharbeiten
    if ctx.pref("claudeAuto", True):
        docs = known_docs(ctx)
        for mod in ctx.data.get("modules", []):
            if mod.get("archived"):
                continue
            for m in mod.get("materials", []):
                state = status["processed"].get(m["id"], {})
                if not state.get("complete") or m.get("status") != "ready":
                    continue
                raw = ctx.text(mod["id"], m["id"])
                if not raw:
                    continue
                text = clean(raw)
                sha = fingerprint(text)
                if state.get("fingerprint") == sha:
                    continue
                old = load_snapshot(m["id"])
                if not state.get("fingerprint") or old is None:
                    baselines[m["id"]] = (sha, text)  # vor dieser Funktion verarbeitet: aktuellen Stand übernehmen
                    continue
                ch = text_changes(old, text)
                if ch["changed"] < MINOR_CHANGE_CHARS or ch["ratio"] < MINOR_CHANGE_RATIO:
                    baselines[m["id"]] = (sha, text)
                    continue
                if planned >= limit:
                    remaining += 1
                    continue
                summaries = summary_docs(ctx, docs, m["id"], state)
                single = len(summaries) == 1
                kern_key = f"{m['id']}#0" if state.get("parts", 1) == 1 else f"{m['id']}#update"
                old_kern = status["modules"].get(mod["id"], {}).get("kernpunkte", {}).get(kern_key, {}).get("points", [])
                changes = "\n\n".join(ch["added"])
                if ch["ratio"] > 0.5:
                    changes = text  # größtenteils neu: ganzen Text nehmen
                body = ["GEÄNDERTE UND NEUE STELLEN (mit „>>“ markiert)\n\n" + changes[:UPDATE_CHARS]
                        + ("\n[… gekürzt]" if len(changes) > UPDATE_CHARS else "")]
                if ch["removed"]:
                    body.append("ENTFERNT\n" + "\n".join(f"- {x}" for x in ch["removed"][:80]))
                if single:
                    body.append(f"BISHERIGE ZUSAMMENFASSUNG („{summaries[0].get('title', '')}“)\n\n{summaries[0].get('markdown', '')}")
                if old_kern:
                    body.append("BISHERIGE KERNPUNKTE\n" + "\n".join(f"- {x}" for x in old_kern))
                outputs = {"flashcards": 0, "topics": True, "kernpunkte": True}
                if single and ctx.pref("claudeSummaries", True):
                    outputs["summary"] = True
                if not ctx.pref("claudeCards", True):
                    outputs.pop("flashcards")
                job = {"id": f"u-{m['id'][:8].lower()}", "type": "update", "model": "haiku",
                       "moduleID": mod["id"], "materialID": m["id"], "materialKind": m.get("kind", "sonstiges"),
                       "materialTitle": m.get("title", ""), "outputs": outputs, "newFingerprint": sha,
                       "summaryDoc": {"id": summaries[0]["id"], "title": summaries[0].get("title", "")} if single else None,
                       "kernKey": kern_key, "label": f"{short(mod)} · {m.get('title', '')} (aktualisiert)",
                       "text": "\n\n".join(body)}
                write_job(job)
                (WORK / job["id"] / "neu.txt").write_text(text, encoding="utf-8")
                jobs.append(job)
                planned += 1

    # 3) Neue Materialien – reihum über die Module (nächste Klausur zuerst), im Modul chronologisch
    if ctx.pref("claudeAuto", True):
        far = dt.datetime(2100, 1, 1, tzinfo=dt.timezone.utc)
        queues = []
        for mod in ctx.data.get("modules", []):
            if mod.get("archived"):
                continue
            queue = []
            for m in unique_materials(mod, status):
                kind = m.get("kind", "sonstiges")
                prio = 0 if kind in LECTURE_KINDS else (1 if kind in EXERCISE_KINDS else 2)
                added = parse_date(m.get("addedAt", "")) or dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc)
                queue.append(((prio, m.get("lectureNumber") or 999, added, natural_key(m.get("title", ""))), m))
            if queue:
                queue.sort(key=lambda q: q[0])
                queues.append((ctx.exam_date(mod["id"]) or far, mod, [m for _, m in queue]))
        queues.sort(key=lambda q: q[0])
        cands = []
        while any(q[2] for q in queues):
            for _, mod, items in queues:
                if items:
                    cands.append((mod, items.pop(0)))
        lecture_of, attach_of, primaries = {}, {}, set()
        for mod in ctx.data.get("modules", []):
            a, b, c = match_exercises(mod)
            lecture_of.update(a)
            attach_of.update(b)
            primaries |= c
        cand_ids = {m["id"] for _, m in cands}
        done = lambda mid: status["processed"].get(mid, {}).get("complete")
        bundled = set()     # Übungen/Beilagen, die in diesem Plan schon in einem Paket stecken
        covered_now = {}    # Beilagen, deren Übung schon erledigt ist: nur vermerken, nichts erstellen

        def solutions_for(mod, target_id):
            """Beilagen einer Übung bzw. Vorlesung: Musterlösungen, Folien, Code, Tutorials."""
            out = []
            for sol in mod.get("materials", []):
                if attach_of.get(sol["id"]) == target_id and not done(sol["id"]):
                    t = ctx.text(mod["id"], sol["id"])
                    if t:
                        out.append((sol, clean(t)))
            return out

        def block(label, mat, text, limit_chars):
            take = text[:limit_chars]
            return f"=== {label}: {mat.get('title')} ===\n{take}" + ("\n[… gekürzt]" if len(take) < len(text) else "")

        for mod, m in cands:
            kind = m.get("kind", "sonstiges")
            if m["id"] in bundled:
                continue
            if m["id"] in attach_of:
                target = attach_of[m["id"]]
                if done(target):
                    covered_now[m["id"]] = target
                    continue
                if target in cand_ids:
                    continue  # kommt mit ihrer Übung bzw. Vorlesung dran
            is_exercise = m["id"] in primaries or kind in EXERCISE_KINDS
            lecture_id = lecture_of.get(m["id"]) if is_exercise else None
            if lecture_id and not done(lecture_id) and lecture_id in cand_ids:
                continue  # kommt zusammen mit ihrer Vorlesung dran
            if planned >= limit:
                remaining += 1
                continue
            raw = ctx.text(mod["id"], m["id"])
            if not raw:
                continue
            text = clean(raw)
            parts = split_parts(text)
            done_parts = set(status["processed"].get(m["id"], {}).get("doneParts", []))
            jtype = "exam" if kind in EXAM_KINDS else ("exercise" if is_exercise else "material")
            n_cards = int(ctx.pref("claudeCardsPerLecture", 10)) if ctx.pref("claudeCards", True) else 0

            # Vorlesung: zugehörige Übungen (+ deren Musterlösungen) gehen mit ins Paket – je 10 eigene Karten
            exercises, attachments = [], []
            if jtype == "material" and 0 not in done_parts:
                for ex in mod.get("materials", []):
                    if (lecture_of.get(ex["id"]) == m["id"] and not done(ex["id"]) and ex["id"] in cand_ids
                            and len(exercises) < MAX_EXERCISES_PER_LECTURE):
                        t = ctx.text(mod["id"], ex["id"])
                        if t:
                            exercises.append((ex, clean(t), solutions_for(mod, ex["id"])))
                            bundled.add(ex["id"])
                attachments = solutions_for(mod, m["id"])  # Lösungen ohne eigenes Blatt: Kontext zur Vorlesung
            elif jtype == "exercise":
                attachments = solutions_for(mod, m["id"])
            for ex, _, sols in exercises:
                bundled.update(sol["id"] for sol, _ in sols)
            bundled.update(sol["id"] for sol, _ in attachments)

            for i, part in enumerate(parts):
                if i in done_parts:
                    continue
                if planned >= limit:
                    remaining += 1
                    break
                outputs = wanted_outputs(kind, ctx, len(part))
                if "flashcards" in outputs and len(parts) > 1:
                    # 10 Karten pro Material – bei langen, geteilten Materialien auf die Teile verteilt
                    outputs["flashcards"] = max(3, round(outputs["flashcards"] / len(parts)))
                if jtype == "exercise":
                    outputs = {"topics": True, "kernpunkte": True}
                    if n_cards:
                        outputs["flashcards"] = n_cards
                first = i == 0
                ex_here = exercises if first else []
                att_here = attachments if first else []
                if ex_here and n_cards:
                    outputs["exerciseCards"] = n_cards
                blocks = [part]
                for ex, t, sols in ex_here:
                    blocks.append(block("ÜBUNG", ex, t, EXERCISE_CHARS))
                    blocks += [block(("MUSTERLÖSUNG" if sol.get("kind") == "loesung" else "BEILAGE") + f" ZU „{ex.get('title')}“", sol, st, SOLUTION_CHARS)
                               for sol, st in sols]
                blocks += [block("MUSTERLÖSUNG" if sol.get("kind") == "loesung" else "BEILAGE", sol, st, SOLUTION_CHARS) for sol, st in att_here]
                lecture_title = next((x.get("title") for x in mod.get("materials", []) if x["id"] == lecture_id), None)
                covered = [{"id": ex["id"], "title": ex.get("title", "")} for ex, _, _ in ex_here]
                covered += [{"id": sol["id"], "title": sol.get("title", "")} for _, _, sols in ex_here for sol, _ in sols]
                covered += [{"id": sol["id"], "title": sol.get("title", "")} for sol, _ in att_here]
                job = {"id": f"m-{m['id'][:8].lower()}-{i}", "type": jtype, "model": model_for("mockExam" in outputs, ctx),
                       "moduleID": mod["id"], "materialID": m["id"], "materialKind": kind,
                       "materialTitle": m.get("title", ""), "part": i, "parts": len(parts), "outputs": outputs,
                       "exercises": [{"id": ex["id"], "title": ex.get("title", "")} for ex, _, _ in ex_here],
                       "covers": covered, "lectureTitle": lecture_title,
                       "label": f"{short(mod)} · {m.get('title', '')}" + (f" (Teil {i + 1}/{len(parts)})" if len(parts) > 1 else "")
                                + (f" + {len(ex_here)} Übung" + ("en" if len(ex_here) > 1 else "") if ex_here else ""),
                       "text": "\n\n".join(blocks)}
                write_job(job)
                jobs.append(job)
                planned += 1

        if covered_now:
            with locked():
                st = ctx.status()
                for mid, target in covered_now.items():
                    st["processed"].setdefault(mid, {}).update({"complete": True, "coveredBy": target, "at": now_iso()})
                ctx.save_status(st)
            status = ctx.status()

    if baselines:
        with locked():
            st = ctx.status()
            for mid, (sha, text) in baselines.items():
                st["processed"].setdefault(mid, {})["fingerprint"] = sha
                save_snapshot(mid, text)
            ctx.save_status(st)
        status = ctx.status()

    # 4) Cheat Sheet / „Das musst du können“ je Modul (aus den Kernpunkten, wenig Text)
    synth = 0
    if ctx.pref("claudeCheatSheets", True) or ctx.pref("claudeMustKnow", True):
        for mod in ctx.data.get("modules", []):
            if mod.get("archived") or synth >= MAX_SYNTH_PER_RUN:
                continue
            ms = status["modules"].get(mod["id"], {})
            notes = ms.get("kernpunkte", {})
            if not notes:
                continue
            last = parse_date(ms.get("synthAt", "")) if ms.get("synthAt") else None
            new_since = ms.get("newSinceSynth", 0)
            # Erstes Mal sofort, danach höchstens wöchentlich (oder wenn sehr viel Neues dazukam)
            age = (dt.datetime.now(dt.timezone.utc) - last).days if last else None
            due = new_since > 0 and (last is None or age >= SYNTH_EVERY_DAYS or new_since >= 8)
            if not due:
                continue
            outputs = {}
            if ctx.pref("claudeCheatSheets", True):
                outputs["cheatSheet"] = True
            if ctx.pref("claudeMustKnow", True):
                outputs["mustKnow"] = True
            lines = []
            for mid, entry in sorted(notes.items(), key=lambda kv: kv[1].get("order", "")):
                lines.append(f"### {entry.get('title', '')}\n" + "\n".join(f"- {p}" for p in entry.get("points", [])))
            exam = ms.get("examNotes", [])
            text = "KERNPUNKTE DER MATERIALIEN\n\n" + "\n\n".join(lines)
            if exam:
                text += "\n\nKLAUSURNOTIZEN (aus Altklausuren)\n" + "\n".join(f"- {e}" for e in exam)
            job = {"id": f"s-{mod['id'][:8].lower()}", "type": "synthesis", "model": model_for(True, ctx),
                   "moduleID": mod["id"], "outputs": outputs, "label": f"{short(mod)} · Cheat Sheet & Das musst du können",
                   "text": text}
            write_job(job)
            jobs.append(job)
            synth += 1

    for j in jobs:
        # show/submit arbeiten im selben Datenordner wie der Plan
        jf = WORK / j["id"] / "job.json"
        data = read_json(jf)
        data["dataDir"] = str(ctx.root)
        write_json_atomic(jf, data)
    plan = {"jobs": [{"id": j["id"], "model": j["model"], "label": j["label"], "prompt": agent_prompt(j["id"])} for j in jobs],
            "remainingMaterials": remaining}
    if not jobs:
        plan["message"] = "Nichts zu tun."
    print(json.dumps(plan, ensure_ascii=False, indent=1))


# ---------------------------------------------------------------- Anzeigen

def load_job(job_id):
    d = WORK / job_id
    job = read_json(d / "job.json")
    if not job:
        sys.exit(f"Unbekanntes Paket: {job_id} (erst „plan“ ausführen)")
    return job, (d / "text.txt").read_text(encoding="utf-8")


def module_context(ctx, mod):
    topics = [t.get("title") for t in mod.get("topics", [])]
    fronts = [c.get("front", "") for c in ctx.data.get("flashcards", []) if c.get("moduleID", "").upper() == mod["id"].upper()]
    out = [f"MODUL: {mod.get('name')}" + (f" ({mod.get('code')})" if mod.get("code") else "")]
    exam = ctx.exam_date(mod["id"])
    if exam:
        out.append(f"Klausur: {exam.astimezone().strftime('%d.%m.%Y')}")
    out.append("Vorhandene Themen: " + ("; ".join(topics) if topics else "(noch keine)"))
    if fronts:
        out.append("Vorhandene Karteikarten (nicht wiederholen): " + " | ".join(f[:60] for f in fronts[-60:]))
    return "\n".join(out)


def job_spec(ctx, job):
    """Regeln + erwartetes JSON für ein Paket."""
    mod = ctx.module(job["moduleID"]) or {"name": "?", "id": job["moduleID"]}
    parts, keys = [], []
    t = job["type"]
    if t in {"material", "exercise", "exam"}:
        outs = job["outputs"]
        what = {"material": "Lernmaterial", "exercise": "Übungsmaterial (Lösungswege und Methoden stehen im Vordergrund)",
                "exam": "eine Altklausur/Probeklausur"}[t]
        head = f"AUFTRAG: Bereite {what} auf: „{job['materialTitle']}“"
        if job["parts"] > 1:
            head += f" – Teil {job['part'] + 1} von {job['parts']}"
        parts.append(head)
        for k in ["summary", "flashcards", "exerciseCards", "quiz", "mockExam", "topics", "kernpunkte", "examNotes"]:
            if k in outs:
                keys.append(k)
                rule = RULES[k]
                if k == "flashcards":
                    n = outs[k]
                    if t == "exercise":
                        rule = (f'KARTEIKARTEN ("flashcards": [{{"front": "...", "back": "...", "topic": "..."}}], genau {n} Karten zu dieser Übung)\n'
                                "- Zu den Aufgaben: Lösungswege, Methoden, nötige Formeln/Sätze, typische Fallen – so, dass man ähnliche Aufgaben selbst lösen kann.\n"
                                + ("- Liegt eine MUSTERLÖSUNG bei, richte die Antworten danach.\n" if job.get("covers") else "")
                                + (f"- Die Übung gehört zur Vorlesung „{job['lectureTitle']}“.\n" if job.get("lectureTitle") else "")
                                + "- Nach Wichtigkeit sortiert. Keine Duplikate zu den vorhandenen Karten unten.")
                    else:
                        rule = (f'KARTEIKARTEN ("flashcards": [{{"front": "...", "back": "...", "topic": "..."}}], genau {n} Hauptkarten)\n'
                                f"- Die {n} wichtigsten Karten zu diesem Material, nach Wichtigkeit sortiert (Wichtigstes zuerst) – das, was man unbedingt können muss.\n"
                                + ("- Nur Inhalte der Vorlesung – die Übungen bekommen eigene Karten (siehe ÜBUNGSKARTEN).\n" if job.get("exercises") else "")
                                + "- Eine Sache pro Karte. Vorderseite: Frage oder Begriff (≤ 120 Zeichen). Rückseite: knapp und vollständig (1–4 Sätze oder Formel + Bedeutung).\n"
                                "- Nichts Triviales, keine Duplikate (auch nicht zu den vorhandenen Karten unten). \"topic\" = passender Thementitel.")
                if k == "exerciseCards":
                    n = outs[k]
                    titles = "; ".join(f"„{e['title']}“" for e in job.get("exercises", []))
                    rule = (f'ÜBUNGSKARTEN ("exerciseCards": [{{"exercise": "Titel der Übung", "cards": [{{"front": "...", "back": "...", "topic": "..."}}]}}], für JEDE Übung genau {n} Karten)\n'
                            f"- Übungen: {titles}\n"
                            "- Zu den Aufgaben: Lösungswege, Methoden, nötige Formeln/Sätze, typische Fallen – so, dass man ähnliche Aufgaben selbst lösen kann.\n"
                            "- Liegt eine MUSTERLÖSUNG bei, richte die Antworten danach. Keine Überschneidung mit den Vorlesungskarten.")
                if k == "quiz":
                    rule = rule.replace("{n}", f"{outs[k]} Fragen").replace("{open}", "30")
                if k == "mockExam":
                    rule = rule.replace("{minutes}", "90").replace("{difficulty}", "Klausurniveau")
                parts.append(rule)
    elif t == "update":
        outs = job["outputs"]
        parts.append(f"AUFTRAG: Das Material „{job['materialTitle']}“ wurde geändert (z. B. korrigierte oder erweiterte Folien). "
                     "Unten stehen nur die geänderten Stellen. Bringe die vorhandenen Lerninhalte auf den neuen Stand – "
                     "erstelle nichts doppelt und lass Unverändertes, wie es ist.")
        rules = {
            "summary": """ZUSAMMENFASSUNG ("summary": {"title": "...", "markdown": "..."})
- Überarbeite die BISHERIGE ZUSAMMENFASSUNG: Neues an passender Stelle einarbeiten, Überholtes korrigieren oder streichen, alles andere unverändert übernehmen. Gib die vollständige neue Fassung zurück.""",
            "flashcards": f"""KARTEIKARTEN ("flashcards": [{{"front": "...", "back": "...", "topic": "..."}}], 0–{UPDATE_MAX_CARDS} Stück)
- Nur zu neuen oder geänderten Inhalten. Gibt es nichts Neues, das sich lohnt: leere Liste.""",
            "topics": """THEMEN ("topics": [...], 0–5 Einträge)
- Nur wirklich neue Themen; sonst leere Liste. Vorhandene Titel (Liste unten) exakt übernehmen.""",
            "kernpunkte": """KERNPUNKTE ("kernpunkte": [...], 6–15 Einträge)
- Die vollständige, aktualisierte Liste der Kernpunkte dieses Materials (BISHERIGE KERNPUNKTE anpassen, falls vorhanden).""",
        }
        for k in ["summary", "flashcards", "topics", "kernpunkte"]:
            if k in outs:
                keys.append(k)
                parts.append(rules[k])
    elif t == "synthesis":
        parts.append("AUFTRAG: Erstelle aus den Kernpunkten aller bisher bearbeiteten Materialien dieses Moduls "
                     "die Übersichten für die Klausurvorbereitung (vollständig neu, nicht nur Ergänzungen).")
        for k in ["cheatSheet", "mustKnow"]:
            if k in job["outputs"]:
                keys.append(k)
                parts.append(RULES[k])
    elif t == "request":
        o = job["options"]
        kind = job["kind"]
        focus = f" Schwerpunkt: {o['focus']}." if o.get("focus") else ""
        diff = ["leicht", "mittel", "Klausurniveau"][max(0, min(2, int(o.get("difficulty") or 1)))]
        parts.append(f"AUFTRAG aus der App: {kind}.{focus}"
                     + ("" if job["materialIDs"] else " Es wurde kein Material gewählt – nutze fundiertes Fachwissen zum Modul und kennzeichne das."))
        mapping = {"flashcards": "flashcards", "summary": "summary", "quiz": "quiz", "topics": "topics",
                   "mockExam": "mockExam", "cheatSheet": "cheatSheet", "mustKnow": "mustKnow", "studyPlan": "studyPlan"}
        k = mapping.get(kind, "summary")
        keys.append(k)
        rule = RULES[k]
        rule = rule.replace("{n}", str(o.get("count") or (20 if k == "flashcards" else 10)))
        rule = rule.replace("{open}", str(int(round((o.get("openShare") or 0.3) * 100))))
        rule = rule.replace("{minutes}", str(o.get("minutes") or 90)).replace("{difficulty}", diff)
        parts.append(rule)
        if k == "studyPlan":
            topics = [f"- {tp.get('title')}: Sicherheit {int(round((tp.get('confidence') or 0) * 100))} %"
                      + ("" if tp.get("covered") else " (noch nicht behandelt)") for tp in mod.get("topics", [])]
            parts.append(f"Heute: {dt.date.today().strftime('%d.%m.%Y')}. Wochenziel: {mod.get('weeklyGoalHours', 6)} h Selbststudium.\n"
                         "Themenstand:\n" + ("\n".join(topics) if topics else "(keine Themen erfasst)"))
    parts.append(COMMON_RULES)
    example = {k: SKELETON[k] for k in keys}
    parts.append("AUSGABE: Genau ein JSON-Objekt mit genau diesen Schlüsseln (Zeilenumbrüche in Markdown als \\n):\n"
                 + json.dumps(example, ensure_ascii=False))
    parts.append(module_context(ctx, mod))
    return "\n\n".join(parts), keys


PAGE_CHARS = 20_000  # je Seite (inkl. Regeln) – bleibt sicher unter der Ausgabegrenze von Bash (~30 000 Zeichen)


def cmd_show(ctx, args):
    """Seite 1: Regeln + Anfang des Materials; weitere Seiten: Rest des Materials."""
    job, text = load_job(args.job)
    text = text if text.strip() else "(kein Material)"
    spec, _ = job_spec(ctx, job)
    first = max(5_000, PAGE_CHARS - len(spec))
    pages = [text[:first]] + [text[i:i + PAGE_CHARS] for i in range(first, len(text), PAGE_CHARS)]
    page = max(1, min(args.seite, len(pages)))
    if page == 1:
        print(spec)
        print("\n================ MATERIAL ================\n")
    print(pages[page - 1])
    if page < len(pages):
        print(f"\n— Seite {page} von {len(pages)}. Lies zuerst ALLE Seiten, bevor du submit ausführst. Weiter mit:\n"
              f"python3 {SCRIPT} show {args.job} --seite {page + 1}")


# ---------------------------------------------------------------- Prüfen & übergeben

def parse_result(raw):
    raw = raw.strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)
    start, end = raw.find("{"), raw.rfind("}")
    if start < 0 or end < 0:
        raise ValueError("Kein JSON-Objekt gefunden.")
    return json.loads(raw[start:end + 1], strict=False)


def s(v):
    return v.strip() if isinstance(v, str) else ""


def check_cards(v, errors, minimum, taken=None):
    """Gültige Karten ohne Doppelungen. `taken`: Vorderseiten, die es im Modul schon gibt – die App würde
    solche Karten verwerfen, deshalb muss der Agent sie ersetzen (sonst fehlen Karten an der Sollzahl)."""
    taken = set() if taken is None else taken
    cards = []
    for c in v if isinstance(v, list) else []:
        if isinstance(c, dict) and s(c.get("front")) and s(c.get("back")):
            cards.append({"front": s(c["front"])[:300], "back": s(c["back"])[:1500], "topic": s(c.get("topic"))[:80]})
    seen, unique, dupes = set(), [], []
    for c in cards:
        k = c["front"].lower()
        if k in taken:
            dupes.append(c["front"])
        elif k not in seen:
            seen.add(k)
            unique.append(c)
    if len(unique) < minimum:
        hint = (" Diese Fragen gibt es im Modul schon – ersetze sie durch neue: " + " | ".join(dupes[:10])) if dupes else ""
        errors.append(f"flashcards: nur {len(unique)} gültige Karten – es müssen {minimum} sein (je front + back, keine doppelten).{hint}")
    return unique


def check_questions(v, errors, minimum):
    out = []
    for q in v if isinstance(v, list) else []:
        if not isinstance(q, dict) or not s(q.get("prompt") or q.get("question")):
            continue
        prompt = s(q.get("prompt") or q.get("question"))
        typ = s(q.get("type")).lower()
        opts = [s(o) for o in q.get("options", []) if s(o)] if isinstance(q.get("options"), list) else []
        if typ.startswith("single") or (typ != "open" and len(opts) >= 2):
            idx = q.get("correctIndex", q.get("correct_index"))
            if not isinstance(idx, int) or not (0 <= idx < len(opts)) or not (3 <= len(opts) <= 6):
                continue
            out.append({"id": new_id(), "type": "single", "prompt": prompt, "options": opts, "correctIndex": idx,
                        "answer": opts[idx], "explanation": s(q.get("explanation")), "topic": s(q.get("topic"))})
        else:
            ans = s(q.get("answer")) or s(q.get("explanation"))
            if not ans:
                continue
            out.append({"id": new_id(), "type": "open", "prompt": prompt, "options": [], "correctIndex": None,
                        "answer": ans, "explanation": s(q.get("explanation")), "topic": s(q.get("topic"))})
    if len(out) < minimum:
        errors.append(f"quiz.questions: nur {len(out)} gültige Fragen (mindestens {minimum}). "
                      "Single: options (3–6) + correctIndex; offen: answer.")
    return out


def check_doc(v, key, errors, min_len=200):
    if isinstance(v, str):
        md, title = v, ""
    elif isinstance(v, dict):
        md, title = s(v.get("markdown")), s(v.get("title"))
    else:
        md, title = "", ""
    if len(md) < min_len:
        errors.append(f"{key}: Markdown fehlt oder ist zu kurz.")
    return title, md


def check_list(v, key, errors, minimum=1, maxlen=300):
    items = [s(x)[:maxlen] for x in v if s(x)] if isinstance(v, list) else []
    if len(items) < minimum:
        errors.append(f"{key}: Liste fehlt oder ist leer.")
    return items


def module_fronts(ctx, module_id):
    """Vorderseiten aller Karten des Moduls – in der App und in noch nicht übernommenen Lieferungen."""
    mid = module_id.upper()
    fronts = {s(c.get("front")).lower() for c in ctx.data.get("flashcards", []) if c.get("moduleID", "").upper() == mid}
    for f in ctx.inbox.glob("*.json") if ctx.inbox.exists() else []:
        d = read_json(f) or {}
        if str(d.get("moduleID", "")).upper() == mid:
            fronts |= {s(c.get("front")).lower() for c in d.get("flashcards", [])}
    return fronts


def cmd_submit(ctx, args):
    job, _ = load_job(args.job)
    raw = Path(args.file).read_text(encoding="utf-8") if args.file else sys.stdin.read()
    try:
        res = parse_result(raw)
    except Exception as e:
        sys.exit(f"FEHLER: Ergebnis ist kein gültiges JSON ({e}). Übergib genau ein JSON-Objekt.")
    _, keys = job_spec(ctx, job)
    errors = []
    mod = ctx.module(job["moduleID"])
    if not mod:
        sys.exit("FEHLER: Modul existiert nicht mehr – Paket verworfen.")
    code = short(mod)
    src = [job["materialID"]] if job.get("materialID") else job.get("materialIDs", [])
    delivery = {"version": 1, "id": new_id(), "createdAt": now_iso(), "moduleID": mod["id"], "title": job["label"],
                "flashcards": [], "docs": [], "quizzes": [], "topics": []}
    covered = job.get("materialKind") in LECTURE_KINDS or job.get("materialKind") in EXERCISE_KINDS
    part_suffix = f" (Teil {job['part'] + 1}/{job['parts']})" if job.get("parts", 1) > 1 else ""
    kern, exam_notes = [], []
    status = ctx.status()
    mstate = status["modules"].setdefault(mod["id"], {})
    taken = module_fronts(ctx, mod["id"])

    for k in keys:
        v = res.get(k)
        if k == "flashcards":
            want = job.get("outputs", {}).get("flashcards") or (job.get("options", {}).get("count") or 10)
            exact = job["type"] in {"material", "exercise", "request"}  # nie mehr Karten als vorgesehen
            minimum = 0 if job["type"] == "update" else (int(want) if exact else max(3, int(want) // 3))
            cards = check_cards(v, errors, minimum, taken)
            if exact or job["type"] == "update":
                cards = cards[:int(want) if exact else UPDATE_MAX_CARDS]  # nach Wichtigkeit sortiert → die ersten zählen
            for c in cards:
                taken.add(c["front"].lower())
                delivery["flashcards"].append({"id": new_id(), **c})
        elif k == "exerciseCards":
            n = int(job["outputs"]["exerciseCards"])
            given = v if isinstance(v, list) else []
            for idx, ex in enumerate(job.get("exercises", [])):
                key = nfc(ex["title"]).lower()
                entry = next((g for g in given if isinstance(g, dict) and nfc(s(g.get("exercise"))).lower() in (key, )), None)
                entry = entry or next((g for g in given if isinstance(g, dict) and key in nfc(s(g.get("exercise"))).lower()), None)
                entry = entry or (given[idx] if idx < len(given) and isinstance(given[idx], dict) else {})
                sub = []
                cards = check_cards(entry.get("cards"), sub, n, taken)
                if sub:
                    _, marker, dupes = sub[0].partition(" Diese Fragen")
                    errors.append(f"exerciseCards für „{ex['title']}“: {len(cards)} gültige Karten – es müssen genau {n} sein."
                                  + (marker + dupes if marker else ""))
                for c in cards[:n]:
                    taken.add(c["front"].lower())
                    delivery["flashcards"].append({"id": new_id(), **c})
        elif k == "quiz":
            q = v if isinstance(v, dict) else {}
            want = job.get("outputs", {}).get("quiz") or (job.get("options", {}).get("count") or 8)
            qs = check_questions(q.get("questions"), errors, max(3, int(want) // 2))[:int(want)]
            title = s(q.get("title")) or f"Quiz {code} · {job.get('materialTitle', '')}{part_suffix}"
            delivery["quizzes"].append({"id": new_id(), "title": title, "questions": qs, "sourceMaterialIDs": src})
        elif k in {"summary", "mockExam", "studyPlan"}:
            title, md = check_doc(v, k, errors, 500 if k == "mockExam" else 200)
            kind = {"summary": "zusammenfassung", "mockExam": "probeklausur", "studyPlan": "lernplan"}[k]
            if k == "summary" and job["type"] == "update" and job.get("summaryDoc"):
                # dieselbe Zusammenfassung überarbeiten statt eine zweite anzulegen
                old = job["summaryDoc"]
                delivery["docs"].append({"id": old["id"], "kind": kind, "title": old.get("title") or title,
                                         "markdown": md, "sourceMaterialIDs": src})
                continue
            default_title = {"summary": f"{code} · {job.get('materialTitle') or 'Zusammenfassung'}{part_suffix}",
                             "mockExam": f"Probeklausur {mod.get('name')} – {dt.date.today().strftime('%d.%m.')}",
                             "studyPlan": f"Lernplan {mod.get('name')}"}[k]
            delivery["docs"].append({"id": new_id(), "kind": kind, "title": title or default_title, "markdown": md,
                                     "sourceMaterialIDs": src})
        elif k in {"cheatSheet", "mustKnow"}:
            _, md = check_doc(v, k, errors)
            focus = s(job.get("options", {}).get("focus"))
            id_key = "cheatSheetDocID" if k == "cheatSheet" else "mustKnowDocID"
            doc_id = new_id() if focus else mstate.get(id_key) or new_id()
            if not focus:
                mstate[id_key] = doc_id
            title = ("Cheat Sheet " if k == "cheatSheet" else "Das musst du können: ") + mod.get("name", "") + (f" – {focus}" if focus else "")
            delivery["docs"].append({"id": doc_id, "kind": "spickzettel" if k == "cheatSheet" else "pflichtwissen",
                                     "title": title, "markdown": md, "sourceMaterialIDs": src})
        elif k == "topics":
            for t in check_list(v, k, errors, 0 if job["type"] == "update" else 1, 80)[:10]:
                delivery["topics"].append({"title": t, "covered": bool(covered)})
        elif k == "kernpunkte":
            kern = check_list(v, k, errors, 3)
        elif k == "examNotes":
            exam_notes = check_list(v, k, errors, 2)

    seen_fronts, unique_cards = set(), []
    for c in delivery["flashcards"]:
        if c["front"].lower() not in seen_fronts:
            seen_fronts.add(c["front"].lower())
            unique_cards.append(c)
    delivery["flashcards"] = unique_cards

    if errors:
        print("FEHLER – bitte korrigieren und erneut übergeben:")
        for e in errors:
            print(" -", e)
        sys.exit(1)

    with locked():
        status = ctx.status()
        mstate = status["modules"].setdefault(mod["id"], {})
        for id_key in ("cheatSheetDocID", "mustKnowDocID"):
            for d in delivery["docs"]:
                if d["kind"] == ("spickzettel" if id_key == "cheatSheetDocID" else "pflichtwissen") and not s(job.get("options", {}).get("focus")):
                    mstate[id_key] = d["id"]
        write_json_atomic(ctx.inbox / f"{delivery['id']}.json", delivery)

        if job["type"] in {"material", "exercise", "exam"}:
            p = status["processed"].setdefault(job["materialID"], {"title": job["materialTitle"]})
            done = sorted(set(p.get("doneParts", [])) | {job["part"]})
            p["doneParts"] = done
            p["parts"] = job["parts"]
            p["at"] = now_iso()
            for d in delivery["docs"]:
                if d["kind"] == "zusammenfassung":
                    p.setdefault("summaryDocIDs", {})[str(job["part"])] = d["id"]
            for ex in job.get("covers", job.get("exercises", [])):
                # Übung bzw. Musterlösung ist mit diesem Paket erledigt – kein eigenes Paket mehr
                e = status["processed"].setdefault(ex["id"], {"title": ex["title"]})
                e.update({"complete": True, "coveredBy": job["materialID"], "at": now_iso(), "parts": 1, "doneParts": [0]})
                raw_ex = ctx.text(mod["id"], ex["id"])
                if raw_ex:
                    e["fingerprint"] = fingerprint(clean(raw_ex))
                    save_snapshot(ex["id"], clean(raw_ex))
            if len(done) >= job["parts"]:
                p["complete"] = True
                mstate["newSinceSynth"] = mstate.get("newSinceSynth", 0) + 1
                # Stand merken, um spätere Änderungen an der Datei zu erkennen
                raw = ctx.text(mod["id"], job["materialID"])
                if raw:
                    text = clean(raw)
                    p["fingerprint"] = fingerprint(text)
                    save_snapshot(job["materialID"], text)
            if kern:
                notes = mstate.setdefault("kernpunkte", {})
                key = f"{job['materialID']}#{job['part']}"
                notes[key] = {"title": job["materialTitle"] + part_suffix, "points": kern, "order": now_iso()}
            if exam_notes:
                mstate["examNotes"] = (mstate.get("examNotes", []) + exam_notes)[-30:]
        elif job["type"] == "update":
            p = status["processed"].setdefault(job["materialID"], {"title": job["materialTitle"], "complete": True})
            p["fingerprint"] = job["newFingerprint"]
            p["updatedAt"] = now_iso()
            p["updates"] = p.get("updates", 0) + 1
            new_text = WORK / job["id"] / "neu.txt"
            if new_text.exists():
                save_snapshot(job["materialID"], new_text.read_text(encoding="utf-8"))
            if kern:
                mstate.setdefault("kernpunkte", {})[job["kernKey"]] = {"title": job["materialTitle"], "points": kern,
                                                                        "order": mstate.get("kernpunkte", {}).get(job["kernKey"], {}).get("order", now_iso())}
            mstate["newSinceSynth"] = mstate.get("newSinceSynth", 0) + 1
        elif job["type"] == "synthesis":
            mstate["synthAt"] = now_iso()
            mstate["newSinceSynth"] = 0
        elif job["type"] == "request":
            Path(job["requestFile"]).unlink(missing_ok=True)
        ctx.save_status(status)

        made = []
        if delivery["flashcards"]:
            made.append(f"{len(delivery['flashcards'])} Karteikarten")
        for d in delivery["docs"]:
            made.append({"zusammenfassung": "Zusammenfassung", "probeklausur": "Probeklausur", "lernplan": "Lernplan",
                         "spickzettel": "Cheat Sheet", "pflichtwissen": "Das musst du können"}.get(d["kind"], "Dokument"))
        for q in delivery["quizzes"]:
            made.append(f"Quiz ({len(q['questions'])} Fragen)")
        if delivery["topics"]:
            made.append(f"{len(delivery['topics'])} Themen")
        if job["type"] == "update":
            made = [x + " überarbeitet" if x == "Zusammenfassung" else x for x in made] or ["Kernpunkte aktualisiert"]
        line = f"{job['label']}: " + ", ".join(made)
        run = read_json(WORK / "run.json", {}) or {}
        run.setdefault("done", []).append(line)
        run.setdefault("doneIDs", []).append(job["id"])
        write_json_atomic(WORK / "run.json", run)
    shutil.rmtree(WORK / job["id"], ignore_errors=True)
    print("OK – " + line)


def cmd_finish(ctx, args):
    with locked():
        run = read_json(WORK / "run.json", {}) or {}
        done = run.get("done", [])
        status = ctx.status()
        status["lastRun"] = now_iso()
        status["lastSummary"] = ("Erstellt: " + "; ".join(done)) if done else "Nichts Neues."
        ctx.save_status(status)
    unfinished = sorted(p.name for p in WORK.iterdir() if p.is_dir()) if WORK.exists() else []
    print(status["lastSummary"])
    if unfinished:
        print(f"Nicht übergeben (kommt im nächsten Durchlauf erneut): {', '.join(unfinished)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan"); p.add_argument("--limit", type=int, help="höchstens so viele Material-Pakete (sonst Einstellung)")
    p = sub.add_parser("show"); p.add_argument("job"); p.add_argument("--seite", type=int, default=1)
    p = sub.add_parser("submit"); p.add_argument("job"); p.add_argument("--file")
    sub.add_parser("finish")
    args = ap.parse_args()
    root = args.data_dir
    if not root and args.cmd in {"show", "submit"}:
        root = (read_json(WORK / args.job / "job.json") or {}).get("dataDir")
    ctx = Ctx(data_dir(root))
    {"plan": cmd_plan, "show": cmd_show, "submit": cmd_submit, "finish": cmd_finish}[args.cmd](ctx, args)


if __name__ == "__main__":
    main()
