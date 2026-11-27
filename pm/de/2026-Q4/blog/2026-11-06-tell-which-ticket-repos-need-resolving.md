<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Erkennen, welche Ticket-Repos neu aufgelöst werden müssen

## Motivation

- Das Auflösen eines Repos ist der teure Teil beim Lokalisieren eines
  Tickets. Mit `pub upgrade` kostet jede git-Abhängigkeit eine Verbindung
  zu ihrem Remote, pro Repo und Lauf.
- Wer nur einige Repos eines Tickets ändert, konnte nicht fragen, welche
  Repos wirklich neu aufgelöst werden müssen, und löste deshalb alle auf.
- Nur einige Repos aufzulösen darf die heilende Wirkung des Auflösens
  aller nicht verlieren: Ein Repo, das ein früherer Lauf unaufgelöst ließ,
  muss gefunden werden.

## Strategie

- Die bestehende Prüfung auf nicht lokalisierte Referenzen als eigenen,
  rein lesenden Aufruf anbieten.
- Eine reine Datei-Prüfung für eine Auflösung ergänzen, die fehlt oder die
  Pfad-Overrides nicht nutzt.
- `pub get` zum einzigen Weg machen, auf dem das Lokalisieren auflöst.

## TicketLocalizer.outOfSync

- Liefert die Repos mit nicht lokalisierten Referenzen, in der gegebenen
  Reihenfolge und als die übergebenen `Node`-Instanzen.
- Nutzt dieselbe `UnlocalizedRefs`-Prüfung wie `check` und
  `localizeUnlocalized`, offline und ohne Suche nach fehlenden Repos.
- `localizeUnlocalized` und `outOfSync` teilen sich jetzt einen Filter.

## repoDependenciesOutdated

- Wahr für eine `pubspec.yaml`, deren `.dart_tool/package_config.json`
  fehlt, unlesbar ist oder nicht jeden `path`-Override aus
  `pubspec_overrides.yaml` auf diesen Pfad auflöst – ein `pub get`, das
  nach dem Lokalisieren scheiterte oder nie lief.
- Wahr für eine `package.json` ohne `node_modules`.
- Verglichen wird der Inhalt, nicht der Zeitstempel: `pub get` lässt
  `package_config.json` unverändert, wenn sich nichts geändert hat. Ein
  Checkout, der nur `pubspec.yaml` berührt, wirkte sonst für immer
  veraltet.

## Nur noch pub get

- `localize` und `localizeAndCommit` lösen mit `pub get` auf, das die
  gesperrten Versionen behält.
- Ihr Parameter `upgrade` ist veraltet und entfällt mit dem nächsten
  Major-Release; Upgraden gehört zu `gg do push`.

## Offene Punkte

- `UnlocalizedRefs` baut den Abhängigkeitsgraphen einmal pro Repo; bei
  großen Tickets wäre ein gemeinsamer Graph schneller.
