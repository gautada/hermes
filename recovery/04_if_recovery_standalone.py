"""Standalone page-level lost-and-found salvage for a damaged Hermes state.db.

Inlines hermes_cli.session_lost_and_found (absent from this deployment's
installed package) verbatim from the hermes-agent main branch, so it runs
against whatever hermes_state / hermes_cli.session_recovery is actually
installed here without needing that module on disk.
"""

from __future__ import annotations

import re
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from typing import Any

# ── from hermes_cli/session_lost_and_found.py (verbatim) ──────────────────

SESSION_ID_PATTERN = re.compile(r"^\d{8}_\d{6}_")

MESSAGE_ROLES = frozenset({"user", "assistant", "tool", "system"})

KNOWN_SOURCES = frozenset(
    {
        "cli",
        "telegram",
        "discord",
        "slack",
        "whatsapp",
        "signal",
        "matrix",
        "irc",
        "email",
        "x",
        "twitter",
        "api",
        "gateway",
        "web",
        "dashboard",
        "tool",
        "subagent",
        "cron",
        "recovered",
        "imported",
        "acp",
    }
)

SESSIONS_LAYOUT_NFIELDS = frozenset({54, 52})
SESSIONS_LEGACY_MINIMAL_NFIELD = 14
SESSION_MODEL_USAGE_NFIELD = 18

_EPOCH_LOW = 1_000_000_000.0  # 2001
_EPOCH_HIGH = 4_000_000_000.0  # 2096

SQLITE3_CLI_GUIDANCE = (
    "A last-resort page-level salvage is available when a `.recover`-capable "
    "`sqlite3` command-line shell is installed: its `.recover` command can "
    "rebuild rows into lost_and_found tables even when the table schemas are "
    "unreadable (this is a CLI-only feature, not part of Python's sqlite3 "
    "module, and some distro builds lack it - the shell must include the "
    "sqlite_dbpage extension, as the official builds from sqlite.org do). "
    "Install such a sqlite3 CLI (e.g. `brew install sqlite` or the "
    "precompiled sqlite-tools from sqlite.org) so it is on PATH, then re-run "
    "with --allow-partial."
)


class LostAndFoundError(RuntimeError):
    """Raised when the CLI .recover pass cannot produce a usable database."""


def find_sqlite3_cli() -> str | None:
    binary = shutil.which("sqlite3")
    if binary is None:
        return None
    return binary if _cli_supports_recover(binary) else None


def _cli_supports_recover(binary: str) -> bool:
    scratch_dir = tempfile.mkdtemp(prefix="hermes-recover-probe-")
    scratch = Path(scratch_dir) / "probe.db"
    try:
        conn = sqlite3.connect(str(scratch))
        try:
            conn.execute("CREATE TABLE t (x)")
            conn.execute("INSERT INTO t VALUES (1)")
            conn.commit()
        finally:
            conn.close()
        probe = subprocess.run(
            [binary, "-readonly", str(scratch), ".recover"],
            capture_output=True,
            timeout=30,
        )
        if probe.returncode != 0:
            return False
        return b"sqlite_dbpage" not in probe.stderr
    except (OSError, subprocess.SubprocessError, sqlite3.Error):
        return False
    finally:
        shutil.rmtree(scratch_dir, ignore_errors=True)


def run_cli_lost_and_found_recover(
    source: Path,
    lf_path: Path,
    sqlite3_bin: str,
    *,
    timeout: float = 3600.0,
) -> dict[str, Any]:
    attempts: list[dict[str, Any]] = []
    for command in (".recover --ignore-freelist", ".recover"):
        if lf_path.exists():
            lf_path.unlink()
        dump = subprocess.Popen(
            [sqlite3_bin, "-readonly", str(source), command],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        load = subprocess.Popen(
            [sqlite3_bin, str(lf_path)],
            stdin=dump.stdout,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        assert dump.stdout is not None
        dump.stdout.close()
        try:
            _, load_err = load.communicate(timeout=timeout)
            dump_err = dump.stderr.read() if dump.stderr is not None else b""
            dump.wait(timeout=60)
        except subprocess.TimeoutExpired:
            dump.kill()
            load.kill()
            raise LostAndFoundError(
                f"sqlite3 .recover timed out after {timeout:.0f}s"
            ) from None
        attempt = {
            "command": command,
            "dump_returncode": dump.returncode,
            "load_returncode": load.returncode,
            "dump_stderr_tail": dump_err.decode("utf-8", "replace")[-2000:],
            "load_stderr_tail": load_err.decode("utf-8", "replace")[-2000:],
        }
        attempts.append(attempt)
        if _lost_and_found_db_usable(lf_path):
            attempt["usable"] = True
            return {"binary": sqlite3_bin, "attempts": attempts}
        attempt["usable"] = False

    raise LostAndFoundError(
        "sqlite3 .recover did not produce a usable lost_and_found database: "
        + "; ".join(
            f"[{a['command']}] dump rc={a['dump_returncode']} "
            f"load rc={a['load_returncode']} "
            f"{a['dump_stderr_tail'] or a['load_stderr_tail']}".strip()
            for a in attempts
        )
    )


def _lost_and_found_db_usable(lf_path: Path) -> bool:
    if not lf_path.exists() or lf_path.stat().st_size == 0:
        return False
    try:
        conn = sqlite3.connect(str(lf_path))
        try:
            tables = [
                str(row[0])
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            ]
        finally:
            conn.close()
    except sqlite3.DatabaseError:
        return False
    return bool(tables)


def _table_columns(conn: sqlite3.Connection, table: str) -> list[str]:
    return [str(row[1]) for row in conn.execute(f'PRAGMA table_info("{table}")')]


def _notnull_defaults(conn: sqlite3.Connection, table: str) -> dict[int, Any]:
    substitutes: dict[int, Any] = {}
    for index, row in enumerate(conn.execute(f'PRAGMA table_info("{table}")')):
        if not row[3]:  # notnull flag
            continue
        default = row[4]
        if default is None:
            declared = str(row[2] or "").upper()
            substitutes[index] = 0 if ("INT" in declared or "REAL" in declared) else ""
            continue
        text = str(default)
        if text.startswith("'") and text.endswith("'"):
            substitutes[index] = text[1:-1]
        else:
            try:
                substitutes[index] = int(text)
            except ValueError:
                try:
                    substitutes[index] = float(text)
                except ValueError:
                    substitutes[index] = text
    return substitutes


def _is_session_id(value: Any) -> bool:
    return isinstance(value, str) and bool(SESSION_ID_PATTERN.match(value))


def _looks_like_source(value: Any) -> bool:
    if not isinstance(value, str) or not value:
        return False
    return value in KNOWN_SOURCES or bool(re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", value))


def classify_lost_and_found_row(
    nfield: int,
    cells: tuple[Any, ...],
) -> str | None:
    if len(cells) >= 3 and cells[0] is None:
        if (
            isinstance(cells[1], str)
            and cells[1]
            and isinstance(cells[2], str)
            and cells[2] in MESSAGE_ROLES
        ):
            return "messages"
        return None

    if not _is_session_id(cells[0] if cells else None):
        return None

    if nfield == SESSION_MODEL_USAGE_NFIELD:
        if len(cells) > 1 and isinstance(cells[1], str) and cells[1]:
            return "session_model_usage"
        return None

    if nfield in SESSIONS_LAYOUT_NFIELDS or nfield == SESSIONS_LEGACY_MINIMAL_NFIELD:
        if len(cells) > 1 and _looks_like_source(cells[1]):
            return "sessions"
        return None

    if nfield >= 30 and len(cells) > 1 and _looks_like_source(cells[1]):
        return "sessions"
    return None


def _heuristic_started_at(cells: tuple[Any, ...]) -> float:
    for value in cells:
        if (
            isinstance(value, (int, float))
            and _EPOCH_LOW <= float(value) <= _EPOCH_HIGH
        ):
            return float(value)
    return 0.0


def _insert_prefix_row(
    dest: sqlite3.Connection,
    table: str,
    dest_columns: list[str],
    values: list[Any],
    notnull_substitutes: dict[int, Any] | None = None,
) -> bool:
    if notnull_substitutes:
        values = [
            notnull_substitutes[index]
            if value is None and index in notnull_substitutes
            else value
            for index, value in enumerate(values)
        ]
    columns = dest_columns[: len(values)]
    quoted = ", ".join(f'"{column}"' for column in columns)
    placeholders = ", ".join("?" for _ in columns)
    cursor = dest.execute(
        f'INSERT OR IGNORE INTO "{table}" ({quoted}) VALUES ({placeholders})',
        values,
    )
    return cursor.rowcount == 1


def _copy_direct_tables(
    lf_conn: sqlite3.Connection,
    dest: sqlite3.Connection,
) -> dict[str, int]:
    copied: dict[str, int] = {}
    for table in (
        "system_prompts",
        "sessions",
        "messages",
        "session_model_usage",
        "compression_locks",
        "gateway_routing",
        "async_delegations",
    ):
        source_columns = _table_columns(lf_conn, table)
        if not source_columns:
            continue
        dest_columns = _table_columns(dest, table)
        columns = [c for c in dest_columns if c in source_columns]
        if not columns:
            continue
        quoted = ", ".join(f'"{c}"' for c in columns)
        placeholders = ", ".join("?" for _ in columns)
        rows = lf_conn.execute(f'SELECT {quoted} FROM "{table}"').fetchall()
        if not rows:
            copied[table] = 0
            continue
        before = int(dest.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
        dest.executemany(
            f'INSERT OR IGNORE INTO "{table}" ({quoted}) VALUES ({placeholders})',
            rows,
        )
        after = int(dest.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
        copied[table] = after - before
    return copied


def map_lost_and_found_rows(
    lf_conn: sqlite3.Connection,
    dest: sqlite3.Connection,
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "direct_table_rows": {},
        "mapped": {"sessions": 0, "messages": 0, "session_model_usage": 0},
        "legacy_minimal_sessions": 0,
        "unmapped_rows": 0,
        "insert_conflicts": 0,
        "lost_and_found_tables": [],
    }

    dest.execute("BEGIN IMMEDIATE")
    try:
        report["direct_table_rows"] = _copy_direct_tables(lf_conn, dest)

        sessions_columns = _table_columns(dest, "sessions")
        messages_columns = _table_columns(dest, "messages")
        usage_columns = _table_columns(dest, "session_model_usage")
        sessions_defaults = _notnull_defaults(dest, "sessions")
        messages_defaults = _notnull_defaults(dest, "messages")
        usage_defaults = _notnull_defaults(dest, "session_model_usage")
        for defaults, protected in (
            (sessions_defaults, (0, 1)),
            (messages_defaults, (1, 2)),
            (usage_defaults, (0, 1)),
        ):
            for index in protected:
                defaults.pop(index, None)

        lf_tables = [
            str(row[0])
            for row in lf_conn.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name LIKE 'lost_and_found%'"
            )
        ]
        report["lost_and_found_tables"] = lf_tables

        for lf_table in lf_tables:
            lf_columns = _table_columns(lf_conn, lf_table)
            if lf_columns[:3] != ["rootpgno", "pgno", "nfield"]:
                continue
            for row in lf_conn.execute(f'SELECT * FROM "{lf_table}"'):
                try:
                    nfield = int(row[2]) if row[2] is not None else 0
                except (TypeError, ValueError):
                    report["unmapped_rows"] += 1
                    continue
                lf_rowid = row[3]
                cells = tuple(row[4 : 4 + max(nfield, 0)])
                kind = classify_lost_and_found_row(nfield, cells)
                if kind is None:
                    report["unmapped_rows"] += 1
                    continue
                try:
                    if kind == "messages":
                        values = [
                            lf_rowid,
                            *cells[1 : min(nfield, len(messages_columns))],
                        ]
                        inserted = _insert_prefix_row(
                            dest,
                            "messages",
                            messages_columns,
                            values,
                            messages_defaults,
                        )
                    elif kind == "session_model_usage":
                        values = list(cells[: len(usage_columns)])
                        inserted = _insert_prefix_row(
                            dest,
                            "session_model_usage",
                            usage_columns,
                            values,
                            usage_defaults,
                        )
                    elif nfield == SESSIONS_LEGACY_MINIMAL_NFIELD:
                        inserted = bool(
                            dest.execute(
                                "INSERT OR IGNORE INTO sessions "
                                "(id, source, started_at, title) "
                                "VALUES (?, ?, ?, ?)",
                                (
                                    cells[0],
                                    cells[1]
                                    if _looks_like_source(cells[1])
                                    else "recovered",
                                    _heuristic_started_at(cells),
                                    "[best-effort recovered] legacy session "
                                    "row (layout unknown)",
                                ),
                            ).rowcount
                            == 1
                        )
                        if inserted:
                            report["legacy_minimal_sessions"] += 1
                    else:
                        values = list(cells[: min(nfield, len(sessions_columns))])
                        inserted = _insert_prefix_row(
                            dest,
                            "sessions",
                            sessions_columns,
                            values,
                            sessions_defaults,
                        )
                except sqlite3.DatabaseError:
                    report["unmapped_rows"] += 1
                    continue
                if inserted:
                    report["mapped"]["sessions" if kind == "sessions" else kind] += 1
                else:
                    report["insert_conflicts"] += 1
        dest.execute("COMMIT")
    except BaseException:
        dest.execute("ROLLBACK")
        raise
    return report


def stub_missing_parent_sessions(dest: sqlite3.Connection) -> dict[str, Any]:
    result: dict[str, Any] = {
        "sessions_stubbed": 0,
        "messages_retained": 0,
        "usage_rows_retained": 0,
    }
    dest.execute("BEGIN IMMEDIATE")
    try:
        orphan_ids: dict[str, dict[str, Any]] = {}
        for session_id, first_ts, count in dest.execute(
            "SELECT m.session_id, MIN(m.timestamp), COUNT(*) FROM messages AS m "
            "WHERE m.session_id IS NOT NULL AND NOT EXISTS "
            "(SELECT 1 FROM sessions WHERE sessions.id = m.session_id) "
            "GROUP BY m.session_id"
        ):
            orphan_ids[str(session_id)] = {
                "started_at": float(first_ts) if first_ts is not None else 0.0,
                "message_count": int(count),
            }
        for (session_id,) in dest.execute(
            "SELECT DISTINCT u.session_id FROM session_model_usage AS u "
            "WHERE u.session_id IS NOT NULL AND NOT EXISTS "
            "(SELECT 1 FROM sessions WHERE sessions.id = u.session_id)"
        ):
            orphan_ids.setdefault(
                str(session_id), {"started_at": 0.0, "message_count": 0}
            )

        sequence = 1
        for session_id, info in sorted(orphan_ids.items()):
            while True:
                title = (
                    f"[best-effort recovered {sequence}] session metadata "
                    "was unreadable"
                )
                sequence += 1
                if (
                    dest.execute(
                        "SELECT 1 FROM sessions WHERE title = ? LIMIT 1",
                        (title,),
                    ).fetchone()
                    is None
                ):
                    break
            dest.execute(
                "INSERT INTO sessions (id, source, started_at, title, "
                "message_count) VALUES (?, 'recovered', ?, ?, ?)",
                (
                    session_id,
                    info["started_at"],
                    title,
                    info["message_count"],
                ),
            )
            result["sessions_stubbed"] += 1
            result["messages_retained"] += info["message_count"]

        result["usage_rows_retained"] = int(
            dest.execute("SELECT COUNT(*) FROM session_model_usage").fetchone()[0]
        )

        dest.execute(
            "UPDATE sessions SET parent_session_id = NULL "
            "WHERE parent_session_id IS NOT NULL AND NOT EXISTS "
            "(SELECT 1 FROM sessions AS p WHERE p.id = sessions.parent_session_id)"
        )
        dest.execute(
            "UPDATE sessions SET system_prompt_hash = NULL "
            "WHERE system_prompt_hash IS NOT NULL AND NOT EXISTS "
            "(SELECT 1 FROM system_prompts "
            "WHERE system_prompts.hash = sessions.system_prompt_hash)"
        )
        dest.execute("COMMIT")
    except BaseException:
        dest.execute("ROLLBACK")
        raise
    return result


def rebuild_fts_indexes(dest: sqlite3.Connection) -> dict[str, str]:
    results: dict[str, str] = {}
    for table in ("messages_fts", "messages_fts_trigram", "messages_fts_cjk"):
        if not _table_columns(dest, table):
            continue
        try:
            dest.execute(f'INSERT INTO "{table}" ("{table}") VALUES (\'rebuild\')')
            results[table] = "rebuilt"
        except sqlite3.DatabaseError as exc:
            results[table] = f"rebuild failed: {exc}"
    return results


# ── driver ──────────────────────────────────────────────────────────────


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(
        description="Page-level lost-and-found salvage for a damaged Hermes state.db, "
        "using sqlite3's .recover instead of SQL-level rowid bisection. Use this when "
        "hermes_cli.session_lost_and_found isn't installed, or to cross-check a "
        "`hermes sessions recover --allow-partial` result against an independent method."
    )
    parser.add_argument(
        "--source",
        required=True,
        type=Path,
        help="Backup/malformed state.db to salvage",
    )
    parser.add_argument(
        "--output", required=True, type=Path, help="New output db path (must not exist)"
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="Scratch directory for the snapshot copy + lost_and_found db (default: alongside --output)",
    )
    args = parser.parse_args()

    from hermes_state import SessionDB

    try:
        from hermes_cli.session_recovery import _finalize_derived_metadata
    except ImportError:

        def _finalize_derived_metadata(
            destination: sqlite3.Connection,
        ) -> dict[str, Any]:
            return {
                "skipped": "hermes_cli.session_recovery._finalize_derived_metadata unavailable"
            }

    SOURCE = args.source
    WORK = args.work_dir or (args.output.parent / f"{args.output.name}.lf-work")
    OUTPUT = args.output

    WORK.mkdir(exist_ok=True, parents=True)
    snapshot = WORK / "snapshot.db"
    shutil.copy2(SOURCE, snapshot)

    sqlite3_bin = find_sqlite3_cli()
    print("sqlite3 CLI (dbpage-capable):", sqlite3_bin)
    if not sqlite3_bin:
        raise SystemExit("no .recover-capable sqlite3 found on PATH")

    lf_path = WORK / "lost_and_found.db"
    cli_report = run_cli_lost_and_found_recover(snapshot, lf_path, sqlite3_bin)
    last = cli_report["attempts"][-1]
    print("recover attempt:", last["command"], "usable:", last["usable"])

    if OUTPUT.exists():
        raise SystemExit(f"{OUTPUT} already exists - remove it or edit the path")

    destination_db = SessionDB(db_path=OUTPUT)
    destination_db.close()

    lf_conn = sqlite3.connect(str(lf_path), isolation_level=None)
    dest_conn = sqlite3.connect(str(OUTPUT), isolation_level=None, timeout=1.0)
    dest_conn.execute("PRAGMA foreign_keys=OFF")

    mapping = map_lost_and_found_rows(lf_conn, dest_conn)
    stubbing = stub_missing_parent_sessions(dest_conn)
    fts = rebuild_fts_indexes(dest_conn)
    derived = _finalize_derived_metadata(dest_conn)

    lf_conn.close()
    dest_conn.close()

    print("mapping:", mapping)
    print("stubbing:", stubbing)
    print("fts:", fts)
    print("derived_metadata:", derived)

    conn = sqlite3.connect(str(OUTPUT))
    for t in (
        "sessions",
        "messages",
        "session_model_usage",
        "system_prompts",
        "gateway_routing",
        "async_delegations",
    ):
        n = conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        print(f"{t}: {n}")
    conn.close()


if __name__ == "__main__":
    main()
