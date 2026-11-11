#!/usr/bin/env python3
"""Keep the feature matrix's stable identifiers unique."""
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
seen = {}
definitions = False
for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
    if line.startswith("| ID |"):
        definitions = True
    elif not line.startswith("|"):
        definitions = False
    if not definitions:
        continue  # Follow-up tables cite existing IDs; they do not define them.
    match = re.match(r"\|\s*([A-Z][A-Z0-9]*-\d+)\s*\|", line)
    if not match:
        continue
    feature_id = match[1]
    if feature_id in seen:
        raise SystemExit(f"{path}:{line_number}: duplicate {feature_id}; first at {seen[feature_id]}")
    seen[feature_id] = line_number
if not seen:
    raise SystemExit("No feature identifiers found")
print(f"Verified {len(seen)} unique feature identifiers")
