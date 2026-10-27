# Platform Support

v0.11.8 records Studio, Robot/runtime, UiPath CLI, project dependency, and locally available UI Automation package evidence where discoverable. Unknown or incompatible release-line evidence is handled conservatively; it is never replaced by a fabricated compatibility claim. Runtime enum reflection requires the relevant package assembly to be locally available, while UiPath-native diagnostics/build require the installed supported `uip` CLI.

## Supported Development pilot

| Component | Supported baseline | Notes |
| --- | --- | --- |
| Operating system | Windows developer workstation | Production machines and resources are out of scope. |
| Permissions | Standard user; no administrator access required for Dev Kit-owned setup | Missing Dev Kit runtimes are installed in the current user's profile. |
| PowerShell | Windows PowerShell 5.1 or PowerShell 7+ | Bot-local and release scripts are regression-tested in both. |
| VS Code | Current organization-approved release | GitHub Copilot Chat and custom-agent support required. |
| GitHub Copilot | Organization-approved account and policy | Copilot is an approved agent service; do not place secrets or unnecessary sensitive data in prompts. |
| UiPath | Approved CLI with `uip rpa` and `uip skills` | Exact current CLI help and installed official skill are authoritative. |
| Graphify | Pinned `graphifyy` version from the payload | Mandatory, bot-local, code-only, no clustering, query logging disabled. |
| Graphify installer | `uv` preferred or `pipx` | Activation installs portable `uv` when neither installer exists. |
| Outlook activities | UiPath Outlook/Mail package plus a usable user Outlook profile | Capability is checked per machine/user; unavailable Outlook does not block independent email validation. |
| UiPath project targets | Windows or Portable | Legacy projects require separate review. |
| UI Target Registry | Project-local JSON; no service/login | Strict/DOM and anchors require the declared UI Automation package; fuzzy, semantic, CV, live validation, and Object Repository routes are used only when local capability evidence supports them. |
| Expressions | Visual Basic default; C# when explicitly selected | New project scaffolding remains XAML by default. |

## Network and data boundary

Data may enter the workstation from approved sources, including official Node.js, GitHub, npm, and Python package endpoints; UiPath feeds; the bot's Azure DevOps repository; GitHub Copilot responses; and approved Development systems.

Bot content must not be sent to Graphify, package vendors, public model APIs, hosted semantic services, or other third-party libraries. The Graphify wrappers:

- run local code-only extraction;
- disable clustering and query logging;
- remove known cloud/model credentials from child processes;
- exclude intake, context, evidence, documents, Office files, media, and generated business outputs through `.graphifyignore`.

Approved GitHub Copilot, the bot's approved Azure DevOps repository, and approved Development applications remain governed enterprise services, not a general exception for arbitrary data egress.

## Per-user tools

Each Windows developer profile may have different executable locations. Activation installs missing portable Node.js/npm and `uv` under `%LOCALAPPDATA%\RpaAiDevKit\tools`, then installs the UiPath CLI and Graphify packages. It resolves existing and newly installed tools, persists verified paths in bot-local ignored `.rpa-ai/local/tool-paths.json`, and invokes those absolute paths directly on future runs.

## Model guidance

Use **GPT-5.6 Luna** with **High** reasoning when available and approved.

- Use a **200K context window** for routine bug fixes and focused changes.
- Use a **1M context window** for new bot development, broad cross-workflow impact, or genuinely complex changes.

This is operating guidance, not hard-coded agent frontmatter. Model labels and context controls may vary by Copilot release and enterprise policy.

## Not supported by v0.11.8

- Production deployment, Production jobs, or Production resource mutation.
- Non-Windows developer workstations as a verified pilot baseline.
- Graphify remote backends, hosted service mode, HTTP/MCP serving, remote semantic enrichment, or vendor upload.
- Unreviewed Marketplace UiPath templates.
- Guessed browser selectors in place of live UiPath capture.
- Treating static selector quality as live target validation, or assuming semantic/CV support without local capability evidence.
- Treating deterministic repository tests as a substitute for a representative Development execution.
