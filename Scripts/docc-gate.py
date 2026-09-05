#!/usr/bin/env python3
"""Fail on DocC diagnostics that belong to this package.

`--warnings-as-errors` cannot be used directly here. `WireMVC` re-exports
`AsyncStreaming` through a `public import`, and on Linux the symbol graph carries
those re-exported types into `/WireMVC/…` — so DocC reports unresolved links in
*their* doc comments (`DuplexAsyncChannel`, `CallerAsyncWriter`, `UniqueArray`),
which this package cannot fix and which do not appear on macOS at all.

So the build runs without the flag and its structured diagnostics are filtered
here: anything whose source is a file in this repository, and not a dependency
checkout under `.build`, fails the job. A broken link in this package's own doc
comments or catalog is caught exactly as before; a dependency's is not this
package's to answer for.
"""

import json
import os
import pathlib
import sys

diagnostics_file = sys.argv[1]
root = pathlib.Path(os.getcwd()).resolve()

diagnostics = json.load(open(diagnostics_file)).get("diagnostics", [])

own = []
for diagnostic in diagnostics:
    source = diagnostic.get("source")
    if not source:
        # No source location — nothing ties it to a file in this package.
        continue
    path = pathlib.Path(source.removeprefix("file://")).resolve()
    if root in path.parents and ".build" not in path.parts:
        own.append((path.relative_to(root), diagnostic))

for path, diagnostic in own:
    print(f"{path}: {diagnostic.get('severity')}: {diagnostic.get('summary')}")

print(f"\n{len(own)} diagnostic(s) in this package's own sources ({len(diagnostics)} total).")
sys.exit(1 if own else 0)
