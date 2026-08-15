#!/usr/bin/env python3
"""Sample messages spread across a recovered db's id space for a content sanity check.

Row counts matching between two recovery methods proves *how many* rows came
back, not that the text inside them is intact. This pulls evenly-spaced
samples (start / quartiles / end of the id range, plus the placeholder
"[recovered ...]" / "[best-effort recovered ...]" sessions) so you can eyeball
whether the content reads as real conversation text or as garbled/truncated
fragments.

Usage:
    python3 06_spot_check_messages.py /mnt/volumes/data/recovered-state-v2.db [--per-bucket 3]
"""

from __future__ import annotations

import argparse
import sqlite3


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("db_path")
    parser.add_argument("--per-bucket", type=int, default=3)
    args = parser.parse_args()

    conn = sqlite3.connect(f"file:{args.db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    ids = [r[0] for r in conn.execute("SELECT id FROM messages ORDER BY id")]
    total = len(ids)
    print(f"total messages: {total}\n")
    if total == 0:
        return

    buckets = {
        "start": ids[: args.per_bucket],
        "q1": ids[total // 4 : total // 4 + args.per_bucket],
        "mid": ids[total // 2 : total // 2 + args.per_bucket],
        "q3": ids[3 * total // 4 : 3 * total // 4 + args.per_bucket],
        "end": ids[-args.per_bucket :],
    }

    for label, bucket_ids in buckets.items():
        print(f"=== {label} ===")
        for mid in bucket_ids:
            row = conn.execute(
                "SELECT id, session_id, role, timestamp, "
                "substr(content, 1, 200) AS preview, length(content) AS full_len "
                "FROM messages WHERE id = ?",
                (mid,),
            ).fetchone()
            if row is None:
                continue
            print(
                f"  id={row['id']} session={row['session_id']} role={row['role']} "
                f"ts={row['timestamp']} len={row['full_len']}"
            )
            print(f"    {row['preview']!r}")
        print()

    print("=== reconstructed placeholder sessions (metadata lost, text retained) ===")
    for row in conn.execute(
        "SELECT id, title, message_count FROM sessions WHERE source = 'recovered' ORDER BY id"
    ):
        print(f"  {row['id']}  msgs={row['message_count']}  {row['title']}")
        sample = conn.execute(
            "SELECT substr(content, 1, 150) AS preview FROM messages "
            "WHERE session_id = ? ORDER BY id LIMIT 1",
            (row["id"],),
        ).fetchone()
        if sample:
            print(f"    first message preview: {sample['preview']!r}")

    conn.close()


if __name__ == "__main__":
    main()
