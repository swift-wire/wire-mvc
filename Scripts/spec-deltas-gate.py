#!/usr/bin/env python3
"""Fail when a proposed spec change would not apply cleanly to the specifications.

A change under `openspec/changes/<name>/` carries deltas against `openspec/specs/`: requirements it
ADDs, MODIFIEs, REMOVEs or RENAMEs. `openspec validate --strict` checks each delta's shape but not
whether it fits the specs it will be applied to. Three mistakes pass it:

- a MODIFIED, REMOVED or RENAMED heading that names no existing requirement (validate reports it
  as INFO only; applying the change then refuses);
- an ADDED requirement whose heading already exists (depending on how the change is applied this
  is refused or absorbed into the existing requirement, so it is checked here directly, with a
  message that says to use MODIFIED instead);
- a change with no `proposal.md`, the file that says why and links the proposal and tracking issue.

So this gate checks the last two directly, then applies every active change, in name order, to a
scratch copy with `openspec archive --yes`, and validates the specs that result. The working tree is
never modified. Archived changes under `openspec/changes/archive/` are history and are skipped.
"""

import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path.cwd()
changes_dir = root / "openspec" / "changes"
openspec = shlex.split(os.environ.get("OPENSPEC", "npx -y @fission-ai/openspec@1.13.2"))
env = {**os.environ, "OPENSPEC_TELEMETRY": "0"}

changes = sorted(
    p for p in changes_dir.iterdir() if p.is_dir() and p.name != "archive"
) if changes_dir.is_dir() else []

if not changes:
    print("No active spec changes.")
    sys.exit(0)

requirement = re.compile(r"^### Requirement:\s*(.+?)\s*$", re.M)
section = re.compile(r"^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements\s*$", re.M)
failures = []

for change in changes:
    name = change.name
    if not (change / "proposal.md").is_file():
        failures.append(f"{name}: no proposal.md")
    deltas = sorted(change.glob("specs/*/spec.md"))
    if not deltas:
        failures.append(f"{name}: no spec deltas under specs/<capability>/spec.md")
    for delta in deltas:
        capability = delta.parent.name
        base = root / "openspec" / "specs" / capability / "spec.md"
        existing = set(requirement.findall(base.read_text())) if base.is_file() else set()
        text = delta.read_text()
        marks = list(section.finditer(text))
        for index, mark in enumerate(marks):
            if mark.group(1) != "ADDED":
                continue
            end = marks[index + 1].start() if index + 1 < len(marks) else len(text)
            for title in requirement.findall(text[mark.end():end]):
                if title in existing:
                    failures.append(
                        f"{name}: ADDED requirement '{title}' already exists in {capability}; "
                        "use MODIFIED Requirements"
                    )

with tempfile.TemporaryDirectory() as scratch:
    shutil.copytree(root / "openspec", pathlib.Path(scratch) / "openspec")
    for change in changes:
        applied = subprocess.run(
            openspec + ["archive", change.name, "--yes"],
            cwd=scratch, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        )
        if applied.returncode != 0:
            detail = (applied.stdout + applied.stderr).strip().splitlines()
            failures.append(f"{change.name}: does not apply: " + " | ".join(detail[-3:]))
    # A change that introduces a capability gets OpenSpec's placeholder Purpose ("TBD - created by
    # archiving change …"), which strict validation rejects. Writing the real Purpose is the
    # implementing pull request's job, and the validator on the real tree holds it to that; here, in
    # the scratch copy only, the placeholder is stood in for so the new requirements are still checked.
    for created in (pathlib.Path(scratch) / "openspec" / "specs").glob("*/spec.md"):
        text = created.read_text()
        if "TBD - created by archiving change" in text:
            created.write_text(re.sub(
                r"TBD - created by archiving change.*",
                "Stand-in purpose for scratch validation; the implementing pull request writes the real one.",
                text,
            ))
    result = subprocess.run(
        openspec + ["validate", "--specs", "--strict", "--no-interactive"],
        cwd=scratch, env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        failures.append("specs after applying every change do not validate:\n" + result.stdout)

for failure in failures:
    print(failure)
print(f"\n{len(changes)} active change(s), {len(failures)} problem(s).")
sys.exit(1 if failures else 0)
