# Benchmark tooling findings

- `New-RpaProject.ps1` reports that neither `init` nor `create-project` exists when its 60-second capability checks time out. In the benchmark preparation, `uip rpa init --help` succeeded with a 90-second timeout in 61.436 seconds. Distinguish timeout from unsupported command before recommending a tool update.
- The prepared UiPath RPA tool 1.203.2 uses Helm targeting `Microsoft.NETCore.App` and `Microsoft.WindowsDesktop.App` 10.0.0. The resolved machine installation has only 8.0.31. Check the actual host runtime configuration against available runtimes during prerequisite verification.
- `uip rpa init` exited 0 with an outer `Result: Success` but `Data.success: false` and a Helm readiness timeout. Generic command telemetry correctly records process completion, but scaffold readiness must also inspect the operation result and generated project files.
- The compatibility helper returns `UNKNOWN` for a new project with Studio 26.0.203.0 and UIA 26.10.2, including when newer-release compatibility evidence is supplied. The official package nuspec explicitly requires Studio 24.10 or higher. Support traceable vendor minimum-version evidence without silently treating unknown environments as compatible.
- Installing isolated Microsoft.NETCore.App and Microsoft.WindowsDesktop.App 10.0.13 resolved the Helm startup failure: the same official initialization then succeeded semantically in 8.638 seconds. The system installation remained separate.

Evidence: `.ai/evidence/ui-selector-benchmark-recovery.json`. These findings are proposals; central implementation and immutable benchmark payloads were not changed during recovery.

## Follow-up findings from attempt 03

- The approved argument-transport repair subsequently changed the central helper only; the two frozen payloads remained unchanged and used the same hash-identified external harness. The patch and regression tests passed independent audit. See `.ai/evidence/ui-selector-argument-repair-result.json`.
- Both GPT-6 Luna attempts exhausted their new-bot budgets before authoring workflow behavior. Baseline live previews passed for all four links; candidate capture and registry resolution completed for all four, with `FRAGILE` selector quality. Neither generated the required output. No successful runtime improvement is established.
- Recorded UIA subprocess durations were 47.015 seconds for baseline and 47.356 seconds for candidate, versus roughly 25 minutes to each blocker. Investigate the elapsed time outside recorded subprocesses before optimizing selector helper milliseconds; this summary does not isolate model, tooling, reading or governance latency.
- Candidate context preparation reported `NEW_WORKFLOW`, `GRAPH_MISSING` and `GRAPH_REFRESH_STATE_MISSING` while the approved new-bot lifecycle intentionally deferred Graphify until stable finalization. Investigate this apparent lifecycle mismatch with a targeted regression before changing gates; do not weaken final graph requirements.
- The baseline installed an isolated .NET 8 compiler SDK during its timed run. Future paired measurements must verify the compiler as well as the headless-host runtime before either measurement, and disclose shared-cache/order effects.
- Benchmark reports should keep fingerprint inventories in referenced artifacts, not embed them in summary JSON. The baseline result was 88,870 bytes despite requiring only compact fingerprints and evidence references.
- Report actual receipt-to-result timing separately from configured budget thresholds. Baseline reported a 1500-second threshold but persisted its result after 1664.186 seconds. Both times are failure evidence, not accepted completion runtimes.
