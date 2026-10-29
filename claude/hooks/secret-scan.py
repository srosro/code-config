#!/usr/bin/env python3
"""Canonical secret-shape scanner for code-config.

`--scan-file <path>` exits 1 if the file matches a known token shape (WITHOUT
echoing the match — printing it would violate CLAUDE.md § Secrets), 0 if clean,
1 (fail-closed) if unreadable. Patterns come from `_secret_patterns.py`, shared
with transcript mining; the /cleanup skill gates its direct-to-main commit here.
"""
from __future__ import annotations
import sys
from pathlib import Path

from _secret_patterns import contains_secret


def _scan_file_for_secrets(path: str) -> int:
    """Gate a file about to be committed to a no-review path (the /cleanup
    findings file) against the canonical secret-shape list
    for code-config. Exit 1 on a match WITHOUT echoing the matched text
    (printing the secret would itself violate CLAUDE.md § Secrets); 0 when
    clean; fail closed (1) if unreadable.
    """
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        print("FATAL: secret scan could not read the file — refusing to commit.", file=sys.stderr)
        return 1
    if contains_secret(text):
        print("FATAL: file matches a known secret shape — sanitize (use …*** below 8 characters, otherwise keep only last-3) + rotate the credential, then re-run. NOT committing.", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    if "--scan-file" in sys.argv:
        idx = sys.argv.index("--scan-file")
        if idx + 1 >= len(sys.argv):
            print("FATAL: --scan-file requires a path", file=sys.stderr)
            return 1
        return _scan_file_for_secrets(sys.argv[idx + 1])
    print("usage: secret-scan.py --scan-file <path>", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
