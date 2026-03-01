# Konzept: Automatisches QSO-Logbuch & Digitale QSL-Karten

## 1. Zusammenfassung

DigiFox soll ein vollwertiges Amateurfunk-Logbuch erhalten, das QSOs automatisch
mitloggt, sobald ein abgeschlossenes QSO erkannt wird. Dazu kommen digitale QSL-Karten
und optionaler Export zu LoTW / ADIF.

---

## 2. Auto-Logging: Automatisches QSO-Erkennen und Loggen

### 2.1 Wann gilt ein QSO als abgeschlossen?

**FT8:** Ein QSO folgt einem festen Ablauf:

```
TX1: CQ DL1ABC JO31          ← CQ rufen
TX2: DL1ABC N0CALL EN40       ← Antwort mit Grid
TX3: N0CALL DL1ABC +05        ← Signal-Report
TX4: DL1ABC N0CALL R-12       ← Report bestätigen
TX5: N0CALL DL1ABC RR73       ← QSO bestätigt
TX6: DL1ABC N0CALL 73         ← Abschied
```

**Trigger zum Auto-Loggen:**
- Wenn **TX5 (RR73)** gesendet oder empfangen wird → QSO gilt als bestätigt
- Alternativ: Wenn `73` in einer Nachricht vorkommt und `dxCall` gesetzt ist

**JS8Call:** Kein festes Protokoll, daher:
- Auto-Log wenn `/QSO` oder `73` als Directed Message erkannt wird
- Oder manueller Log-Button (wie jetzt)

**CW:** Rein manuell (da CW-Parsing zu unzuverlässig für Auto-Detection)

### 2.2 Lock-Mechanismus ("QSO in Arbeit")

Wenn DigiFox erkennt, dass ein QSO läuft (ab TX2/Response), wird ein interner
QSO-Lock gesetzt:

```
┌─────────────────────────────────────────┐
│  QSO-Status-Anzeige (im QSOPanel)       │
│                                         │
│  🔴 QSO aktiv: DL1ABC                  │
│  ├─ Grid: JO31                          │
│  ├─ Report: -12 dB                      │
│  ├─ Band: 20m (14.074 MHz)             │
│  ├─ Schritt: 3/5 (Report gesendet)     │
│  └─ Dauer: 01:15                        │
│                                         │
│  [ Abbrechen ]        [ Jetzt loggen ]  │
└─────────────────────────────────────────┘
```

**Was der Lock bewirkt:**
- Sammelt alle QSO-relevanten Daten während des Ablaufs (Callsign, Grid, Reports,
  Frequenz, Zeitstempel Start/Ende, Band, Mode)
- Verhindert versehentliches Überschreiben bei Doppelklick auf andere Station
- Zeigt visuellen Fortschritt des QSO-Ablaufs
- Wird automatisch freigegeben nach erfolgreichem Log oder nach Timeout (5 Minuten
  ohne Aktivität)

### 2.3 Datenmodell: QSORecord (erweitert)

Das bisherige `QSOLogEntry` wird deutlich erweitert:

```
QSORecord
├── id: UUID
├── timestampStart: Date         ← Beginn des QSO
├── timestampEnd: Date           ← Ende (RR73/73)
├── myCallsign: String           ← Eigenes Rufzeichen
├── myGrid: String               ← Eigener Locator
├── dxCallsign: String           ← Gegenstation
├── dxGrid: String               ← Locator der Gegenstation
├── frequency: Double            ← Dial + Audio-Offset
├── band: String                 ← z.B. "20m"
├── mode: String                 ← "FT8", "JS8", "CW"
├── rstSent: String              ← Gesendeter Report
├── rstReceived: String          ← Empfangener Report
├── qslStatus: QSLStatus         ← .none / .sent / .received / .confirmed
├── qslMethod: QSLMethod?        ← .digital / .bureau / .direct / .lotw
├── qslCardImageData: Data?      ← Gespeicherte QSL-Karte (optional)
├── notes: String                ← Freitext-Notizen
└── adifExported: Bool           ← Schon exportiert?
```

---

## 3. Persistentes Logbuch

### 3.1 Speicherung

**Empfehlung: SwiftData** (ab iOS 17, passt perfekt zum Projekt-Target)

- Automatische Persistierung auf dem Gerät
- iCloud-Sync möglich (für Backup)
- Kein manuelles Dateischreiben nötig
- Volltextsuche über Callsigns, Grids etc.

**Alternative:** JSON-Datei im Documents-Ordner (einfacher, aber weniger Features)

### 3.2 Logbuch-Ansicht

```
┌─────────────────────────────────────────────────────┐
│  📖 Logbuch                          🔍 [ Suche ]  │
│─────────────────────────────────────────────────────│
│  Filter: [ Alle ▾ ] [ Alle Bänder ▾ ] [ QSL ▾ ]  │
│─────────────────────────────────────────────────────│
│                                                     │
│  01.03.2026 — 3 QSOs                               │
│  ┌─────────────────────────────────────────────┐   │
│  │ 14:32 UTC  DL1ABC   JO31   FT8   20m  -12  │   │
│  │            QSL: ✅ bestätigt (LoTW)         │   │
│  ├─────────────────────────────────────────────┤   │
│  │ 14:15 UTC  N0CALL   EN40   FT8   20m  +05  │   │
│  │            QSL: 📤 gesendet                 │   │
│  ├─────────────────────────────────────────────┤   │
│  │ 13:50 UTC  JA1XYZ   PM95   FT8   20m  -18  │   │
│  │            QSL: —                           │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  28.02.2026 — 5 QSOs                               │
│  ...                                                │
│                                                     │
│  ─────────────────────────────────────────────────  │
│  Gesamt: 128 QSOs  ·  45 DXCC  ·  23 bestätigt    │
└─────────────────────────────────────────────────────┘
```

**Tap auf ein QSO öffnet Detailansicht:**

```
┌─────────────────────────────────────────┐
│  ← Logbuch        QSO-Details           │
│─────────────────────────────────────────│
│                                         │
│  DL1ABC                                │
│  Grid: JO31  ·  20m  ·  FT8            │
│  14.074.300 Hz                          │
│                                         │
│  Start: 14:30:15 UTC                    │
│  Ende:  14:32:45 UTC                    │
│                                         │
│  Report gesendet:   -12 dB             │
│  Report empfangen:  +05 dB             │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  QSL-Status                     │   │
│  │  ○ Keine QSL                    │   │
│  │  ○ Gesendet                     │   │
│  │  ● Bestätigt                    │   │
│  │  Via: LoTW                      │   │
│  └─────────────────────────────────┘   │
│                                         │
│  Notizen:                               │
│  ┌─────────────────────────────────┐   │
│  │ Nette Station, gutes Signal     │   │
│  └─────────────────────────────────┘   │
│                                         │
│  [ QSL-Karte erstellen ]               │
│  [ ADIF exportieren ]                   │
│                                         │
└─────────────────────────────────────────┘
```

---

## 4. Digitale QSL-Karten

### 4.1 Grundidee

DigiFox generiert automatisch eine hübsche QSL-Karte als Bild, die man per
AirDrop, iMessage, E-Mail oder Social Media teilen kann.

### 4.2 QSL-Karten-Design (Templates)

Drei Vorlagen zur Auswahl:

**Template 1: "Klassisch"**
```
╔═══════════════════════════════════════════════╗
║                                               ║
║   ┌──────────┐                                ║
║   │ DIGIFOX  │   Bestätigung des QSO mit     ║
║   │  🦊📻   │                                ║
║   └──────────┘   DL1ABC                      ║
║                                               ║
║   Datum:     01.03.2026  14:32 UTC           ║
║   Band:      20m (14.074 MHz)                ║
║   Mode:      FT8                              ║
║   RST:       -12 dB                          ║
║                                               ║
║   Via:  DE1ABC  ·  JO31                      ║
║                                               ║
║   PSE QSL  ☐    TNX QSL  ☑                  ║
║                                               ║
╚═══════════════════════════════════════════════╝
```

**Template 2: "Modern / Dunkel"**
- Dunkler Hintergrund mit Waterfall-Screenshot als Hintergrundbild
- Neon-Akzente in DigiFox-Orange
- Minimalistisch, große Schrift

**Template 3: "Karte"**
- Weltkarte im Hintergrund mit eingezeichnetem Pfad zwischen den beiden Locatoren
- Distanz in km automatisch berechnet
- Great-Circle-Linie visualisiert

### 4.3 QSL-Karten-Editor (Bedienungskonzept)

```
┌─────────────────────────────────────────────────────┐
│  ← Zurück          QSL-Karte erstellen              │
│─────────────────────────────────────────────────────│
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │                                             │   │
│  │         [ LIVE-VORSCHAU DER KARTE ]         │   │
│  │                                             │   │
│  │   Bestätigung QSO mit DL1ABC               │   │
│  │   01.03.2026 14:32 UTC · 20m · FT8         │   │
│  │   RST: -12 dB                              │   │
│  │                                             │   │
│  │   DE1ABC · JO31 → DL1ABC · JO31            │   │
│  │   Distanz: 245 km                          │   │
│  │                                             │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  Design:                                            │
│  [ Klassisch ]  [ Modern ]  [ Karte ]              │
│                                                     │
│  Eigenes Foto als Hintergrund:                      │
│  [ Foto auswählen... ]                              │
│                                                     │
│  Persönliche Nachricht:                             │
│  ┌─────────────────────────────────────────────┐   │
│  │ 73 de DE1ABC!                               │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                     │
│  [ 💾 Speichern ]    [ 📤 Teilen ]                 │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Teilen-Optionen (iOS Share Sheet):**
- Als Bild in Fotos speichern
- AirDrop an andere OM
- iMessage / WhatsApp / Telegram
- E-Mail
- Social Media (Twitter/X, Mastodon)

### 4.4 Automatische QSL-Vorschläge

Nach jedem geloggten QSO erscheint ein dezenter Banner:

```
┌─────────────────────────────────────────┐
│  ✅ QSO mit DL1ABC geloggt             │
│                                         │
│  [ QSL-Karte erstellen ]  [ Schließen ]│
└─────────────────────────────────────────┘
```

---

## 5. Export & Anbindungen

### 5.1 ADIF-Export (Amateur Data Interchange Format)

**ADIF** ist der universelle Standard für Logbuch-Austausch. DigiFox sollte
ADIF 3.1.4 unterstützen.

**Exportformat-Beispiel:**
```
<CALL:6>DL1ABC <GRIDSQUARE:4>JO31 <MODE:3>FT8 <RST_SENT:3>-12
<RST_RCVD:3>+05 <QSO_DATE:8>20260301 <TIME_ON:6>143215
<BAND:3>20m <FREQ:8>14.07430 <MY_GRIDSQUARE:4>JO31 <EOR>
```

**Export-Optionen:**
- Einzelnes QSO exportieren
- Alle QSOs exportieren
- Zeitraum-basierter Export (von-bis Datum)
- "Nur neue" (seit letztem Export)
- Export als `.adi`-Datei → iOS Share Sheet

### 5.2 LoTW (Logbook of The World) — Ideen

LoTW ist der Goldstandard für QSO-Bestätigungen, betrieben von der ARRL.

**Herausforderung:** LoTW erfordert:
1. Ein TQ6-Zertifikat (digitale Signatur, persönlich an Rufzeichen gebunden)
2. Signierte ADIF-Dateien (.tq8-Format)
3. Upload über HTTPS-API oder TQSL-Software

**Mögliche Ansätze:**

| Ansatz | Aufwand | Machbarkeit |
|--------|---------|-------------|
| **A) ADIF-Export → TQSL am Mac** | Gering | Einfach. DigiFox exportiert ADIF, Nutzer importiert manuell in TQSL auf dem Desktop. |
| **B) Direkter LoTW-Upload aus App** | Hoch | Erfordert TQ6-Zertifikat-Import in die App + Signierung. Komplex aber möglich. |
| **C) TQSL-Commandline auf Mac via Shortcut** | Mittel | ADIF per AirDrop zum Mac, Shortcut startet tqsl CLI. Halbautomatisch. |

**Empfehlung:** Starte mit **Ansatz A** (simpler ADIF-Export). Das ist sofort nützlich und
deckt 90% der Fälle ab. LoTW-Integration kann später als Premium-Feature kommen.

### 5.3 Weitere Plattformen (optional, Zukunft)

- **eQSL.cc** — ADIF-Upload per HTTP (einfacher als LoTW, kein Zertifikat nötig)
- **QRZ.com Logbook** — API-Key basiert, REST-API verfügbar
- **Club Log** — Für DXCC-Tracking, HTTPS-Upload
- **HamQTH** — ADIF-Upload per POST

---

## 6. Bedienungskonzept (Navigation)

### 6.1 Neue Tab-Struktur

Die App bekommt einen zusätzlichen Tab:

```
┌──────┬──────┬──────┬──────┬──────┬──────┐
│ FT8  │ JS8  │  CW  │  📖  │  📊  │  ⚙️  │
│      │ Call │      │ Log  │Aktiv.│ Einst│
└──────┴──────┴──────┴──────┴──────┴──────┘
                       ↑ NEU
```

Alternativ: Log-Tab ersetzt den bisherigen Aktivitäts-Tab und die
Band-Aktivität wandert als Unter-Tab in den Log-Bereich.

### 6.2 Workflow: Typischer Ablauf

```
1. Nutzer empfängt CQ von DL1ABC
          │
          ▼
2. Doppeltap auf DL1ABC in Band-Aktivität
          │
          ▼
3. QSO-Lock wird gesetzt, Panel zeigt:
   "QSO aktiv: DL1ABC" + Fortschrittsanzeige
          │
          ▼
4. Auto-Sequenz läuft durch (TX1→TX5)
          │
          ▼
5. Bei RR73/73: Auto-Log
   ┌──────────────────────────────────┐
   │ ✅ QSO mit DL1ABC geloggt       │
   │ [ QSL erstellen ] [ Schließen ] │
   └──────────────────────────────────┘
          │
          ▼
6. Optional: QSL-Karte erstellen & teilen
          │
          ▼
7. QSO-Lock wird freigegeben,
   bereit für nächsten Kontakt
```

### 6.3 Einstellungen (Erweiterung)

Unter Einstellungen → Logbuch:

```
┌─────────────────────────────────────────┐
│  Logbuch-Einstellungen                  │
│─────────────────────────────────────────│
│                                         │
│  Auto-Log                               │
│  ┌─────────────────────────────────┐   │
│  │ FT8: Automatisch bei RR73  [✓] │   │
│  │ JS8: Nur manuell           [✓] │   │
│  │ CW:  Nur manuell           [✓] │   │
│  └─────────────────────────────────┘   │
│                                         │
│  QSL-Karten                             │
│  ┌─────────────────────────────────┐   │
│  │ Standard-Template: [Klassisch▾] │   │
│  │ Nach Log fragen:           [✓]  │   │
│  │ Eigenes Hintergrundbild: [...]  │   │
│  └─────────────────────────────────┘   │
│                                         │
│  Export                                 │
│  ┌─────────────────────────────────┐   │
│  │ [ Alle QSOs als ADIF export. ] │   │
│  │ [ Nur neue seit letztem Exp. ] │   │
│  └─────────────────────────────────┘   │
│                                         │
└─────────────────────────────────────────┘
```

---

## 7. Zusammenfassung der Features (Priorisierung)

| Prio | Feature | Beschreibung |
|------|---------|-------------|
| P1 | QSO-Lock/Tracker | Visueller QSO-Fortschritt während aktivem QSO |
| P1 | Auto-Log bei RR73 | Automatisches Loggen bei FT8-QSO-Abschluss |
| P1 | Persistentes Logbuch | SwiftData-Speicherung + Logbuch-Tab |
| P2 | ADIF-Export | .adi-Dateiexport über iOS Share Sheet |
| P2 | Digitale QSL-Karten | Template-basierte QSL-Karten-Erstellung |
| P3 | QSL-Karten-Templates | Mehrere Designs (Klassisch/Modern/Karte) |
| P3 | Statistiken | DXCC-Counter, Band-Statistik, QSO-Übersicht |
| P4 | LoTW-Upload | Direkter Upload (erfordert Zertifikat-Handling) |
| P4 | eQSL/QRZ-Anbindung | API-basierter Upload |

---

## 8. Technische Hinweise

- **SwiftData** für Persistierung (passt zu iOS 17+ Target)
- **Swift Charts** für Statistiken (Bands, Modi, Zeiträume)
- QSL-Karten-Rendering via **SwiftUI → UIImage** (Canvas/ImageRenderer)
- Weltkarte-Template via **MapKit** Snapshot
- ADIF-Parsing ist simpel (Tag-basiertes Textformat, kein XML)
- Share Sheet über `UIActivityViewController` / `.shareLink` Modifier
- Great-Circle-Distanz: Haversine-Formel aus den Maidenhead-Locatoren
