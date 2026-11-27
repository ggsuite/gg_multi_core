<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Einen belegten Ticket-Ordner erklären

## Motivation

- `cleanUpTicket` verschiebt ein fertiges Ticket in den Papierkorb.
- Unter Windows scheitert das, solange ein Terminal oder ein Editor wie
  VS Code im Ticket-Ordner steht: „used by another process“, Fehler 32.
- Der Nutzer sah nur den rohen Fehler. Er sagte weder warum, noch was schon
  erledigt war, noch wie man das Aufräumen zu Ende bringt.
- Oft lag das Ticket schon im Papierkorb und nur der leere Ordner war
  übrig. Auch das sagte die Meldung nicht.

## Strategie

- Den Windows-Fehler „Sharing Violation“ erkennen.
- Sagen, was übrig ist, und die Befehle nennen, die das Aufräumen beenden.
- Alle anderen Fehler unverändert lassen.

## Belegten Ordner erkennen

- Eine `FileSystemException` mit OS-Fehlercode 32
  (`ERROR_SHARING_VIOLATION`) gilt als belegter Ordner.

## Sagen, wie es weitergeht

- Wird das Umbenennen verweigert, kopiert das Verschieben und löscht
  danach. Ist nur der leere Ticket-Ordner übrig, liegt das Ticket schon im
  Papierkorb. Der Hinweis sagt das und nennt `cd <root>` und
  `rmdir <ticket>`.
- Steht das Ticket noch an seinem Platz, bittet der Hinweis, den Ordner zu
  verlassen, das Programm zu schließen und es mit
  `gg do rm ticket <ticket>` erneut zu versuchen.
- `rmdir` bekommt den Pfad relativ zur Workspace-Wurzel, damit auch ein
  alter `tickets/<ticket>`-Ordner passt.

## Tests

- `cleanUpTicket` nimmt optional eine `moveToTrash`-Funktion, damit Tests
  den Windows-Fehler auf jeder Plattform auslösen können.

## Offene Punkte

- Auch andere Programme als Terminals und Editoren können den Ordner
  belegen; der Hinweis nennt nur die üblichen.
