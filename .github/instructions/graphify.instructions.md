---
description: Safe use of the per-bot Graphify knowledge graph.
applyTo: "**"
---
# Graphify knowledge-graph rules

- The graph is a navigation/impact-analysis layer. Current repository source always wins if graph and source disagree.
- Graphify activation is mandatory for Dev Kit bots. The Coordinator verifies managed-file integrity and, for an existing bot, reuses or refreshes the bot-local graph once before planning; new-bot work defers graph discovery until stable finalization. Downstream agents consume that evidence and do not repeat successful preflight.
- Use `./.rpa-ai/scripts/Query-BotGraph.ps1` for agent graph queries so query logging is explicitly disabled.
- Default graph mode is **code/XAML local-only**. The installed `.graphifyignore` excludes documentation, Office files, images, audio/video and other artifacts that can require semantic model calls.
- Do not bypass or modify the managed `.graphifyignore`/`.graphifyrc`, enable a remote Graphify backend, or install Graphify hooks/integrations. v0.11.0 permits Graphify only through the hardened Dev Kit wrappers.
- Verify critical graph findings against current XAML/project/config files before editing or approving.
- Record fingerprint schema version, executable source fingerprint, graph configuration fingerprint, timestamp, Graphify version, and whether the result was `PASS` or `REUSED`. Refresh after final source or graph-configuration changes only when the relevant fingerprint differs or the prior graph is stale/incomplete. Documentation/evidence-only changes do not invalidate executable graph/build evidence. When AUDIT_MODE is LIGHT or FULL, the Auditor consumes that final snapshot; do not refresh again after Auditor PASS when fingerprints are unchanged. A required refresh failure blocks task completion.
- A successful Auditor PASS does not itself require a Graphify refresh. For AUDIT_MODE NONE, the Coordinator/Developer consume the final snapshot. Refresh only when the relevant source state changed after the graph snapshot.
- Rerun managed-file integrity only when managed paths may have changed, repository state changed, evidence is stale, or suspicious modifications are detected. Record the reason for any rerun.
- Managed-file integrity validation is state-based, not agent-based. Agent handoff alone does not invalidate existing trustworthy integrity evidence.
- Do not treat inferred/ambiguous graph edges as confirmed business logic without source verification.
