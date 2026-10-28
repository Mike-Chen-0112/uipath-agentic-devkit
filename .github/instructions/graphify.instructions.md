---
description: Safe use of the per-bot Graphify knowledge graph.
applyTo: "**"
---
# Graphify knowledge-graph rules

- The graph is a navigation/impact-analysis layer. Current repository source always wins if graph and source disagree.
- Graphify is optional and on-demand. The Coordinator uses the deterministic UiPath Project Mapper first. Only install/refresh a graph when the Mapper cannot resolve a material relationship, when cross-workflow impact remains ambiguous, or when an explicit graph analysis is approved. Use `Activate-RpaAiDevKit.ps1 -EnableGraphify` to enable it. An absent graph alone is not a blocker; downstream agents must not require graph evidence unless a graph was explicitly requested.
- Use `./.rpa-ai/scripts/Query-BotGraph.ps1` for agent graph queries so query logging is explicitly disabled.
- Default graph mode is **code/XAML local-only**. The installed `.graphifyignore` excludes documentation, Office files, images, audio/video and other artifacts that can require semantic model calls.
- Do not bypass or modify the managed `.graphifyignore`/`.graphifyrc`, enable a remote Graphify backend, or install Graphify hooks/integrations. v0.11.0 permits Graphify only through the hardened Dev Kit wrappers.
- Verify critical graph findings against current XAML/project/config files before editing or approving.
- Record fingerprint schema version, executable source fingerprint, graph configuration fingerprint, timestamp, Graphify version, and whether the result was `PASS` or `REUSED`. Refresh after final source or graph-configuration changes only when the relevant fingerprint differs or the prior graph is stale/incomplete. Documentation/evidence-only changes do not invalidate executable graph/build evidence. When AUDIT_MODE is LIGHT or FULL, the Auditor consumes that final snapshot; do not refresh again after Auditor PASS when fingerprints are unchanged. A requested graph refresh failure must be diagnosed or recorded as a blocker for graph-dependent analysis; it must not be misreported as a successful graph.
- A successful Auditor PASS does not itself require a Graphify refresh. For AUDIT_MODE NONE, the Coordinator/Developer consume the final snapshot. Refresh only when the relevant source state changed after the graph snapshot.
- Rerun managed-file integrity only when managed paths may have changed, repository state changed, evidence is stale, or suspicious modifications are detected. Record the reason for any rerun.
- Managed-file integrity validation is state-based, not agent-based. Agent handoff alone does not invalidate existing trustworthy integrity evidence.
- Do not treat inferred/ambiguous graph edges as confirmed business logic without source verification.
