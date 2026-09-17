# IMPLEMENTATION_TASK.md

## Auftrag

Behebe den weiterhin offenen YouTube-Pause-Fehler in Blitztext und schließe
die nachgewiesene Lücke zwischen beobachteter Pause und eigener Pause.

- Repository: marco21061990/blitztext-app
- PR: #5
- Branch: codex/blitztext-reliability-ui
- Review-Basis: 3d9538595f35a25e9f48145c7b304f25bc791607
- Vergleichsbasis: main, b171a984007b5c6b8a65ab1ca34fd770962292b6
- Erstellt aus einer read-only Gegenprüfung durch GPT-6 Pro am 2026-09-17.

Diese Aufgabe beschreibt lokale Implementierung und Tests. Sie autorisiert
keinen Push, PR-Kommentar, Merge, Release oder sonstigen externen Write.
Installation und Live-Steuerung gehören ausschließlich in einen kontrollierten
lokalen Abnahmelauf mit dem Benutzer.

Zuerst AGENTS.md und docs/media-playback-during-dictation.md lesen,
Arbeitsbaum und Revision prüfen und fremde Änderungen erhalten. Codekommentare
und Commit-Messages bleiben gemäß Repository-Vorgabe Englisch.

## 1. Befundlage

### Aus dem Repository belegt

- Die frühere Exactly-one-Auswahlsperre wurde durch Gruppenbesitz für
  vollständig identifizierte, spielende Provider ersetzt.
- Der Chrome-Locator verwendet weiterhin ausschließlich
  kAXFocusedWindowAttribute; eine explizite Zuordnung von Fenster, aktivem
  Tab und Haupt-WebArea fehlt.
- Vordergrundauswahl und Popover-Aktivierung können zeitlich auseinanderfallen.
- Ein pausierter Adapter-Rückgabewert kann ohne ausgeführten Pause-Befehl als
  eigene Pause übernommen werden.
- Die Chrome-Identität besteht derzeit aus PID und URL.
- Die bestehenden Coordinator-Tests verwenden Fake-Adapter und durchlaufen
  nicht die produktive AX-Auswahl oder Button-Klassifikation.

### Vom Benutzer beobachtet

- Ein tatsächlich laufender YouTube-Tab wurde nach Installation des PR-Stands
  weiterhin nicht pausiert.
- Eine separate AX-Inspektion fand movie_player und passende Pause-/Play-
  Labels.

### Noch nicht belegt

- Welcher Guard den letzten fehlgeschlagenen App-Lauf beendet hat.
- Ob der Fehler im Start-/Fokuskontext, AX-Locator, Berechtigungszustand,
  Zeitbudget oder eigentlichen Aktionsaufruf liegt.
- Ob die separate Inspektion den gleichen AX-Kontext wie die installierte
  Blitztext-Instanz verwendet.

Keine dieser Hypothesen vor der Diagnose als Root Cause ausgeben.

## 2. Lösungsvorschlag und Priorisierung

Die führende Arbeitshypothese ist eine abweichende oder nicht mehr eindeutig
bestimmbare Fenster-/Tab-/Player-Auswahl im tatsächlichen Blitztext-
Startkontext. locateControl() nimmt nur das fokussierte Chrome-Fenster,
durchsucht danach das gesamte Fenster und verlangt genau einen Player. Der
aktive Tab und sein Hauptdokument werden nicht explizit identifiziert.

Zweite Hypothese ist ein Ablauf-/Deadlineproblem: Initiale Inspektionen laufen
parallel, Pause-Aufrufe aber seriell, standardmäßig Spotify vor Chrome. Der
Chrome-AX-Baum wird bei Auswahl, Pause-Vorprüfung und Bestätigung erneut
durchsucht, ohne eigene Deadline- oder Vollständigkeitsinformation.

Dritte Hypothese ist die breite Play-Label-Erkennung. isPlayLabel() akzeptiert
unter anderem jedes Label mit wiedergabe; ein zusätzlicher Treffer kann einen
echten Pause-Button zu einem mehrdeutigen Ergebnis machen. Das Auftreten eines
konkreten problematischen Labels im letzten Live-Lauf ist nicht belegt.

Vierte Hypothese ist ein Unterschied bei AX-Trust oder Accessibility-
Initialisierung zwischen separater Inspektion und der installierten
Blitztext-Instanz. Das muss im ursprünglichen App-Prozess verifiziert werden.

Der stärkste Einwand gegen den aktuellen Multi-Source-Ansatz ist unabhängig
vom konkreten YouTube-Ausfall: Der Coordinator verwechselt einen beobachteten
Zustand mit dem Nachweis eines eigenen Befehls. Wenn eine Quelle zunächst
playing ist, der Benutzer sie vor der Adapteraktion pausiert und der Adapter
anschließend paused zurückgibt, kann confirmPause() trotzdem Besitz markieren,
obwohl kein Pause-Befehl ausgeführt wurde. Das kann am Ende zu einem
unberechtigten Play führen. Die Gruppenidee bleibt vertretbar, benötigt aber
einen belastbaren Besitznachweis pro Quelle.

Die minimale unterscheidende Probe ist ein korrelierter Lauf aus der
installierten App mit den Stationen:

    Start -> Inspektion -> Auswahl -> Pause-Vorprüfung -> AXPress -> Zustandsbestätigung -> Besitzübernahme

Pro Station nur Request-Bezug, Auswahlgrund, grobe Vordergrundklasse,
AX-Trust, Fenster-/Dokument-/Player-Anzahl, begrenzte AX-Fehlercodes,
command_issued, command_accepted, same_target sowie verstrichene und
verbleibende Millisekunden erfassen. Keine Labels, URLs oder vollständigen
AX-Bäume loggen. So werden Auswahlregel, Locator, Deadline, fehlender AXPress
und fehlende Bestätigung unterschieden.

## 3. Ziel und Nicht-Ziele

### Ziel

Ein eindeutig identifizierter, tatsächlich spielender YouTube-Player soll vor
einer Aufnahme explizit pausiert werden. Nur eine nachweislich von Blitztext
übernommene, weiterhin unveränderte Pause darf restauriert werden. Spotify und
die unterstützte Gruppenfunktion dürfen nicht regressieren.

### Nicht-Ziele

- Keine globale Browser- oder Mediensteuerung.
- Keine automatische Steuerung aller Chrome-Tabs.
- Keine Erweiterung auf andere Browser oder Player.
- Kein JavaScript über Chrome-Apple-Events und keine Browser-Erweiterung.
- Keine Medien-Taste, kein Space-/K-Tastendruck und kein blindes Toggle.
- Kein Aktivieren von Chrome, AXRaise oder Tabwechsel zur Zielsuche.
- Keine Lautstärke- oder Mute-Änderung.
- Keine privaten Frameworks, neuen Netzwerkziele oder Telemetrie.
- Kein allgemeiner Shortcut-, Popover- oder Auto-Paste-Umbau.
- Kein Erhöhen des 500-ms-Vorbereitungsbudgets.

## 4. Änderungsreihenfolge

### Welle A: Diagnose vor funktionaler Auswahlerweiterung

In BlitztextMac/Services/MediaPlaybackCoordinator.swift die bestehenden
Entscheidungsstellen instrumentieren:

- prepareForRecording
- performPreparation
- selectCandidates
- timeoutPreparation
- ChromeYouTubeMediaPlaybackAdapter.inspect
- ChromeYouTubeMediaPlaybackAdapter.pause
- ChromeYouTubeMediaPlaybackAdapter.resume
- locateControl
- focusedWindow
- findPlayers
- findActionButton
- attributeValue
- press

In BlitztextMac/App/AppState.swift:

- prepareForPopoverPresentation
- startWorkflow
- prepareAndStartWorkflow

In BlitztextMac/App/BlitztextMacApp.swift:

- handleHotkeyDown
- showPopover

Den maßgeblichen Startkontext vor eigener Popover-Aktivierung und den später
verwendeten Auswahlkontext erfassen. Hold, Toggle und Menüstart unterscheiden.
Keine zusätzlichen Volltraversierungen nur für Logging. Das Ergebnis der Welle
ist ein reproduzierter Fehlversuch mit eindeutigem Abbruchgrund. Erst danach
den erforderlichen Locator- oder Timing-Patch festlegen.

Falls eine Zeitmessung nötig ist, in
BlitztextMac/Services/AudioRecorder.swift bei startRecording nur einen
datenfreien Marker ergänzen. Keine Audioinhalte, Dateipfade oder Recorder-
Refactors.

### Welle B: Besitzvertrag korrigieren

Betroffene Dateien und Symbole:

- BlitztextMac/Services/MediaPlaybackSession.swift
  - MediaPlaybackSnapshot
  - MediaPlaybackSession
  - MediaPlaybackSessionStateMachine.begin
  - confirmPause
  - observe
  - shouldRestore
  - MediaPlaybackTiming
- BlitztextMac/Services/MediaPlaybackCoordinator.swift
  - MediaPlaybackAdapter
  - performPreparation
  - restorePreparedSource
  - pollForConfirmedSnapshot
  - beide konkreten Adapter

Führe einen expliziten Ergebnis-/Besitzvertrag ein, zum Beispiel:

- notIssued(reason)
- issuedUnconfirmed(reason)
- confirmed(receipt)

Ein bestätigter Receipt muss mindestens belegen:

- dieselbe Quelle war unmittelbar vor dem Befehl playing;
- ein expliziter Pause-Befehl wurde ausgeführt und vom Transport akzeptiert;
- dieselbe Quelle wurde danach als paused bestätigt;
- Request-/Session-Generation stimmt;
- dazwischen wurde keine externe Änderung erkannt.

Ein aus der Vorprüfung bereits pausierter Zustand ist notIssued, nicht
confirmed. Ein fehlgeschlagener Befehl mit später beobachtetem paused ist
ebenfalls kein eigener Besitz. Spotify behält seine explizite Apple-Events-
Semantik; den funktionierenden Transport nicht unnötig umbauen.

### Welle C: Chrome gezielt und testbar korrigieren

Neue Datei:

BlitztextMac/Services/ChromeYouTubeAccessibility.swift

Darin eine schmale injizierbare Grenze definieren:

- ChromeYouTubeAXClient
- SystemChromeYouTubeAXClient
- ChromeYouTubeTargetResolver

Die bestehenden inspect-/pause-/resume-Einstiegspunkte bleiben im
ChromeYouTubeMediaPlaybackAdapter. Produktiver Adapter und Tests müssen
denselben Resolver, dieselbe Label-Klassifikation und dieselbe Bestätigungs-
logik verwenden. Kein allgemeines AX-Framework bauen. Eine funktionale
Fenster-/Dokument-Auswahlerweiterung muss durch Welle A begründet sein.

### Welle D: Integration, Tests, Dokumentation

Erhalten und erweitern:

- Tests/MediaPlaybackCoordinatorTests.swift
- Tests/MediaPlaybackSessionTests.swift

Neu:

- Tests/ChromeYouTubeMediaPlaybackAdapterTests.swift

Danach die tatsächlich geänderten Aussagen prüfen und bei Bedarf aktualisieren:

- docs/media-playback-during-dictation.md
- docs/runtime-data.md
- docs/setup.md
- docs/architecture.md
- docs/workflows.md
- docs/privacy.md
- docs/development.md
- README.md

Ein Build-Erfolg darf nicht als erfolgreiche YouTube-Laufzeitabnahme
ausgegeben werden.

## 5. Chrome-Auswahlalgorithmus

### 5.1 Startkontext fixieren

Den maßgeblichen Vordergrundkontext vor Blitztexts eigener Popover-Aktivierung
auf dem MainActor erfassen und unveränderlich an die Vorbereitung übergeben.
Für Menüstarts den Kontext vor der Popover-Präsentation verwenden. Veraltete
Kontexte dürfen nicht in neue Workflows übernommen werden. Eigene Aktivierung
ist von echten Benutzerwechseln während der Vorbereitung zu unterscheiden.

Die bestehende Policy bleibt:

- Unterstützte Vordergrundquelle: nur diese Quelle berücksichtigen.
- Dort paused, unknown oder unsupported: kein Hintergrundfallback.
- Keine unterstützte Vordergrundquelle: unabhängig bestätigbare Provider
  dürfen gemeinsam kontrolliert werden.

### 5.2 Chrome-Prozess und Fenster

AX-Trust im laufenden Blitztext-Prozess prüfen. Die Chrome-Prozessinstanz
eindeutig identifizieren; mehrere nicht zuordenbare Prozesse nicht mit
willkürlichem .first auflösen.

Öffentliche AX-Fensterattribute nutzen:

- fokussiertes Fenster;
- Hauptfenster;
- Fensterliste.

AX-Referenzen vergleichen und deduplizieren, ohne Fenstertitel als Identität
zu verwenden. Listenreihenfolge beweist keine Priorität.

Wenn Chrome maßgebliche Vordergrund-App ist:

- eindeutig zugeordnetes aktuelles Fenster verwenden;
- bei fehlendem AXFocusedWindow nur ein eindeutig belegtes Hauptfenster oder
  das einzige geeignete Browserfenster als Ersatz nutzen;
- ein dort pausierter oder nicht unterstützter Tab darf keinen anderen Fenster-
  oder Tab-Fallback auslösen.

Wenn Chrome Hintergrundprovider ist:

- begrenzt ausgewählte Dokumente geeigneter Browserfenster untersuchen;
- höchstens einen eindeutig identifizierten spielenden Chrome-Player wählen;
- mehrere geeignete spielende Chrome-Player als mehrdeutig ablehnen;
- unvollständige Erkundung niemals als Eindeutigkeit werten;
- keine Fenster oder Tabs aktivieren, um sie untersuchbar zu machen.

### 5.3 Tab und Hauptdokument

Vor einer funktionalen Nutzung live auf der installierten Chrome-Version
verifizieren, welche öffentlichen AX-Beziehungen den ausgewählten Tab seinem
Haupt-WebArea zuordnen. AXSelected, AXSelectedChildren oder andere Attribute
nur verwenden, wenn ihre tatsächliche Darstellung belegt ist.

Das eindeutig zugeordnete Haupt-WebArea bevorzugen. Seitenleisten, fremde
Frames und andere WebAreas nicht als Hauptdokument verwenden. Bei fehlender
eindeutiger Zuordnung unknown liefern und keinen Befehl senden. Inaktive
Hintergrund-Tabs, die AX nicht exponiert, bleiben außerhalb des sicheren Pfads.
Keine Tab-Aktivierung und kein Toggle-Fallback.

### 5.4 Dokument, Player und Identität

Die Dokument-URL mit URLComponents und expliziter Host-Allowlist prüfen.
Kein contains("youtube.com/")-Test. YouTube im Pfad, Query oder auf einem
fremden Host reicht nicht aus.

movie_player ausschließlich innerhalb des zugeordneten Dokuments suchen und
die dokumentbezogene Identität erhalten. Ein Ziel-Token muss mindestens
enthalten:

- Chrome-Prozessinstanz;
- Fensteridentität;
- Tab-/Dokumentidentität;
- Playeridentität;
- beobachtete Dokument-/Mediengeneration.

PID plus URL reicht nicht. Zwei Tabs mit gleicher URL müssen verschiedene Ziele
bleiben. Navigation, Playerersetzung oder Verlust der Zuordnung invalidiert
das Token. Bei späteren Prüfungen nicht einfach einen neuen aktuellen Gewinner
als ursprüngliche Quelle übernehmen.

### 5.5 AX-Traversierung und Buttons

Traversierung nach Zeit, Knotenzahl und Tiefe begrenzen. Abbruch oder
Kommunikationsfehler liefert incomplete/unknown, nicht eine scheinbar
vollständige leere oder eindeutige Kandidatenmenge. AX-Fehler differenzieren:

- Attribut nicht unterstützt;
- kein Wert;
- ungültiges Element;
- Kommunikationsfehler;
- Budget abgelaufen.

Steuerelemente in einem gemeinsamen Durchlauf finden. Nur nutzbare Buttons
innerhalb des ausgewählten movie_player mit angebotener AXPress-Aktion
akzeptieren. Versteckte Vorfahren und deaktivierte Controls berücksichtigen.
Ein nicht unterstütztes optionales Sichtbarkeitsattribut ist nicht automatisch
ein Kommunikationsfehler; die Fallback-Semantik muss live belegt sein.

Bekannte Labels eng normalisieren, zum Beispiel:

- Pause: Pause, Pause (k);
- Play: Play, Wiedergeben (k).

Weitere Formen nur mit konkreter Fixture- oder Live-Evidenz aufnehmen. Kein
allgemeines contains("wiedergabe"). Autoplay, Geschwindigkeit, Einstellungen,
nächstes Video, Replay und ähnliche Controls nie als Play verwenden. Description,
Title und Value nicht blind zu einem Label vermischen, wenn dadurch
unterschiedliche Absichten zusammenfallen. Bei beiden Absichten oder mehreren
nicht auflösbaren Kandidaten unknown und keinen Befehl liefern.

## 6. Explizite Pause und Bestätigung

1. Unmittelbar vor der Aktion Ziel, Generation und eindeutig klassifizierten
   Pause-Button revalidieren.
2. playing und verbleibendes Budget verlangen.
3. Bei paused, changed, unknown oder expired: notIssued; keine spätere
   Besitzübernahme aus diesem Zustand.
4. Genau einen AXPress auf dem validierten Pause-Control ausführen.
5. AX-Rückgabecode erfassen. Nach Fehler oder unklarem Ausgang nicht blind
   wiederholen.
6. Innerhalb der Deadline dieselbe Zielidentität, unveränderte Generation und
   paused bestätigen.
7. Für die Bestätigung zielgebundene Reads nutzen, nicht jedes Mal eine neue
   vollständige Fenstersuche.
8. Kurzes begrenztes Polling darf einen ausstehenden Zustandswechsel abwarten,
   aber niemals erneut drücken.
9. Quellenwechsel sofort abbrechen, auch wenn der neue Snapshot zugleich
   unknown ist.
10. Ohne vollständigen Receipt kein eigener Besitz und später kein Play.

Ein AXPress ist kein atomarer Pause-if-playing-Befehl. Race-Fälle testen:
Benutzer pausiert zwischen Vorprüfung und Aktion, oder Chrome widmet dasselbe
Button-Element vor AXPress um. Bei unsicherem Toggle-Pfad bleibt das
Sicherheits-Gate offen; kein Toggle-Fallback.

## 7. Unveränderte Sicherheitsinvarianten

### Aufnahme, Timeout und Generationen

- Globales monotones Vorbereitungsbudget von 500 ms.
- Deadline in AX-Reads, Traversierung, Vorprüfung und Bestätigung beachten.
- Öffentliche AX-Messaging-Timeouts an die Restzeit anpassen; keine globalen
  Auto-Paste-Timeouts verändern.
- Langsame Provider dürfen die Aufnahmefreigabe nicht blockieren.
- Medienfreigabe und tatsächlichen Recorder-Start getrennt messen.
- Timeout, Cancel und erfolgreiche Vorbereitung unter einer Zustandsentscheidung
  gegenseitig ausschließen.
- Pro Vorbereitung genau ein Abschlusscallback.
- Nach ausgeliefertem Timeout keine späte Session-Adoption.
- Abgelaufene Requests dürfen keine neuen Steueraktionen starten.
- Verspätete eigene Seiteneffekte nur nach erneuter Identitäts- und Besitzprüfung
  bereinigen, niemals durch vorsorgliches Play.

### Gruppen und Spotify

- Besitz, externe Invalidierung und Restore-Versuch pro Quelle führen.
- Unbestätigte Provider verleihen anderen keinen Besitz.
- Teilbudgets und Abbruchgründe explizit machen.
- Keine pauschale Parallelisierung mutierender Befehle als Schnellfix.
- Überlappende alte Inspektionen und AX-Caches gegen neue Providerzugriffe
  absichern.
- Explizite Spotify-Pause-/Play-Semantik unverändert erhalten.
- Bereits pausiertes, gestopptes oder unbekanntes Spotify bleibt unangetastet.

### Benutzeraktionen und Monitoring

Monitoring ab bestätigter Übernahme beginnen. Externe Invalidierung ist
monoton und wird nicht durch einen später wieder passend aussehenden Zustand
reaktiviert. Relevante Änderungen sind Wiedergabe durch Benutzer/anderen
Prozess, Tab-/Dokument-/Medienwechsel, Playerersetzung, Prozessneustart und
Verlust sicherer Beobachtbarkeit. Ein normaler Fokuswechsel in die Diktat-
Ziel-App allein ist kein Medienzielwechsel.

AXObserver-Benachrichtigungen nur ergänzend einsetzen und tatsächliche
Zustellung live belegen. 200-ms-Polling beweist nicht, dass ein schneller
Play-/Pause-Zyklus dazwischen ausgeschlossen wurde. Bei Beobachtungslücke
nicht automatisch restaurieren.

### Restore

Restore nur bei:

- gültigem eigenem Pause-Receipt;
- demselben vollständigen Ziel;
- aktuell eindeutig paused;
- keiner externen Invalidierung;
- noch keinem Restore-Versuch.

Vor Play erneut prüfen. Genau einen expliziten Play-Befehl senden und die
Bestätigung begrenzen. Restored nur melden, wenn dieselbe Quelle nach dem
eigenen akzeptierten Play-Befehl als playing bestätigt wurde. Bereits vom
Benutzer gestartete oder andere spielende Quellen dürfen keinen falschen
Wiederherstellungserfolg erzeugen.

## 8. Diagnose und Datenschutz

Nur den bestehenden lokalen Logger verwenden, keine Telemetrie. Zulässig sind:

- kurzlebige zufällige Request-Korrelation;
- Provider und Triggerklasse;
- Vordergrundklasse chrome/spotify/self/other/none;
- AX-Trust;
- Stufe und endlicher Reason-Code;
- Fenster-/Dokument-/Player-/Button-Anzahlen;
- Suchvollständigkeit und begrenzte Knotenzahl;
- AX-Fehlercode;
- command_issued, command_accepted, same_target;
- coarse state, elapsed ms, remaining ms.

Mindestens unterscheiden:

foreground_policy, ax_untrusted, window_missing, document_ambiguous,
player_missing, player_ambiguous, controls_ambiguous,
inspection_incomplete, deadline_before_command, preflight_not_playing,
target_changed, action_failed, confirmation_timeout, pause_confirmed.

Nicht loggen: URLs oder URL-Hashes, Titel, Tracknamen, Video-IDs, rohe
Source-Identifier, AX-Labels, vollständige AX-Bäume, Fehlerobjekt-Dumps,
Transkripte, Audio, Zwischenablageinhalt oder private Dateipfade. Keine
permanenten Logs pro AX-Knoten oder unverändertem Poll, nur Übergänge und
zusammengefasste Ergebnisse.

## 9. Fokussierte automatisierte Tests

Den produktiven Chrome-Resolver mit einem Fake-AX-Client testen. Ein weiterer
Fake-MediaPlaybackAdapter allein reicht nicht.

### Auswahl

- AXFocusedWindow fehlt, eindeutig belegtes Hauptfenster funktioniert.
- Chrome ist Hintergrundprovider mit eindeutig ausgewähltem YouTube-Dokument.
- Der ausgewählte Tab ist nicht der erste AX-Kindknoten.
- Unterstützte Vordergrundquelle ist paused/unsupported: kein Hintergrundfallback.
- Mehrere Fenster, WebAreas, versteckte Player und echte Mehrdeutigkeit.
- Unvollständiger Baum erzeugt keine Eindeutigkeit.
- Gleiche URL in zwei Tabs/Fenstern bleibt unterschiedliche Identität.
- Nicht exponierter Hintergrundtab verursacht keinen Aktivierungsversuch.

### Buttons

- Belegte deutsche und englische Pause-/Play-Formen.
- Synthetische Verwechslungen wie Wiedergabegeschwindigkeit und Wiedergabe
  pausieren.
- Autoplay, Replay, Einstellungen und fremde Controls.
- Beide Absichten, deaktivierte Controls, versteckte Vorfahren.
- Fehlende AXPress-Aktion und differenzierte AX-Lesefehler.

### Besitz

- Quelle zunächst playing, Benutzer pausiert vor Adapteraktion: null
  Steuerbefehle, kein Besitz, kein Restore, für Chrome und Spotify.
- Aktion fehlgeschlagen, danach paused: kein bestätigter Besitz.
- Akzeptierte Aktion mit verzögertem Zustandswechsel: genau ein Pause-Befehl
  und danach Bestätigung.
- Keine Zustandsbestätigung: kein Play.
- Quellenwechsel während Bestätigung, auch zusammen mit unknown: Abbruch.
- Umwidmung desselben Buttons vor AXPress: kein unerlaubtes Starten.

### Lifecycle und Gruppen

- Ein Provider bestätigt, einer nicht: nur bestätigten Besitz restaurieren.
- Langsamer erster/zweiter Provider bei globalem 500-ms-Budget.
- Bestätigte späte Pause, Cancel während Aktion und Retry.
- Timeout gleichzeitig mit Adoption: genau ein Callback, keine späte Session.
- Externe Änderung nur einer Gruppenquelle: andere Quelle unabhängig prüfen.
- Play-/Pause-Ereignisse zwischen Polls invalidieren Besitz.
- Restore liefert anderes Ziel oder externes playing: kein falscher
  restored-Status.
- Alte Events/Statusmeldungen ändern keinen neuen Workflow.

### Datenschutz

Sensitive Canary-Werte in Fake-URLs, Labels und Fehlerdaten verwenden.
Keiner dieser Werte darf in erzeugten Diagnosen erscheinen. Tests mit
kontrollierter Uhr und Scheduler gegenüber zufälligen Sleeps bevorzugen.

## 10. Manuelle macOS-Abnahme

### Aufbau und Baseline

Lokal dokumentieren:

- geprüfte Revision und tatsächlich gestartete App aus /Applications;
- macOS-/Chrome-Version und Sprache;
- Hold, Toggle und Menüstart;
- grobe Fenster-/Tab-Anordnung;
- AX-Trust der gestarteten App.

Zuerst den ursprünglichen Fehleraufbau ohne zusätzliche AX-Initialisierung
durch Inspector testen, danach einen warmen Vergleichslauf. Keine Chrome-Flags
oder VoiceOver als dauerhafte Voraussetzung einführen.

### Kontrollierte Szenarien

1. YouTube-only: laufendes Video mit Chrome vorne und derselben Anordnung mit
   TextEdit vorne. Hold, Toggle und Menüstart getrennt.
2. Mindestens zehn Wiederholungen des zuvor fehlgeschlagenen Hauptpfads,
   einschließlich eines Starts ohne vorher geöffneten Inspector.
3. Spotify-only als Regression.
4. Spotify plus YouTube mit TextEdit vorne: beide Pause-Receipts und beide
   unabhängig bestätigten Restores. Mit unterstützter Vordergrund-App zusätzlich
   prüfen, dass die Vordergrundregel weiterhin gilt.
5. Bereits pausiertes YouTube und Spotify: kein Pause-Befehl, kein Play am Ende.
6. Nach Blitztext-Pause manuell starten, starten und wieder pausieren, Tab
   wechseln, zu einem zweiten Tab mit gleicher URL wechseln und zurückwechseln.
   Invalidierter Besitz darf nicht restauriert werden.
7. Cancel, sehr kurze Aufnahme, Fehler, Paste-Fallback und Retry:
   ausschließlich eigene unveränderte Pausen einmalig bereinigen.
8. Fehlende AX-Berechtigung sowie kontrolliert langsamer/fehlerhafter AX-Pfad:
   Aufnahme freigeben, keine unbestätigten Play-Befehle.

### Beobachtbare Belege

Erfolgreiche Läufe müssen zeigen:

- playing vor der Aktion;
- genau einen akzeptierten Pause-Aufruf;
- dasselbe Ziel danach paused;
- Pausebestätigung vor Aufnahmefreigabe;
- sichtbaren tatsächlichen Wiedergabestopp;
- keine Wiederaufnahme allein beim Mikrofonstopp;
- zulässigen terminalen Ausgang;
- genau einen eigenen Play-Aufruf und playing-Bestätigung desselben Ziels.

Fail-open-Läufe müssen zeigen:

- konkreten Abbruchgrund;
- Freigabe spätestens an der 500-ms-Medien-Deadline;
- keine verspätete Session-Adoption;
- keinen unberechtigten Restore.

Medienfreigabe, Main-Queue-Zustellung und tatsächlichen Recorder-Start
getrennt ausweisen. UI-Status allein ist kein Nachweis für gestarteten
Recorder oder gestopptes Video.

Für lokale, gefilterte Unified Logs kann verwendet werden:

    log stream --style compact --level debug --predicate 'subsystem == "app.blitztext.mac" AND category BEGINSWITH "MediaPlayback"'

## 11. Build und Abschlusskriterien

Ausführen:

- git diff --check;
- bestehende Standalone-Tests gemäß docs/development.md;
- neue AX-Testdatei und Hilfsquellen in denselben Testbefehlen;
- SDK über das aktive Xcode bestimmen;
- kein erfundenes swift test, da bestehende Tests @main-Programme sind;
- ./build.sh --debug;
- universale App kontrolliert installieren und genau diese App testen.

Bis zur Live-Evidenz offen bleiben:

- tatsächliche Chrome-Tab-/Dokumentbeziehungen;
- AX-Verfügbarkeit ohne vorherigen Inspector;
- nicht exponierte inaktive Hintergrundtabs;
- reale Button-Labels und Nutzbarkeit;
- Ereignisabdeckung externer Benutzeraktionen;
- verbleibendes Race zwischen Zustandsprüfung und AXPress.

Done erst, wenn:

1. Der jüngste reale Fehlertyp auf der Baseline mit konkreter Fehlerstufe
   reproduziert und von bloßer Vordergrundpolitik unterschieden ist.
2. Derselbe Aufbau mit der Korrektur wiederholt erfolgreich ist.
3. Produktive AX-Auswahl und realer Fehlerfall fokussiert regressionstestbar
   sind.
4. Der Besitzfehler bei Pause ohne eigenen Befehl für beide Provider geschlossen
   ist.
5. Spotify-only, Gruppenfall und negative Restore-Fälle bestanden sind.
6. 500-ms-Fail-open und Generationstrennung belegt sind.
7. Diagnosen keine verbotenen Daten enthalten.
8. Dokumentation Fähigkeiten, Grenzen und tatsächliche Abnahme korrekt nennt.

Wenn der reale Problemfall ein nicht sicher exponierter Hintergrundtab ist oder
Aktions-/Besitzsicherheit ungeklärt bleibt, bleibt die Abnahme offen. Dann den
konkreten Capability-Blocker dokumentieren, sicher fail-open bleiben und Build
oder Tests nicht als Beleg einer gelösten YouTube-Steuerung werten.
