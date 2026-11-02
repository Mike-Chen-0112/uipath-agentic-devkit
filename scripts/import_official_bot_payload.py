#!/usr/bin/env python3
"""Import an OFFICIAL DevKit bot ZIP back into the central source repository.

Usage:
  python scripts/import_official_bot_payload.py /path/to/rpa-ai-devkit-bot-0.12.2.zip

This maps payload destinations to central SOURCE paths, verifies every file's
SHA-256 and does not delete central-only scripts, tests or build infrastructure.
Review the diff and run regression tests before pushing.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE_MANIFEST = ROOT / "distribution/payload-manifest.json"
HASH_MANIFEST = ROOT / "MANIFEST.sha256"
NEW_CLI_SOURCE = "scripts/UiPathCliContract.psm1"
NEW_CLI_DEST = ".rpa-ai/scripts/UiPathCliContract.psm1"


def safe_repo_file(path: str) -> Path:
    candidate = (ROOT / path).resolve()
    if not candidate.is_relative_to(ROOT) or candidate == ROOT:
        raise ValueError(f"Path outside central source repository: {path}")
    return candidate


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip_file", type=Path)
    args = parser.parse_args()
    current_manifest = json.loads(SOURCE_MANIFEST.read_text(encoding="utf-8"))
    entries = list(current_manifest["files"])
    by_destination = {x["destination"]: x for x in entries}
    if NEW_CLI_DEST not in by_destination:
        new_entry = {"source": NEW_CLI_SOURCE, "destination": NEW_CLI_DEST, "ownership": "managed"}
        pos = next((i for i, x in enumerate(entries) if x["destination"] == ".rpa-ai/scripts/Invoke-UiPathUiAutomation.ps1"), len(entries) - 1)
        entries.insert(pos + 1, new_entry)
        by_destination[NEW_CLI_DEST] = new_entry

    changed: list[str] = []
    with zipfile.ZipFile(args.zip_file) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP CRC verification failed")
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError("Duplicate ZIP filenames")
        payload = json.loads(archive.read(".rpa-ai/kit-manifest.json"))
        if payload.get("kitVersion") != "0.12.2":
            raise ValueError(f"Unexpected ZIP version: {payload.get('kitVersion')}")
        supplied = payload["files"]
        if len(supplied) != 97 or len(entries) != 97:
            raise ValueError(f"Unexpected file count: ZIP={len(supplied)}, source={len(entries)}")
        if set(x["path"] for x in supplied) != set(by_destination):
            raise ValueError("ZIP manifest does not match the central payload path contract")

        verified: list[tuple[str, bytes]] = []
        for record in supplied:
            destination = record["path"]
            content = archive.read(destination)
            actual = hashlib.sha256(content).hexdigest()
            if actual.lower() != record["sha256"].lower():
                raise ValueError(f"Payload SHA-256 mismatch: {destination}")
            source_path = by_destination[destination]["source"]
            safe_repo_file(source_path)
            verified.append((source_path, content))

        # All 97 checks pass before modifying ANY central source file.
        for source_path, content in verified:
            location = safe_repo_file(source_path)
            if location.exists() and location.read_bytes() == content:
                continue
            location.parent.mkdir(parents=True, exist_ok=True)
            location.write_bytes(content)
            changed.append(source_path)

    if current_manifest["files"] != entries:
        current_manifest["files"] = entries
        SOURCE_MANIFEST.write_text(json.dumps(current_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        changed.append("distribution/payload-manifest.json")

    # Update only touched source entries, preserving the remaining manifest.
    lines = HASH_MANIFEST.read_text(encoding="utf-8").splitlines()
    indexed = {line.split("  ./", 1)[1]: i for i, line in enumerate(lines) if "  ./" in line}
    for path in changed:
        digest = hashlib.sha256(safe_repo_file(path).read_bytes()).hexdigest()
        entry = f"{digest}  ./{path}"
        if path in indexed:
            lines[indexed[path]] = entry
        else:
            lines.append(entry)
    HASH_MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"Verified all 97 official v0.12.2 payload files; updated {len(changed)} central source/manifest files:")
    for path in changed:
        print(f"  {path}")
    print("NEXT: review git diff, run Windows tests, then git commit and push develop.")


if __name__ == "__main__":
    main()
