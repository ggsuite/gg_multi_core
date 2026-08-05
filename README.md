# gg_multi_core

Workspace model of the gg_multi tool family - the ocean/tickets/trash
layout, organization folders, url parsing, git platforms, ticket
metadata and state.

`gg_multi` manages multi-package workspaces and orchestrates editing,
reviewing and publishing across all repos of a ticket. This package is
the foundation the other members of the family (`gg_multi_workspace`,
`gg_multi_commit`, `gg_multi_do_publish`) build on.

## What it provides

- **Workspace layout** (`workspace_utils.dart`, `constants.dart`,
  `ocean_migration.dart`, `trash.dart`): the three folders at a
  workspace root — `.ocean/` (all registered repos), `tickets/<id>/`
  (per-ticket clones) and `.trash/<id>/` (closed tickets, moved, never
  deleted) — plus `WorkspaceUtils.detectTicketPath()`, which finds the
  context from any working directory, and the automatic `.master` →
  `.ocean` rename for legacy workspaces.
- **Organization folders** (`repo_folder_resolver.dart`,
  `workspace_migration.dart`): the `<workspace>/<org>/<repo>` layout —
  destination, listing, resolving by name/manifest/remote url — and
  the migration that moves flat legacy workspaces into it.
- **Url parsing & git platforms** (`url_parser.dart`,
  `git_platform.dart`, `organization.dart`, `organization_utils.dart`,
  `repository.dart`): every GitHub and Azure DevOps url shape the
  platforms hand out, `fetchOrgRepos` via the `gh` / `az` CLIs, and
  the organization-selection prompt for ambiguous repo names.
- **Ticket metadata & state** (`ticket_json.dart`,
  `ticket_state.dart`, `ticket_cleanup.dart`): the local `ticket.json`
  (never committed), the ticket-level success cache in
  `<ticket>/.gg.json`, and `cleanUpTicket`, which deletes the remote
  feature branches and moves the whole ticket folder to the trash.
- **Git helpers** (`git_snapshot.dart`): `runGit` and
  `captureUncommitted`, shared by the push and publish flows.
- **Publish skip check** (`publish_skip_check.dart`): decides whether
  a repo needs a release at all — dependency bumps outside the
  published constraint, or manual (non-`#gg:`) changes since the last
  release.

## License

`gg_multi_core` is licensed under the terms specified in the `LICENSE`
file.
