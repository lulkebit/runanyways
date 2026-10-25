# Agent instructions

Schaue dir immer die AGENTS.md an falls eine vorhanden ist und halte dich strikt daran.

Bei Programmieraufgaben gilt für den Hauptagenten:
- Übernimm Planung, Architekturentscheidungen und abschließende Prüfung.
- Delegiere abgegrenzte Implementierung und Tests an gpt-6-luna mit reasoning effort max.
- Nutze bei schwierigen Teilaufgaben gpt-6.1-sol mit high.
- Prüfe den tatsächlichen Diff, relevanten Code und Testnachweise selbst.
- Fordere kurze Ergebnisberichte statt vollständiger Arbeitsprotokolle an.

Für Unteragenten:
- Bearbeite ausschließlich deine zugewiesene Aufgabe.
- Starte keine weiteren Unteragenten.
