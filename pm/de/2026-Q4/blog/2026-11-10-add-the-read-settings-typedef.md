<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Den Typ ReadSettings neben GgRc anbieten

## Motivation

- `GgRc` ist die `~/.gg_rc` des Nutzers. `GgRc.load` liest die Datei und
  schreibt sie mit allen Voreinstellungen, wenn sie fehlt.
- Ein Befehl, der eine Einstellung liest, sollte `GgRc.load` nicht direkt
  aufrufen: Sonst würde jeder Test die echte Datei im Home-Verzeichnis
  lesen oder sogar anlegen. Der Befehl bekommt die Lesefunktion deshalb
  im Konstruktor, und ein Test übergibt eine, die `GgRc.defaults()` oder
  ein eigenes `GgRc` liefert.
- Ein solches Argument braucht einen Funktionstyp. Bisher bot dieses
  Paket `GgRc` an, aber nicht den Typ der Funktion, die es lädt. Jeder
  Nutzer musste diesen Typ selbst deklarieren.
- Zwei getrennte Deklarationen desselben Typs unter demselben Namen sind
  für Dart zwei verschiedene Deklarationen. Eine Bibliothek, die beide
  exportiert, lässt sich nicht kompilieren.
- Der Typ gehört dorthin, wo `GgRc` liegt: eine Deklaration, die jeder
  Nutzer von `GgRc` importiert.

## Strategie

- Den Typ in `lib/src/backend/gg_rc.dart` deklarieren, direkt über `GgRc`
- Die Signatur beibehalten, die `GgRc.load` für sein Pflichtargument
  schon hat, sodass `GgRc.load` selbst ein gültiger Wert des Typs ist
- Ihn über das bestehende `export 'src/backend/gg_rc.dart'` der
  Bibliothek exportieren, ohne neue Datei und ohne neuen Export
- An `GgRc` selbst nichts ändern

## Realisierung

- Neuer öffentlicher Typ:

  ```dart
  /// Reads the user's settings — [GgRc.load] fits.
  typedef ReadSettings = GgRc Function({required GgLog ggLog});
  ```

- `GgRc.load` hat weitere optionale Parameter (`file`, `environment`).
  Ein Funktionstyp, der nur `ggLog` nennt, akzeptiert es trotzdem. Aufrufer
  schreiben also `readSettings: GgRc.load`, ohne Hülle
- Ein Test übergibt stattdessen eine Closure:
  `readSettings: ({required ggLog}) => const GgRc.defaults()`
- `CLAUDE.md` und `README.md` nennen den Typ bei `GgRc`

## Ergebnis

- `package:gg_multi_core/gg_multi_core.dart` exportiert jetzt
  `ReadSettings`
- Für bestehenden Code ändert sich nichts: Das Release fügt einen Namen
  hinzu, es entfernt oder ändert keinen
- Veröffentlicht als Minor-Version

## Offene Punkte

- Keine
