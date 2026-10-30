---
name: kompass-lernen
description: Erstellt in Davids Lern-App Kompass Karteikarten, Zusammenfassungen, Quizze, Probeklausuren, Cheat Sheets und „Das musst du können“ aus neuen Materialien und aus Aufträgen der App – sparsam über Haiku-Unteragenten. Nutzen, wenn David Lernmaterial für Kompass erstellen lassen will oder der tägliche Kompass-Durchlauf läuft.
---

# Kompass-Lerndurchlauf

Du steuerst nur – die eigentliche Arbeit machen Unteragenten mit dem jeweils vorgegebenen Modell
(meist Haiku). Lies selbst keine Materialien, Ausgabedateien oder Transkripte der Agenten; das spart
Davids Nutzungslimit. Das Skript erledigt Planung, Prüfung und Übergabe an die App.

1. Führe aus:
   `python3 /Users/david/Developer/Kompass/Scripts/kompass_claude.py plan`
2. Ist `jobs` leer: führe `python3 /Users/david/Developer/Kompass/Scripts/kompass_claude.py finish` aus,
   antworte mit einer Zeile und höre auf.
3. Starte für jeden Eintrag in `jobs` einen Agenten (Agent-Tool):
   - `subagent_type`: `kompass-karten` (darf nur das Skript ausführen; fehlt der Typ: `general-purpose`)
   - `model`: der Wert `model` des Jobs (`haiku` oder `sonnet`) – nie ein anderes Modell
   - `description`: `label` des Jobs (gekürzt)
   - `prompt`: `prompt` des Jobs, wörtlich und unverändert
   Starte höchstens 6 gleichzeitig; weitere, sobald einer fertig ist. Jobs mit `sonnet`
   (Cheat Sheets) erst, wenn alle anderen fertig sind.
4. Warte, bis alle Agenten fertig sind (du wirst benachrichtigt). Prüfe ihre Arbeit nicht nach –
   das Skript hat jedes Ergebnis beim Übergeben schon geprüft.
5. Führe `python3 /Users/david/Developer/Kompass/Scripts/kompass_claude.py finish` aus und antworte
   mit dessen Ausgabe (höchstens drei Zeilen).

Nicht übergebene Pakete holt der nächste Durchlauf automatisch nach. Wünscht David etwas Bestimmtes
(z. B. „mach Karteikarten zu Vorlesung 5“), soll er das in Kompass über „Mit Claude erstellen“ als
Auftrag anlegen – dann erledigt Schritt 1–5 es.
