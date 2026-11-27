<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Getrackte Dateien beim Kopieren eines Repositorys behalten

## Motivation

- `copyDirectory` kopiert ein Repository, z. B. in den Ordner eines
  Tickets. Es lässt weg, was zur Arbeitskopie gehört und nicht zum
  Repository: `node_modules` und die Dateien, die gg für sich selbst
  schreibt, etwa `ticket.json`, `publish_config.json` oder
  `publish_state.json`.
- Es ließ sie nach ihrem Namen weg, auf jeder Ebene des Baums. Ein
  Repository, das eine Datei mit einem dieser Namen trackt, verlor sie in
  der Kopie: eine Fixture `test/data/ticket.json` oder ein Dokument
  `doc/publish_config.json`.
- Die Kopie unterschied sich dann stillschweigend von ihrer Quelle. git
  zeigte die Datei als gelöscht, und ein Commit über alles nahm die
  Löschung mit.

## Strategie

- Die eigenen Dateien von gg über den Ort benennen, an den gg sie
  schreibt: den Ordner `.gg` des kopierten Verzeichnisses. Alles andere
  mit demselben Namen ist Inhalt des Repositorys und wird kopiert.
- Den einfachen Fall einfach lassen: Ein bloßer Name heißt weiterhin »auf
  jeder Ebene«, was für `node_modules` richtig ist.
- Für die Aufrufer nichts ändern. Der Parameter bleibt eine Menge von
  Strings; neu ist nur die Bedeutung eines Eintrags mit Schrägstrich.

## Orte und Namen in skipNames

- Ein Eintrag von `skipNames` mit einem `/` benennt einen Ort unterhalb
  der Quelle, z. B. `.gg/publish_state.json`. Nur diese Datei oder dieser
  Ordner wird weggelassen.
- Ein Eintrag ohne `/` ist ein Name. Er wird weggelassen, wo immer er
  vorkommt, wie bisher.
- Führende, abschließende und doppelte Schrägstriche werden ignoriert:
  `/.gg/ticket.json` und `.gg//ticket.json` benennen denselben Ort. Ein
  Ort wird immer mit `/` geschrieben, auch unter Windows.
- Das private `_copyDirectory` trägt den Ort des Ordners, in dem es
  gerade ist, den Baum hinunter und vergleicht jeden Eintrag mit den
  Namen und den Orten.

## Der neue Standard

- `node_modules` auf jeder Ebene.
- Die Arbeitsdateien von gg, jede an ihrem Ort in `.gg`:
  `publish_config.json`, `publish_state.json`, `create_repo_state.json`,
  `gg-publish.json`, `.gg-publish.json`, `.ticket.json`, `ticket.json`
  und `.gg_localize_refs_publish_to_backup.json`.
- Eine getrackte `ticket.json` oder `publish_config.json` irgendwo sonst
  im Repository wird kopiert.

## Tests

- Eine Datei, die wie eine der Dateien von gg heißt, übersteht die Kopie,
  wenn sie nicht in `.gg` liegt — auf der obersten Ebene und in einem
  Unterordner.
- Die Dateien in `.gg` werden weiterhin weggelassen; `.gg/gg.json` wird
  weiterhin kopiert.
- Orte mit führenden, abschließenden und doppelten Schrägstrichen; ein
  Ort, der einen Ordner benennt; ein Name und ein Ort in derselben Menge.
- `CLAUDE.md` hat einen Abschnitt zum Kopieren eines Repositorys.

## Offene Punkte

- Ein Aufrufer, der eigene `skipNames` mit bloßen Namen wie `ticket.json`
  übergibt, behält das alte Verhalten: Die Datei wird auf jeder Ebene
  weggelassen. Geändert hat sich nur der Standard.
- Weitere Dateien, die gg künftig nach `.gg` schreibt, müssen in den
  Standard aufgenommen werden; der Ordner `.gg` wird nicht als Ganzes
  übersprungen, weil `.gg/gg.json` getrackt ist.
