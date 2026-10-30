# Kompass

Deine All-in-one-App für Studium, Werkstudentenjob und Lernen – nativ für macOS (SwiftUI).

## Was Kompass kann

- **Heute** – Agenda, Fristen-Countdown, Aufgaben, Wochenfortschritt, „Noch zu bestätigen“ (Termine und Lernblöcke der letzten 7 Tage)
- **Kalender** – Tag/Woche/Monat, Zwei-Wege-Sync mit Apple Kalender (alle Kalender lesen und bearbeiten), Termine per Drag & Drop verschieben und an der Unterkante in der Länge ziehen, Werkstudenten-Zeiten grau hinterlegt
- **Wochenplan** – Soll/Ist je Modul, Zeitbudget (Arbeit, Vorlesungen, Termine, Lernen), KI-Wochenfazit, Ausblick und automatischer **Lernblock-Planer**. Sonntags erscheint der Rückblick (plus Mitteilung um 18 Uhr).
- **Fristen** – Klausuren, Abgaben, Präsentationen, Testate, Anmeldungen. Erinnerungen über macOS-Mitteilungen, die Erinnerungen-App (iPhone/Watch) und Kalender-Alarme
- **Module** – Veranstaltungen (als Kalenderserie), Themen mit Selbsteinschätzung, Materialien (PDF inkl. Scans, PowerPoint, Word, Bilder, Notebooks …), Fortschritt aus Themen, Materialien, Quizzen, Karteikarten und Lernzeit, Status „Im Plan / hinterher“ bis zur Klausur
- **Lernen mit KI (DeepSeek)** – Quiz, Karteikarten (Wiederholung im optimalen Abstand), Zusammenfassungen, Probeklausuren im Stil deiner Altklausuren, Lernpläne, Abfragen im Chat
- **Assistent** (⌘J) – kann die ganze App bedienen: Module, Termine, Fristen, Aufgaben, Planung, Materialien durchsuchen, Dokumente speichern. Löschen und Änderungen an fremden Kalendern musst du bestätigen.
- **Zeiterfassung** (⌘6, ähnlich Jira/Tempo) – Buchungen auf Module, Arbeit und eigene Kategorien (Sport …), Stundenzettel pro Tag/Woche mit Filtern (Woche, Monat, Semester, frei; nur Gelerntes, Veranstaltungen, Arbeit …), Verlauf, Schätzung vs. erfasst vs. verbleibend für Aufgaben und Fristen, CSV-Export, Warnung bei mehr als 20 h Arbeit pro Woche in der Vorlesungszeit
- **„Wahrgenommen“ per Klick** – auf jeden Termin oder Arbeitsblock im Kalender; bei Serien gilt es nur für dieses eine Vorkommen. „Noch zu bestätigen“ in der Heute-Ansicht, „Tag bestätigen“ per Rechtsklick auf den Tageskopf, abends eine Erinnerung
- **Timer** in der Symbol- und Menüleiste – für Module, Arbeit oder eigene Kategorien; die Zeit wird automatisch gebucht

## Mac: installieren / aktualisieren

```bash
cd ~/Developer/Kompass && ./build.sh install
```

Die App landet in `/Programme/Kompass.app`. Alternativ in Xcode `Kompass.xcodeproj` öffnen, Schema **Kompass macOS** wählen und ▶︎ drücken.

## iPhone: über Xcode installieren

1. iPhone per Kabel verbinden (beim ersten Mal „Diesem Computer vertrauen“).
2. `Kompass.xcodeproj` in Xcode öffnen.
3. Oben das Schema **Kompass iOS** und dein iPhone als Ziel wählen.
4. Projekt „Kompass“ → Ziel **Kompass iOS** → *Signing & Capabilities* → **Team**: deine Apple-ID („Personal Team“) wählen. Meldet Xcode, die Bundle-ID sei vergeben, hänge etwas an (z. B. `de.staufer.kompass.david`).
5. Auf dem iPhone den **Entwicklermodus** aktivieren: Einstellungen → Datenschutz & Sicherheit → Entwicklermodus (Neustart).
6. In Xcode ▶︎ drücken. Beim ersten Start auf dem iPhone: Einstellungen → Allgemein → VPN & Geräteverwaltung → deinem Entwickler-Zertifikat vertrauen.

Mit einer kostenlosen Apple-ID läuft die App **7 Tage** und muss dann einfach erneut aus Xcode installiert werden (deine Daten bleiben erhalten). Mit dem bezahlten Developer Program sind es ein Jahr.

## Mac und iPhone synchronisieren (iCloud Drive)

- **Mac:** Kompass speichert automatisch in *iCloud Drive › Kompass* (Einstellungen → Daten & Sync).
- **iPhone:** Bei der Einrichtung bzw. in den Einstellungen → *Daten & iCloud-Sync* → „iCloud-Ordner verbinden …“ → *Durchsuchen* → iCloud Drive → Ordner **Kompass** → Öffnen.

Module, Materialien, Zeiten, Karteikarten, Quizze und Dokumente liegen dann in diesem Ordner. Änderungen beider Geräte werden zusammengeführt (pro Eintrag; bei gleichzeitiger Änderung desselben Eintrags gewinnt das Gerät, das gerade speichert). Schutz gegen Datenverlust: Ein Gerät überschreibt nie eine neuere iCloud-Fassung, von iCloud aufbewahrte Konfliktfassungen werden automatisch zusammengeführt, und verschwindet beim Abgleich auf einen Schlag mehr als die Hälfte der Einträge (typisch für ein Gerät mit veralteter Kopie), wird das nicht übernommen. Sicherungen: stündlich (48 h) und täglich (30 Tage) in *Kompass › Backups*. Termine, Fristen und Erinnerungen laufen zusätzlich über Apple Kalender/Erinnerungen. Kalender-Zuordnungen (welcher Kalender ist der Arbeitskalender usw.) sind pro Gerät einstellbar.

Hinweis: Die App ist lokal (ad hoc) signiert. Nach einem Update fragt macOS evtl. erneut nach Kalender- oder Schlüsselbund-Zugriff – einfach erlauben.

## WueCampus (Moodle der Uni Würzburg)

Kompass holt Dateien, Abgabetermine und weitere Termine automatisch aus deinen WueCampus-Kursen.

1. Einstellungen → **WueCampus** → **Mit WueCampus anmelden** → im Fenster mit deinem JMU-Account (Uni-Login) anmelden. Kompass bekommt nur einen Zugangsschlüssel, nie dein Passwort.
2. **Kurse auswählen & zuordnen …** → Kurse anhaken und einem Modul zuordnen (oder neu anlegen lassen).
3. Fertig: Der Mac synchronisiert beim Start und alle 3 Stunden, am iPhone gibt es „Jetzt synchronisieren“ bzw. „Aktualisieren“ im Materialien-Reiter.

- Dateien landen sortiert (Vorlesung, Übung, Altklausur …) im Modul, ihr Text wird für die KI eingelesen. Geänderte Dateien werden ersetzt.
- Aufgaben mit Fälligkeit werden zu Fristen (Abgabe), Tests zu Testaten, Kurstermine wie „Klausur …“ zu Klausuren – mit Erinnerungen. Schon selbst eingetragene Fristen werden verknüpft statt doppelt angelegt.
- Videos, Archive und Dateien über 100 MB werden übersprungen. Was du in Kompass löschst, wird nicht erneut geladen.
- Klappt die Anmeldung nicht: In WueCampus → Profil → Einstellungen → Sicherheitsschlüssel den Schlüssel für „Moodle mobile web service“ kopieren und unter „Anmeldung klappt nicht?“ einfügen.

## Lernmaterial mit Claude (über das Claude-Abo, ohne API-Kosten)

Ein geplanter Claude-Durchlauf (Claude-App → Geplante Aufgaben → „Kompass: Lernmaterial“, täglich ca. 7 Uhr) bereitet neue Materialien auf: Karteikarten, Zusammenfassungen, Quizze, Themen, aus Altklausuren Probeklausuren, und je Modul ein Cheat Sheet sowie „Das musst du können“ (wöchentlich aktualisiert). In Kompass kannst du beim Erstellen zusätzlich „Claude“ statt „DeepSeek“ wählen – der Auftrag wird beim nächsten Durchlauf erledigt (sofort: in der Claude-App „Jetzt ausführen“).

- Sparsam fürs Nutzungslimit: Die Arbeit machen **Haiku**-Unteragenten; nur Probeklausuren und die Modul-Übersichten nutzen Sonnet (abschaltbar). Planung, Prüfung und Buchführung erledigt `Scripts/kompass_claude.py` ohne KI; doppelte Dateien (Notebook + HTML) werden übersprungen.
- Genau **10 Karteikarten pro Vorlesung und 10 pro Übung** (einstellbar), nach Wichtigkeit sortiert. Übungskarten behandeln Lösungswege, Methoden und typische Fallen; Musterlösungen werden dem passenden Blatt beigelegt (keine eigenen Karten). Ist die Übung zusammen mit ihrer Vorlesung da (Zuordnung über die Nummer wie „Übungsblatt 2“ ↔ „L2“/„Kap.2“, sonst über das Datum), bearbeitet ein Agent beides in einem Paket. Mehr Karten nur auf Wunsch: Materialmenü → „Mehr Karteikarten mit Claude“ oder „Karteikarten erstellen“ mit eigener Anzahl.
- Baut aufeinander auf: Jedes Material wird nur einmal verarbeitet. Ändert sich eine Datei (z. B. korrigierte Folien aus WueCampus), bekommt Claude nur die geänderten Stellen: Die Zusammenfassung wird überarbeitet (dasselbe Dokument), neue Karteikarten gibt es nur für neue Inhalte, Kleinigkeiten wie Tippfehler kosten nichts. Cheat Sheet und „Das musst du können“ entstehen aus den gesammelten Kernpunkten, nicht aus den Folien. Gelöschtes wird nicht wieder angelegt.
- Einstellungen → **KI** → *Claude*: was automatisch entsteht und wie viele Pakete pro Durchlauf höchstens (Standard 50 – reicht für alles Neue einer Woche).
- Die Agenten dürfen nur `kompass_claude.py` ausführen (Agent-Typ `kompass-karten`, Freigabe in `~/.claude/settings.json`) – keine Rückfragen. Lange Materialien gibt `show` seitenweise aus (`--seite 2` …), `submit` weist Karten zurück, deren Frage es im Modul schon gibt, damit die Sollzahl stimmt.
- Austausch über Dateien im Datenordner: `Claude/Auftraege` (von der App), `Claude/Eingang` (von Claude, übernimmt die App), `Claude/status.json`.
- Auch im Chat nutzbar: `/kompass-lernen` (Skill in `.claude/skills/kompass-lernen`).

## DeepSeek-API-Key

Einstellungen (⌘,) → **KI** → Key einfügen (`sk-…`) → „Speichern & testen“. Der Key liegt im macOS-Schlüsselbund.
Key erstellen: <https://platform.deepseek.com/api_keys>. Standardmodell: `deepseek-chat` (änderbar).

## Daten

`~/Library/Application Support/Kompass/`

- `kompass.json` – alle Daten (Module, Fristen, Lernzeiten …)
- `Materialien/` – Kopien deiner hochgeladenen Dateien + extrahierter Text
- `Backups/` – tägliche Sicherung (die letzten 30)
- `chats.json` – Assistenten-Verläufe

(Mit iCloud-Sync liegt alles in *iCloud Drive › Kompass*; die lokale Kopie unter Application Support bleibt als Sicherung.)

Zeitangaben beim Buchen im Jira-Format: `1h 30m`, `45m`, `1,5h`, `1:30`, `2d` (= 8 h). Ohne Einheit gelten kleine Zahlen als Stunden (`2` = 2 h) und große als Minuten (`45` = 45 min).

Semester wechselst du über die Seitenleiste („Module · WiSe …“). Alte Module kannst du archivieren – alles bleibt erhalten.

## Tastenkürzel

| Kürzel | Aktion |
|---|---|
| ⌘1 … ⌘6 | Heute, Kalender, Wochenplan, Fristen, Karteikarten, Zeiten |
| ⇧⌘L | Zeit buchen |
| ⌘J | Assistent |
| ⌘N | Neuer Termin |
| ⇧⌘D | Neue Frist |
| ⇧⌘N | Neues Modul |
| ⇧⌘T | Neue Aufgabe |
| ⇧⌘P | Nächste Woche planen |
| ← / → | Im Kalender blättern |
| Leertaste, 1–4 | Karteikarten umdrehen und bewerten |

## Entwicklung

- `swift build` – Debug-Build, `./build.sh` – App-Bundle (Mac, nur Command Line Tools nötig)
- `Kompass.xcodeproj` – Mac- und iPhone-Ziel aus denselben Quellen. `Sources/Kompass` ist als synchronisierter Ordner eingebunden: neue Dateien erscheinen automatisch. Neu erzeugen mit `python3 Scripts/generate_xcodeproj.py`.
- Plattformunterschiede stecken in `App/Platform.swift` (`#if os(macOS)` / `#if os(iOS)`), schmale Layouts über `@Environment(\.isCompactLayout)`.
- Demo-Modus (eigener Datenordner, keine Berechtigungen, keine Mitteilungen):
  `build.noindex/Kompass.app/Contents/MacOS/Kompass -kompass.demo YES -kompass.dataDir /tmp/kompass-demo`
- Neue Felder in gespeicherten Modellen bitte als Optional anlegen (siehe `Models.swift`), damit alte Daten ladbar bleiben.
