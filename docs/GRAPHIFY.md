# Graphify Operating Guide

## Why it is included

Graphify gives the agents a per-bot relationship map so they can discover impact without repeatedly opening large portions of the repository.

## Pinned version

The current Dev Kit pins Graphify in `graph/config/graphify-version.json`. Do not silently upgrade it on developer machines. Change the pin through normal review, test it against pilot bots, then roll it forward.

## On-demand activation

Graphify is not installed or refreshed during ordinary bot activation. Use the deterministic Project Mapper for routine work. To explicitly install/refresh the pinned local-only graph when dependency analysis requires it:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1 -EnableGraphify
```

When requested, activation verifies managed files, installs or checks pinned Graphify, and refreshes an existing project's graph. Project-less new bots defer extraction. Without `-EnableGraphify`, missing graph artifacts are expected and are not errors.

Graphify git hooks and VS Code integration are disabled in v0.11.0 because they can invoke Graphify outside the hardened wrappers. The Coordinator starts with the Project Mapper; Graphify is invoked only for material gaps or ambiguous relationships. When Graphify was used, the Developer refreshes it after relevant final source changes and the Auditor may reuse the same snapshot. No graph is required for a successful ordinary low-risk task.

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
