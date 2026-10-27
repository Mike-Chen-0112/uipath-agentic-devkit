# Technology References

<!-- markdownlint-disable MD034 -->

Verified for Dev Kit v0.11.0 on 01 September 2026.

## UiPath

- UiPath CLI Skills concept and agent support:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/concepts-skills
- `uip skills` command reference:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-skills
- UiPath for Coding Agents overview:
  https://docs.uipath.com/coding-agents/standalone/latest/user-guide/overview
- UiPath Agent Skills repository / current `uipath-rpa` skill:
  https://github.com/UiPath/skills
  https://github.com/UiPath/skills/blob/main/skills/uipath-rpa/SKILL.md
- `uip rpa` command group and Studio-backed coding-agent operations:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa
- Current official skill uses `uip rpa init` and `uip rpa templates search` for project scaffolding and template discovery. The installed skill and local `--help` output are authoritative:
  https://github.com/UiPath/skills/blob/main/skills/uipath-rpa/references/environment-setup.md
- Public CLI compatibility reference for `uip rpa create-project`:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-create-project
- Public CLI compatibility reference for `uip rpa search-templates`:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-search-templates
- Public compatibility reference for `uip rpa install-or-update-packages`:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-install-or-update-packages
- `uip rpa restore` is documented under the `uip rpa` command group as restoring dependencies already declared in `project.json`.
- `uip rpa uia` dynamic UI Automation command group:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-uia
- `uip rpa find-activities`:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-find-activities
- `uip rpa indicate-application`:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-indicate-application
- `uip rpa indicate-element`:
  https://docs.uipath.com/uipath-cli/standalone/latest/user-guide/uip-rpa-indicate-element
- UI Automation v26.10 release notes: coding-agent UI interaction, target configuration, semantic selectors and selector intelligence:
  https://docs.uipath.com/activities/other/latest/ui-automation/release-notes-uipath-uiautomation-activities-v26-10
- Selector concepts and stable-attribute guidance:
  https://docs.uipath.com/activities/other/latest/ui-automation/about-selectors
- Advanced target/descriptor configuration:
  https://docs.uipath.com/activities/other/latest/ui-automation/advanced-descriptor-configuration

Dev Kit dependency assumptions at this version:

- Portable Node.js bootstrap resolves the current Windows LTS archive from the official distribution index and verifies it against the release `SHASUMS256.txt` before extraction:
  https://nodejs.org/dist/index.json
- Portable `uv` bootstrap resolves the latest official release assets and verifies the archive against its published `.sha256` asset before extraction:
  https://github.com/astral-sh/uv/releases
- Dependency setup is an internal Dev Kit lifecycle gate: derive/restore/install/verify before authoring.
- Current official skills may use `uip rpa packages install`, while the public compatibility reference documents `uip rpa install-or-update-packages`. The installed skill and local `--help` output are authoritative. Use `uip rpa restore` for declared dependencies.
- New package dependencies are project changes and remain subject to normal audit/validation; pre-development installation does not exempt them.
- Dev Kit prerequisites are installed through verified user-profile downloads. Machine-wide installation is not required.

Dev Kit browser automation assumptions at this version:

- Current UiPath `uipath-rpa` skill describes UI automation as a first-class desktop/browser capability and includes a capture-first fast path for UI-heavy tasks.
- For UiPath workflows, target capture/configuration is performed through UiPath UI Automation/Object Repository tooling before authoring the UI activity logic.
- The installed UI Automation package guide and current CLI surface are authoritative; do not invent fixed command syntax from memory.
- Python browser tooling may supplement diagnostics, but for a UiPath deliverable it does not replace UiPath target capture. It is a full capture/implementation route only when the final browser implementation is intentionally Python.
- Generated-scaffold validation exemption is an internal Dev Kit policy, not a UiPath product guarantee.

## GitHub / VS Code

- VS Code custom agents:
  https://code.visualstudio.com/docs/agent-customization/custom-agents
- VS Code Agent Skills:
  https://code.visualstudio.com/docs/agent-customization/agent-skills

## Graphify

- Graphify repository / current README:
  https://github.com/Graphify-Labs/graphify
- Graphify releases:
  https://github.com/Graphify-Labs/graphify/releases

Dev Kit Graphify assumptions at this version:

- PyPI package: `graphifyy`; CLI: `graphify`.
- Version pinned by this kit: see `graph/config/graphify-version.json`.
- Code including `.xaml` is supported by local AST extraction.
- Non-code semantic extraction can use an assistant/model backend; the default Dev Kit excludes those files.
- Graphify states no telemetry/analytics.
- Query logging is explicitly forced off by Dev Kit wrappers.
- `graphify-out/` is per bot and can be shared/committed subject to company source-control policy.
- Graphify git hooks and VS Code integration are disabled in v0.11.0 so runtime calls cannot bypass the hardened wrappers. Graphify refresh behavior is unchanged in v0.11.0.

<!-- markdownlint-enable MD034 -->
