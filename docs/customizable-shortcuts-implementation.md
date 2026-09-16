# Implementierungsauftrag: Anpassbare globale Shortcuts

**Status:** IMPLEMENTED IN WORKTREE
**Scope:** Blitztext macOS App
**Letzte Aktualisierung:** 2026-09-16

## Ziel

Die aktuell in `HotkeyService` hart codierten globalen Blitztext-Shortcuts
sollen in den Einstellungen pro Workflow aufgezeichnet, gespeichert,
geändert, zurückgesetzt und deaktiviert werden können.

Das bisherige Verhalten soll für bestehende Nutzer erhalten bleiben. Die
Funktion betrifft nur die Belegung der Shortcuts. Das vorhandene globale
Hold-/Toggle-Verhalten bleibt unverändert und gilt weiterhin app-weit.

## Verbindliche Produktentscheidungen

### Workflows und Reichweite

- Konfigurierbar sind alle sechs Workflows:
  - Blitztext (`transcription`)
  - Blitztext Lokal (`localTranscription`)
  - Blitztext+ (`textImprover`)
  - Translate EN (`translateEN`)
  - Blitztext $%&! (`dampfAblassen`)
  - Blitztext :) (`emojiText`)
- Der lokale Workflow erhält deshalb ebenfalls eine eigene Zeile in den
  Shortcut-Einstellungen, auch wenn er nicht in
  `WorkflowType.mainMenuCases` enthalten ist.
- Shortcuts bleiben global und funktionieren auch bei inaktiver Blitztext-App.
- Escape bleibt fest für Abbrechen reserviert und darf nicht aufgezeichnet
  oder einem Workflow zugewiesen werden.

### Erlaubte Belegungen

- Die bisherigen Modifier-only-Chords bleiben gültige Belegungen.
- Neue Belegungen dürfen aus den bisherigen Modifiern (`Fn`, `Shift`, `Ctrl`,
  `Option`, `Cmd`) plus genau einer Standardtaste bestehen.
- Eine einzelne Nicht-Modifier-Taste ohne Modifier ist nicht erlaubt, damit
  keine versehentlichen globalen Einzel-Tasten-Trigger entstehen.
- Als Standardtasten gelten Buchstaben, Zahlen, Leertaste und F-Tasten.
- Escape sowie Play/Pause-, Lautstärke- und sonstige Medientasten werden nicht
  zugelassen.
- Die physische Tastenkombination wird stabil über Key Code plus Modifier-
  Flags gespeichert. Die Anzeige soll die aktuell passende Tastaturbelegung
  berücksichtigen, soweit AppKit das ermöglicht.

### Konflikte und Deaktivierung

- Doppelte aktive Blitztext-Belegungen werden beim Speichern blockiert.
- Escape und klar bekannte, systemseitig reservierte Kombinationen werden
  ebenfalls blockiert.
- Wenn die technische Registrierungs-/Monitoring-Schicht eine Belegung nicht
  übernehmen kann, bleibt die bisherige funktionierende Belegung aktiv; die
  neue Belegung wird nicht gespeichert und die UI zeigt einen verständlichen
  Fehler.
- App-spezifische Kollisionen, die macOS über die verwendeten Event-Monitore
  nicht erkennen kann, dürfen nicht als sicher erkannt behauptet werden. Ein
  erklärender Hinweis ist zulässig.
- Jeder Workflow kann über einen sichtbaren Aktiv-Schalter deaktiviert werden.
  Beim Deaktivieren bleibt die aufgezeichnete Belegung erhalten und kann später
  wieder aktiviert werden.
- Zusätzlich gibt es eine Reset-Aktion pro Workflow und eine Aktion zum
  Wiederherstellen aller Standardbelegungen. Ein Reset verändert den globalen
  Hold-/Toggle-Modus nicht.

### Migration und Laufzeit

- Vorhandene Nutzer behalten exakt die heutigen Defaults:

  | Workflow | Standardbelegung |
  | --- | --- |
  | Blitztext | `Fn + Shift` |
  | Blitztext Lokal | `Fn + Shift + Ctrl` |
  | Blitztext+ | `Fn + Ctrl` |
  | Translate EN | `Fn + Shift + Option` |
  | Blitztext $%&! | `Fn + Option` |
  | Blitztext :) | `Fn + Cmd` |

- Neue Installationen starten mit denselben Defaults.
- Änderungen werden unmittelbar nach erfolgreichem Speichern aktiv, ohne
  Neustart.
- Eine laufende Aufnahme wird durch eine Shortcut-Änderung nicht abgebrochen.
  Die aktuelle Aufnahme endet mit ihrer bisherigen Belegung; die neue
  Belegung gilt ab dem nächsten Start.
- Bei einem ungültigen oder kollidierenden Eintrag darf kein teilweise
  aktualisierter Zustand entstehen. Konfiguration und laufende Registrierung
  müssen atomar auf die letzte gültige Belegung zurückfallen.

## Erwartete Benutzeroberfläche

In `CustomizeSettingsView` wird der bisherige reine Label-Block durch einen
konfigurierbaren Bereich ersetzt:

- eine Zeile pro Workflow, inklusive `localTranscription`;
- Anzeigename und aktuelles Shortcut-Label;
- fokussierbares Aufzeichnungsfeld mit dem Hinweis, eine Kombination zu
  drücken;
- Aktiv-Schalter pro Workflow;
- Inline-Fehler bei ungültiger Taste, fehlendem Modifier, Duplikat oder nicht
  registrierbarer Belegung;
- Reset pro Zeile;
- Reset aller Defaults;
- kurze Erklärung, dass Escape fest zum Abbrechen gehört und Medientasten
  nicht verwendet werden können.

Annahmen für die Interaktion:

- Das Aufzeichnungsfeld übernimmt eine neue Kombination direkt nach dem
  Loslassen der Kombination.
- Escape beendet die Aufzeichnung ohne Änderung.
- Eine Löschen-/Clear-Aktion entfernt die Belegung nicht dauerhaft, sondern
  setzt den Aktiv-Schalter aus; das gespeicherte Kürzel bleibt sichtbar bzw.
  wieder aktivierbar.
- Die bestehende Modusauswahl `Halten`/`Drücken` bleibt an ihrer bisherigen
  Stelle und wird nicht pro Workflow aufgespalten.

## Technischer Umsetzungsrahmen

### Persistenz

In `AppSettings` eine versionierbare, Codable-fähige Shortcut-Konfiguration
ergänzen. Die Implementierung soll mindestens abbilden:

- Workflow-Zuordnung;
- Key Code der optionalen Standardtaste;
- Modifier-Flags;
- Aktivierungsstatus.

Beim Decodieren alter `settings.json` müssen fehlende Shortcut-Felder auf die
sechs aktuellen Defaults zurückfallen. Unbekannte oder ungültige Einträge
dürfen den gesamten Settings-Load nicht unbrauchbar machen; sie werden
validiert und auf den betreffenden Default zurückgesetzt.

Die Defaults sollen an einer zentralen Stelle liegen und sowohl von der
Persistenzmigration, dem Reset-UI als auch `HotkeyService` verwendet werden.
`WorkflowType.hotkeyLabel` darf nicht länger die alleinige Quelle der
Belegungen sein. Ein formatter darf daraus weiterhin die Anzeige erzeugen.

### HotkeyService

`HotkeyService` soll eine öffentliche Konfiguration erhalten, die aus der
aktuellen Shortcut-Belegung erzeugt wird. Die hart codierte `switch`-Zuordnung
ist durch eine datengetriebene Zuordnung zu ersetzen.

Die bestehende Unterstützung für Modifier-only-Chords einschließlich der
90-ms-Auflösung von Präfixen muss erhalten bleiben. Für Belegungen mit einer
Standardtaste muss zusätzlich die globale Key-Down-/Key-Up-Sequenz korrekt
behandelt werden:

- nur ein `.down` pro Tastendruck;
- `.up` beim Verlassen der vollständigen Belegung im Hold-Modus;
- Autorepeat darf keinen zweiten Start erzeugen;
- ein unvollständiges Präfix darf keinen Workflow starten;
- nach dem Loslassen müssen identische Folgeauslösungen wieder möglich sein;
- Escape bleibt ein eigener Cancel-Pfad.

Die Service-API soll eine sichere Aktualisierung der Konfiguration erlauben.
Beim Aktualisieren sind laufende Hotkey-Zustände und ausstehende Chord-Tasks
sauber zu beenden. Eine laufende Workflow-Aufnahme wird dabei nicht indirekt
gestoppt; die bestehende AppState-Workflowlogik bleibt dafür zuständig.

### AppState und Speicherung

- `AppState` bleibt die zentrale Stelle für Laden, Speichern und Anwenden der
  Einstellungen.
- Nach erfolgreicher Validierung und Speicherung wird die neue Belegung an
  `HotkeyService` übergeben.
- Bei einem Fehler werden sowohl `AppSettings` als auch `HotkeyService` auf den
  vorherigen gültigen Zustand zurückgesetzt.
- Die bestehenden Hotkey-Events und die globale `hotkeyMode`-Semantik werden
  nicht neu erfunden.

### Validierung

Eine zentrale Validierung soll mindestens prüfen:

1. Escape und ausgeschlossene Medientasten;
2. mindestens einen Modifier bei jeder Belegung mit Standardtaste;
3. erlaubte Key Codes;
4. Duplikate zwischen aktiven Workflows;
5. bekannte systemseitig reservierte Kombinationen;
6. eine deaktivierte Zeile ohne Belegung als zulässigen Zustand.

Die UI und die Laufzeitkonfiguration müssen dieselbe Validierungslogik nutzen.
Keine doppelte, voneinander abweichende Konfliktprüfung in View und Service.

## Akzeptanzkriterien

- Alle sechs Workflows erscheinen in den Shortcut-Einstellungen.
- Eine neue Kombination aus Modifier plus Standardtaste kann aufgezeichnet,
  gespeichert und global aus einer anderen App ausgelöst werden.
- Die sechs heutigen Defaults funktionieren nach Migration unverändert.
- Modifier-only-Defaults funktionieren weiterhin zuverlässig.
- Hold- und Toggle-Modus verhalten sich wie vor der Änderung.
- Duplikate, Escape, nicht erlaubte Tasten und erkannte reservierte
  Kombinationen werden nicht gespeichert.
- Ein Workflow kann deaktiviert und später ohne erneute Aufzeichnung aktiviert
  werden.
- Einzelne Defaults und alle Defaults können wiederhergestellt werden.
- Shortcut-Änderungen stoppen keine laufende Aufnahme.
- Ein fehlerhaftes Speichern hinterlässt die vorherige Belegung aktiv.
- Die Einstellungsdaten bleiben mit bestehenden Installationen kompatibel.
- README und relevante Entwicklungs-/Nutzerdokumentation beschreiben die neue
  Shortcut-Konfiguration korrekt.

## Verifikation

Da das Repository aktuell kein automatisches Xcode-Testziel besitzt, sind
mindestens erforderlich:

1. gezielte, kompilierbare Tests für Modellierung, Codable-Migration und
   Validierung, soweit sie ohne App-UI sinnvoll möglich sind;
2. `./build.sh --debug` aus dem Repository-Root;
3. manueller macOS-Smoke-Test mit einer anderen Vordergrund-App:
   - jeden Default einmal testen;
   - eine neue Standardtasten-Kombination aufzeichnen und testen;
   - Hold und Toggle testen;
   - Duplikat, Escape, Einzel-Taste und Medientaste ablehnen lassen;
   - einen Workflow deaktivieren und wieder aktivieren;
   - Einzel- und Gesamt-Reset testen;
   - während einer laufenden Aufnahme die Belegung ändern und prüfen, dass
     die Aufnahme normal endet.

Nicht Bestandteil dieses Auftrags sind neue Shortcuts für Escape, Medien-
steuerung, per-Workflow-Hotkey-Modi, Telemetrie, neue Netzwerkziele,
Notarization, Deployment oder ein generelles Betriebssystem-Shortcut-
Management.
