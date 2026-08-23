#!/usr/bin/env python3
"""Row-level diff between two independently recovered candidate databases.

Matching COUNT(*) between two recovery methods doesn't mean they recovered
the *same* rows. This reports, per table, which primary keys are in A only,
B only, or both - so you can build a union (best-of-both) candidate instead
of picking one and losing whatever only the other one found.

Usage:
    python3 07_diff_recovered_dbs.py A.db B.db
"""

from __future__ import annotations

import argparse
import sqlite3

TABLE_KEYS = {
    "sessions": "id",
    "messages": "id",
    "session_model_usage": "session_id, model",
    "system_prompts": "hash",
    "gateway_routing": "scope, session_key",
    "async_delegations": "delegation_id",
}


def ids(conn: sqlite3.Connection, table: str, key: str) -> set[tuple]:
    try:
        return {
            row if isinstance(row, tuple) else (row,)
            for row in conn.execute(f"SELECT {key} FROM {table}").fetchall()
        }
    except sqlite3.DatabaseError as exc:
        print(f"  ({table}: {exc})")
        return set()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("db_a")
    parser.add_argument("db_b")
    args = parser.parse_args()

    a = sqlite3.connect(f"file:{args.db_a}?mode=ro", uri=True)
    b = sqlite3.connect(f"file:{args.db_b}?mode=ro", uri=True)

    print(f"A = {args.db_a}")
    print(f"B = {args.db_b}\n")

    for table, key in TABLE_KEYS.items():
        a_ids = ids(a, table, key)
        b_ids = ids(b, table, key)
        only_a = a_ids - b_ids
        only_b = b_ids - a_ids
        both = a_ids & b_ids
        print(
            f"{table}: A={len(a_ids)} B={len(b_ids)} both={len(both)} only_A={len(only_a)} only_B={len(only_b)}"
        )
        if only_a:
            sample = list(only_a)[:5]
            print(f"    sample only_A: {sample}")
        if only_b:
            sample = list(only_b)[:5]
            print(f"    sample only_B: {sample}")

    a.close()
    b.close()


if __name__ == "__main__":
    main()
