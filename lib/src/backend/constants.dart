// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The ocean folder holding the pristine clones of all repos
const String ggMultiOceanFolder = '.ocean';

/// The former name of [ggMultiOceanFolder]; auto-renamed at the next start
const String ggMultiLegacyMasterFolder = '.master';

/// The folder tickets used to be stored in.
///
/// Tickets live directly in the workspace root today — beside `.ocean` — so
/// nothing creates this folder anymore. It is still recognized so a workspace
/// created by an older gg keeps working: `WorkspaceUtils.ticketDirs` lists the
/// tickets inside it and `WorkspaceUtils.ticketDir` resolves a name to them.
const String ggMultiLegacyTicketFolder = 'tickets';

/// The trash folder beside `.ocean` that holds removed tickets and repos
const String ggMultiTrashFolder = '.trash';
