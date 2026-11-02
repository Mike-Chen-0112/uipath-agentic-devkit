# Bot Architecture

## Entry point

- Main workflow:

## Major workflow groups

| Area | Workflow(s) | Responsibility |
|---|---|---|
| | | |

## REFramework mapping (if applicable)

- Init:
- Get Transaction Data:
- Process Transaction:
- Set Transaction Status:
- End Process:

## Known architectural constraints

- 

## Discovery and handoff

- Current XAML/project/config source is authoritative. Use the deterministic UiPath Project Mapper first and pass current fingerprints, the compact map, Impact Set, and validation evidence between roles; handoff alone does not require rediscovery.
- Graphify is optional and on-demand for unresolved material relationships, ambiguous cross-workflow impact, or approved graph analysis. Record `GRAPH_STATE: NOT_REQUIRED` when unused; any requested graph stays code/XAML local-only and must be current for graph-dependent analysis.
- Use installed official UiPath Skills, package guides, and current CLI help first. Inventory the official Object Repository before UI target discovery; inventory is not live capture proof. Preserve legacy Registry/inline targets without creating a parallel registry for new targets.
- Development-only execution, security, approval, applicable dependency/build/test/UI-capture/output gates, and risk-based audit routing remain required.
