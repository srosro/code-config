#!/usr/bin/env bash
# Guard: every ranked corpus file follows the canonical nudgeable shape.
#   INV-1  No numbered ##/### section headers. A sequence is a numbered LIST
#          inside a section, never the header itself — so every section is a
#          uniform, nudgeable directive-section (see CLEANUP_RANKING_MODEL.md).
#   INV-2  The first heading in the file is an H1 `# Title` (a consistent title
#          before any ## section).
#   INV-3  Every Claude and repo-owned Codex skill's first H2 is a 3–7-entry
#          Priority index whose pointers resolve to unique H2s; only its first
#          pointer may be pinned.
# Ranked corpus = claude/*.md MINUS the three the cleanup skill excludes
# (COMMENT_REVIEW_MISTAKES.md is auto-tuned, CLEANUP_RANKING_MODEL.md is the
# model doc, PROPOSALS.md is the Track-B staging doc). Keep this exclusion list
# in sync with claude/skills/cleanup/SKILL.md § Step 2.
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/assert.sh
source tests/assert.sh

EXCLUDE=(COMMENT_REVIEW_MISTAKES.md CLEANUP_RANKING_MODEL.md PROPOSALS.md)
is_excluded() {
  local b; b=$(basename "$1")
  for e in "${EXCLUDE[@]}"; do [ "$b" = "$e" ] && return 0; done
  return 1
}

for f in claude/*.md; do
  is_excluded "$f" && continue

  # INV-1: no numbered ##/### headers
  numbered=$(grep -nE '^#{2,3} +[0-9]+\.' "$f" || true)
  assert_eq "" "$numbered" "$f: numbered section header(s) — a sequence belongs in a numbered list INSIDE a section, not the header"

  # INV-2: first heading is an H1
  first_heading=$(grep -m1 -E '^#{1,6} ' "$f" || true)
  case "$first_heading" in
    '# '*) ok=1 ;;
    *)     ok=0 ;;
  esac
  assert_eq "1" "$ok" "$f: first heading must be an H1 '# Title' (got: ${first_heading:-<none>})"
done

skill_errors=$(python3 - <<'PY'
from pathlib import Path
import re

errors = []
pointer = re.compile(r"^- `§ (.*)`(?: \*\(pinned\)\*)?$")
skill_paths = [
    *Path("claude/skills").glob("*/SKILL.md"),
    *Path("codex/skills").glob("*/SKILL.md"),
]
for path in sorted(skill_paths):
    lines = path.read_text().splitlines()
    h2s = [line[3:] for line in lines if line.startswith("## ")]
    if not h2s or h2s[0] != "Priority":
        errors.append(f"{path}: first H2 must be ## Priority")
        continue
    start = lines.index("## Priority") + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    rows = [line for line in lines[start:end] if line.strip()]
    if not 3 <= len(rows) <= 7:
        errors.append(f"{path}: Priority needs 3–7 pointer rows (got {len(rows)})")
    targets = []
    for index, row in enumerate(rows):
        match = pointer.fullmatch(row)
        if not match:
            errors.append(f"{path}: malformed Priority pointer: {row}")
            continue
        target = match.group(1)
        targets.append(target)
        if "*(pinned)*" in row and index != 0:
            errors.append(f"{path}: only the first Priority pointer may be pinned")
        if h2s.count(target) != 1:
            errors.append(f"{path}: Priority target must name one exact H2: {target}")
    if len(targets) != len(set(targets)):
        errors.append(f"{path}: duplicate Priority pointer")
print("\n".join(errors))
PY
)
assert_eq "" "$skill_errors" "skills: Priority indexes are bounded and point to exact unique H2s"

assert_summary
