# Per-bot knowledge graph

Graphify is the mandatory graph provider for this Dev Kit. Agents access it through Dev Kit wrappers so its security and lifecycle policy stays centralized.

## Default security posture

The Dev Kit installs a `.graphifyignore` that keeps the initial graph **code/XAML only**. UiPath `.xaml`, JSON and PowerShell can be parsed locally; documentation/media/Office artifacts are excluded because semantic extraction can use a configured model backend.

The wrappers force code-only extraction without clustering, set `GRAPHIFY_QUERY_LOG_DISABLE=1`, and remove known cloud/model credentials for every Graphify call they launch. Package downloads may enter the workstation; bot content must not leave through Graphify.

## Files per bot

```text
graphify-out/
├── graph.json
├── GRAPH_REPORT.md      # when produced by the installed Graphify version/mode
└── ...
```

`graphify-out/` is bot-specific. The central Dev Kit never stores knowledge for all bots in one graph.

## Lifecycle

1. Activate with `Activate-RpaAiDevKit.ps1`; checked imports do this automatically.
2. Verify managed-core integrity and reuse or refresh the graph during activation only when a UiPath project already exists; defer project-less new-bot extraction until stable finalization.
3. Query with `Query-BotGraph.ps1 -Question "..."`.
4. During planning, refresh or validate when required and record the source fingerprint.
5. After final source changes, refresh once when the content fingerprint differs and associate the graph with that final fingerprint.
6. When `AUDIT_MODE` is `LIGHT` or `FULL`, the Auditor consumes the final graph evidence. For `AUDIT_MODE: NONE`, the Coordinator/Developer use it for completion. Auditor PASS alone does not require another refresh; refresh only when relevant source state changes.
7. Treat a failed required refresh as BLOCKED, not as an optional-tool warning.

## Source-of-truth rule

Graphify is a fast map. The UiPath repository is the source of truth. Agents must verify critical relationships in current XAML/config/project files.
