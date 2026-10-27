# Graphify Operating Guide

## Why it is included

Graphify gives the agents a per-bot relationship map so they can discover impact without repeatedly opening large portions of the repository.

## Pinned version

The current Dev Kit pins Graphify in `graph/config/graphify-version.json`. Do not silently upgrade it on developer machines. Change the pin through normal review, test it against pilot bots, then roll it forward.

## Mandatory activation

Graphify is activated automatically by a checked payload import. To repair or verify an installed bot directly:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
```

Activation verifies managed Dev Kit files and installs or checks the pinned Graphify package. For an existing UiPath project it reuses or refreshes the bot-local graph and proves that `graphify-out/graph.json` is non-empty valid JSON; for a project-less new bot it records deferred extraction until stable finalization.

Graphify git hooks and VS Code integration are disabled in v0.11.0 because they can invoke Graphify outside the hardened wrappers. For an existing project, the Coordinator reuses or refreshes the graph before planning when its content fingerprint requires it; new-bot work defers graph discovery until stable finalization. The Developer refreshes once after final source changes when needed, and the Auditor consumes that final snapshot when `AUDIT_MODE` is `LIGHT` or `FULL`. For `AUDIT_MODE: NONE`, the Coordinator/Developer use the final snapshot for completion. A post-audit refresh is unnecessary when the content fingerprint is unchanged.

Graphify refresh optimization uses a git-based content fingerprint since v0.11.2: an `-Mode Update` refresh reuses the prior graph when tracked/untracked source and the Graphify ruleset files are unchanged, and always falls back to a full extract when git is unavailable, the fingerprint differs, or `-Force` is passed. Graphify's own binary, backend, isolation, and query-logging behavior are unchanged.

## Build the graph

From the bot repo:

```powershell
./.rpa-ai/scripts/Refresh-BotGraph.ps1 -Mode Build
```

The default `.graphifyignore` excludes non-code semantic artifacts, and the wrapper uses `--no-cluster` so the initial graph does not need model-backed community naming.

## Query

```powershell
./.rpa-ai/scripts/Query-BotGraph.ps1 `
  -Question "Which workflows are connected to invoice validation?"
```

## Refresh

```powershell
./.rpa-ai/scripts/Refresh-BotGraph.ps1 -Mode Update
```

## Local processing and network boundary

- Graph extraction and querying process bot source locally on the workstation.
- The wrappers force `--code-only`, disable clustering and query logging, and remove known cloud/model credentials from every Graphify child process.
- `.graphifyignore` excludes documentation, Office files, images, audio, video, evidence, intake, and other semantic-content surfaces.
- Graphify remote backends, hosted services, semantic document enrichment, HTTP/MCP serving, and vendor upload are not permitted by this release.
- Approved package downloads may enter the workstation during installation. Bot source, graph content, prompts, and business data must not leave through Graphify or another third-party library.
