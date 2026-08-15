# Hermes state.db recovery — HOWTO

Incident: `/mnt/volumes/data/state.db` failed with `database disk image is
malformed`. In-place repair failed on the `messages` table. Two independent
recovery passes against the preserved backup converged on the same result:
**31 sessions (20 original + 11 reconstructed placeholders), ~3,069-3,070
messages recovered**. That convergence between unrelated recovery methods is
strong evidence this is the real recoverable ceiling, not a tooling artifact.

Backup preserved at: `/mnt/volumes/data/state.db.malformed-backup-20260814_170116`
— keep this file indefinitely. Every script below only ever reads it via a
scratch copy or `-readonly`; nothing here can damage it further.

This doc has two parts:

- **Part 1 — Cutover**: get hermes back up and running on the best recovered data.
- **Part 2 — Toolkit**: reusable scripts for continuing to dig into the backup,
  or for the next time this happens.

All commands run inside the pod: `kubectl exec -n ai deploy/hermes -it -- zsh`
(as root). To get these scripts onto the pod, either `kubectl cp` this whole
`scripts/` directory in, or `cat > file <<'EOF' ... EOF` each one — quote the
heredoc delimiter (`<<'EOF'`, not `<<EOF`) since a couple of these scripts
contain literal backticks.

```bash
kubectl cp scripts ai/<pod-name>:/tmp/hermes-recovery-scripts
```

---

## Part 1 — Cutover

### 1. Pick the candidate

You have (at least) two recovered databases from this incident:

| file | method | sessions | messages |
|---|---|---|---|
| `recovered-state.db` | SQL rowid-bisection (`hermes sessions recover --allow-partial`) | 31 (20 real) | 3,069 |
| `recovered-state-v2.db` | page-level `sqlite3 .recover` salvage | 31 (21 real) | 3,070 |

`recovered-state-v2.db` is the better default: it came entirely through
`.recover`'s direct schema-attributed reconstruction (its `mapped` counts
were all zero — nothing relied on the fuzzy heuristic classifier), and it
recovered one extra real session and message. Use it unless you've already
built a merged union of both (see `07_diff_recovered_dbs.py` in the toolkit
if you want to chase that last row-or-two).

### 2. Run the cutover script

```bash
./scripts/01_cutover.sh --recovered /mnt/volumes/data/recovered-state-v2.db
```

This is not a black box — read it before running it once. It:

1. Runs `PRAGMA integrity_check` + `PRAGMA foreign_key_check` on the
   candidate and aborts if either fails.
2. Holds the s6-supervised `hermes` service down (`s6-svc -d`) and waits for
   the process to actually exit, so nothing reopens `state.db` mid-swap.
3. Backs up the current live `state.db` to a timestamped copy before
   touching it.
4. Deletes stale `-wal`/`-shm`/`-journal` sidecars next to the live path —
   skipping this is the one step that can turn a clean swap into a *new*
   corruption, since SQLite will try to replay a stale WAL against unrelated
   data on next open.
5. Copies the candidate into place as the live `state.db`.
6. Re-verifies the installed file's integrity before restarting anything; if
   that check fails it automatically restores the pre-swap backup.
7. Restarts the service (`s6-svc -u`) and confirms a `hermes gateway run`
   process comes up.

### 3. Confirm from the app's own view

```bash
hermes sessions list --limit 5
```

### 4. What's permanently different afterward

- 10-11 sessions now show as `[best-effort recovered N] session metadata was
  unreadable` / `[recovered N] ...` — their conversation text survived, but
  title, model, timestamps, and cost are gone.
- Whatever message content existed beyond the ~3,070 recovered is gone. If
  anything downstream depends on completeness here (users, billing
  reconciliation, audit trail), flag it now.

### 5. Don't clean up yet

Keep all of these around for a while after cutover, in case something
surfaces once real traffic hits the recovered data:

- `state.db.malformed-backup-20260814_170116` (the original corruption)
- `recovered-state.db` + `.recovery.json`
- `recovered-state-v2.db`
- `state.db.pre-install-backup-<timestamp>` (written by the cutover script)

---

## Part 2 — Toolkit

Scripts live in `scripts/`. All are safe to re-run and never mutate a source
backup in place — they copy first or open `-readonly`.

### `02_inspect_backup.sh <backup-path>`

Thin wrapper around `hermes sessions recover --inspect-only`. Re-check
whether a backup's canonical tables (`sessions`, `messages`) are readable at
any time, without committing to a full recovery run.

```bash
./scripts/02_inspect_backup.sh /mnt/volumes/data/state.db.malformed-backup-20260814_170116
```

### `03_read_recovery_report.py <report.recovery.json>`

Pretty-prints the JSON report from any `hermes sessions recover` run: per-table
copy status, skipped rowid ranges, orphan cleanup, and verification
warnings/errors in one screen instead of raw JSON.

```bash
python3 ./scripts/03_read_recovery_report.py /mnt/volumes/data/recovered-state.db.recovery.json
```

### `04_lf_recover_standalone.py --source <backup> --output <new.db>`

Page-level salvage via `sqlite3 .recover`, independent of SQL rowid
bisection. This is `hermes_cli.session_lost_and_found`'s logic, inlined
verbatim (diffed line-for-line against the hermes-agent `main` branch source)
because that module isn't present in this deployment's installed package —
only `hermes_state` and `hermes_cli.session_recovery` are required, both of
which are already proven present since `--allow-partial` used them
successfully during this incident.

Use this any time `hermes sessions recover --allow-partial` reports a table
`status: failed` or a suspiciously large `skipped_rowid_span` /
`query_limit_reached: true` — that combination means the SQL-bisection
salvage couldn't get clean rowid bounds (typically because corruption sits
near the table's own root page) and burned its 10,000-query budget
subdividing synthetic empty rowid space rather than mapping real rows. A
raw page scan doesn't have that failure mode.

```bash
python3 ./scripts/04_lf_recover_standalone.py \
    --source /mnt/volumes/data/state.db.malformed-backup-20260814_170116 \
    --output /mnt/volumes/data/recovered-state-v3.db
```

Requires a `.recover`-capable `sqlite3` on PATH (checks for the
`sqlite_dbpage` extension automatically; prints `None` and exits if missing —
some distro packages omit it, get a static build from sqlite.org or
`brew install sqlite` if you hit that on a different host).

### `05_raw_integrity_check.sh <backup-path>`

Runs `PRAGMA integrity_check` / `quick_check` directly against a scratch copy
of the backup — more granular than the hermes-level inspect, since SQLite
names the actual corrupted pages/cells instead of just "table X unreadable".
Useful for characterizing how widespread the damage is (one bad page vs.
scattered corruption throughout).

```bash
./scripts/05_raw_integrity_check.sh /mnt/volumes/data/state.db.malformed-backup-20260814_170116
```

### `06_spot_check_messages.py <recovered.db>`

Row counts matching between two recovery methods proves *how many* rows came
back, not that the text inside is intact. Pulls samples spread across the id
space (start/quartiles/end) plus the first message of every reconstructed
placeholder session, so you can eyeball whether content reads as real
conversation text or garbled fragments.

```bash
python3 ./scripts/06_spot_check_messages.py /mnt/volumes/data/recovered-state-v2.db
```

### `07_diff_recovered_dbs.py <A.db> <B.db>`

Row-level (not just count-level) diff between two recovered candidates, by
primary key, per table. Matching counts can still hide different underlying
rows — this tells you exactly which ids are `only_A`, `only_B`, or `both`, so
you can build a proper union (`INSERT OR IGNORE` from B's `only_B` rows into
a copy of A) instead of picking one candidate and silently losing whatever
only the other one found.

```bash
python3 ./scripts/07_diff_recovered_dbs.py \
    /mnt/volumes/data/recovered-state.db \
    /mnt/volumes/data/recovered-state-v2.db
```

---

## Reading a `.recovery.json` report — field cheat sheet

- `copy.<table>.status`: `complete` (every row read), `partial` (some rows
  skipped, real corruption), `failed` (nothing usable), `missing` (table
  absent from source, not corruption).
- `copy.<table>.skipped_rowid_span` near `2^63` combined with
  `query_limit_reached: true` — the salvage budget was spent on synthetic
  empty rowid space, not mapping real data. Re-run via `04_lf_recover_standalone.py`.
- `orphan_cleanup.sessions_reconstructed` / `messages_retained` — messages
  are never dropped for lacking a parent session; a placeholder session is
  synthesized instead. This count is data *retained*, not lost.
- `verification.loss_detected` — true whenever anything is short of a fully
  clean 1:1 recovery, even if `verification.healthy` is also true. `healthy`
  means the output database itself is structurally sound; `loss_detected`
  means it doesn't have everything the source was supposed to.
- `verification.warnings` vs `.errors` — warnings are acknowledged, expected
  loss under `--allow-partial`; errors mean don't install this output.

i## Quick recovery

`./scripts/01_cutover.sh --recovered /mnt/volumes/data/recovered-state-v2.db`
