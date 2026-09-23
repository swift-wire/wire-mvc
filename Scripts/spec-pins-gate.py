#!/usr/bin/env python3
"""Fail when a specification pins a requirement to something that does not exist.

Every requirement under `openspec/specs/` ends with a `Pinned by:` line naming the test, golden
file, fixture or CI job that measures it. A spec is only as good as those pins: a renamed test or a
moved fixture leaves the requirement claiming a measurement nobody takes, and nothing else notices.

So this checks, for every `Pinned by:` line, that each backticked repository path exists (a
directory, a file, or a glob that matches something), and that each backticked identifier in the
parentheses after a path occurs in that file. URLs into other repositories are not checked here.

`Pinned by: nothing yet.` is a deliberate marker and passes. The count is printed so a growing
number of unpinned requirements is visible in the job log.
"""

import glob
import pathlib
import re
import sys

root = pathlib.Path.cwd()
specs = sorted(root.glob("openspec/specs/*/spec.md"))

token = re.compile(r"`([^`]+)`")
name_list = r"`[^`\s()]+`(?:\s*,\s*`[^`\s()]+`)*"
pin = re.compile(r"`([^`]+)`(?:\s*\((" + name_list + r")\))?")

failures = []
pinned = 0
unpinned = 0


def looks_like_path(text):
    return "/" in text and not text.startswith(("http://", "https://")) and " " not in text


def resolve(text):
    path = root / text.rstrip("/")
    if path.exists():
        return [path]
    return [pathlib.Path(p) for p in glob.glob(str(root / text), recursive=True)]


for spec in specs:
    relative = spec.relative_to(root)
    for number, line in enumerate(spec.read_text().splitlines(), start=1):
        if not line.startswith("Pinned by:"):
            continue
        if "nothing yet" in line:
            unpinned += 1
        body = line[len("Pinned by:"):]
        if token.search(body):
            pinned += 1
        # A path is a backticked token containing a slash. When it is followed directly by a
        # parenthesised list made only of backticked names (test functions,
        # golden case names, CI job ids), each name must occur in that file.
        # A parenthetical that is prose ("built by the `X` job") is not a name list and is skipped.
        for match in pin.finditer(body):
            text, names = match.group(1), match.group(2)
            if not looks_like_path(text):
                continue
            found = resolve(text)
            if not found:
                failures.append(f"{relative}:{number}: no such path `{text}`")
                continue
            if not names:
                continue
            files = [p for p in found if p.is_file()]
            for name in token.findall(names):
                if looks_like_path(name) and re.search(r"\.[A-Za-z]+$", name):
                    # A file named alongside the first, not a name inside it.
                    if not resolve(name):
                        failures.append(f"{relative}:{number}: no such path `{name}`")
                    continue
                if "/" not in name:
                    name = name.split(".")[-1]
                if files and not any(name in p.read_text(errors="ignore") for p in files):
                    shown = files[0].relative_to(root)
                    failures.append(f"{relative}:{number}: `{name}` does not occur in {shown}")

for failure in failures:
    print(failure)

print(
    f"\n{len(specs)} spec(s), {pinned} pinned requirement line(s), "
    f"{unpinned} marked 'nothing yet', {len(failures)} broken pin(s)."
)
sys.exit(1 if failures else 0)
