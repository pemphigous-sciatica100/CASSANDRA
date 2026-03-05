#!/usr/bin/env python3
"""
Migrate JSON snapshots to SQLite.

Pass 1: Scan all snap_*.json, collect unique nuclei (synset → word + anchor).
Pass 2: For each snap+delta pair chronologically, insert snapshot + observations.
Pass 3: Import positions from nucleus_positions.json.

Commits per snapshot for resumability. Skips already-imported timestamps.
"""

import json
import re
import sys
from pathlib import Path

from db import (
    get_connection, ensure_schema, pack_anchor, parse_wall_time,
)

BASE_DIR = Path(__file__).parent
SNAPSHOTS_DIR = BASE_DIR / 'snapshots'
POSITIONS_PATH = BASE_DIR / 'nucleus_positions.json'


def find_all_timestamps():
    """Find all snapshot timestamps in chronological order."""
    timestamps = []
    for p in SNAPSHOTS_DIR.glob('snap_*.json'):
        m = re.match(r'snap_(\d{8}_\d{6})\.json', p.name)
        if m:
            timestamps.append(m.group(1))
    timestamps.sort()
    return timestamps


def load_json(path):
    with open(path) as f:
        return json.load(f)


def main():
    conn = get_connection()
    ensure_schema(conn)

    timestamps = find_all_timestamps()
    print(f"Found {len(timestamps)} snapshots to migrate")

    # Check which timestamps are already imported
    existing = set(
        row[0] for row in conn.execute("SELECT timestamp FROM snapshots").fetchall()
    )
    to_import = [ts for ts in timestamps if ts not in existing]
    print(f"  {len(existing)} already imported, {len(to_import)} remaining")

    if not to_import:
        print("Nothing to do!")
        # Still import positions in case they're missing
        _import_positions(conn)
        conn.close()
        return

    # Pass 1+2 combined: process each snapshot chronologically
    nuclei_seen = set(
        row[0] for row in conn.execute("SELECT synset FROM nuclei").fetchall()
    )

    for i, ts in enumerate(to_import):
        snap_path = SNAPSHOTS_DIR / f"snap_{ts}.json"
        delta_path = SNAPSHOTS_DIR / f"delta_{ts}.json"

        try:
            snapshot = load_json(snap_path)
        except Exception as e:
            print(f"  [{i+1}/{len(to_import)}] SKIP {ts}: {e}")
            continue

        delta = {}
        if delta_path.exists():
            try:
                delta = load_json(delta_path)
            except Exception:
                pass

        wall_time = parse_wall_time(ts)

        # Insert new nuclei
        new_nuclei = []
        for synset, data in snapshot.items():
            if synset not in nuclei_seen and 'anchor' in data:
                new_nuclei.append((synset, data['word'], pack_anchor(data['anchor'])))
                nuclei_seen.add(synset)
        if new_nuclei:
            conn.executemany(
                "INSERT OR IGNORE INTO nuclei (synset, word, anchor) VALUES (?, ?, ?)",
                new_nuclei,
            )

        # Insert snapshot row
        conn.execute(
            "INSERT INTO snapshots (timestamp, wall_time) VALUES (?, ?)",
            (ts, wall_time),
        )
        snap_id = conn.execute(
            "SELECT id FROM snapshots WHERE timestamp = ?", (ts,)
        ).fetchone()[0]

        # Insert observations
        rows = []
        for synset, data in snapshot.items():
            if data.get('update_count', 0) > 0:
                rows.append((
                    snap_id,
                    synset,
                    data['update_count'],
                    data.get('exemplar_count', 0),
                    data.get('uncertainty', 1.0),
                    delta.get(synset, 0),
                ))
        if rows:
            conn.executemany(
                "INSERT INTO observations "
                "(snapshot_id, synset, update_count, exemplar_count, uncertainty, delta) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                rows,
            )

        conn.commit()

        if (i + 1) % 100 == 0 or i == len(to_import) - 1:
            print(f"  [{i+1}/{len(to_import)}] {ts}  "
                  f"({len(rows)} obs, {len(new_nuclei)} new nuclei)")

    # Pass 3: import positions
    _import_positions(conn)

    # Summary
    n_nuclei = conn.execute("SELECT COUNT(*) FROM nuclei").fetchone()[0]
    n_snaps = conn.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0]
    n_obs = conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
    n_pos = conn.execute("SELECT COUNT(*) FROM positions").fetchone()[0]
    db_path = conn.execute("PRAGMA database_list").fetchone()[2]
    db_size_mb = Path(db_path).stat().st_size / (1024 * 1024)

    print(f"\nMigration complete!")
    print(f"  {n_nuclei} nuclei, {n_snaps} snapshots, {n_obs} observations, {n_pos} positions")
    print(f"  Database size: {db_size_mb:.1f} MB")

    conn.close()


def _import_positions(conn):
    if not POSITIONS_PATH.exists():
        print("No positions file found, skipping")
        return

    positions = load_json(POSITIONS_PATH)
    existing = set(
        row[0] for row in conn.execute("SELECT synset FROM positions").fetchall()
    )
    new_pos = [
        (synset, pos[0], pos[1])
        for synset, pos in positions.items()
        if synset not in existing
    ]
    if new_pos:
        conn.executemany(
            "INSERT OR IGNORE INTO positions (synset, x, y) VALUES (?, ?, ?)",
            new_pos,
        )
        conn.commit()
    print(f"  Positions: {len(new_pos)} new, {len(existing)} existing")


if __name__ == '__main__':
    main()
