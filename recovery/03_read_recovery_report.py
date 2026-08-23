#!/usr/bin/env python3
"""Summarize a hermes `sessions recover` .recovery.json report.

Usage:
    python3 03_read_recovery_report.py /mnt/volumes/data/recovered-state.db.recovery.json
"""

from __future__ import annotations

import json
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} <report.recovery.json>")

    with open(sys.argv[1]) as fh:
        r = json.load(fh)

    print("=== copy status per table ===")
    for table, c in r.get("copy", {}).items():
        fields = {
            k: c.get(k)
            for k in (
                "status",
                "copied_rows",
                "source_rows",
                "skipped_rowid_span",
                "query_limit_reached",
            )
        }
        print(f"  {table:26s} {fields}")

    print()
    print("=== orphan_cleanup ===")
    print(json.dumps(r.get("orphan_cleanup"), indent=2))

    v = r.get("verification", {})
    print()
    print("=== verification ===")
    print(
        "healthy:",
        v.get("healthy"),
        "complete:",
        v.get("complete"),
        "loss_detected:",
        v.get("loss_detected"),
    )
    print("table_counts:", v.get("table_counts"))
    print("warnings:")
    for w in v.get("warnings", []):
        print("  -", w)
    print("errors:")
    for e in v.get("errors", []):
        print("  -", e)

    print()
    print("=== top-level ===")
    for key in (
        "operation",
        "mode",
        "best_effort",
        "complete",
        "partial",
        "verified",
        "installed",
    ):
        if key in r:
            print(f"  {key}: {r[key]}")


if __name__ == "__main__":
    main()
