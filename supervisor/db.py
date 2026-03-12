"""Database management for the migration supervisor."""

import sqlite3
import aiosqlite
from pathlib import Path
from typing import Optional

PRAGMAS = """
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
"""

SCHEMA = PRAGMAS + """

CREATE TABLE IF NOT EXISTS accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    src_host TEXT NOT NULL,
    dst_host TEXT NOT NULL,
    policy TEXT NOT NULL DEFAULT 'monitor',
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL,
    pid INTEGER,
    status TEXT NOT NULL DEFAULT 'running',
    started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    ended_at TEXT,
    exit_code INTEGER,
    restarts INTEGER NOT NULL DEFAULT 0,
    manifest_cmd TEXT,
    log_path TEXT,
    last_reason TEXT,
    last_heartbeat_ts INTEGER,
    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL,
    ts INTEGER NOT NULL,
    rss_mb INTEGER,
    heartbeat_age_s INTEGER,
    msgs_found INTEGER,
    msgs_copied INTEGER,
    bytes_copied INTEGER,
    current_folder TEXT,
    rate_msgs_s REAL,
    FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    account_id INTEGER,
    run_id INTEGER,
    event_type TEXT NOT NULL,
    message TEXT,
    metadata_json TEXT,
    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE SET NULL,
    FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS config (
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    scope TEXT NOT NULL DEFAULT 'global',
    account_id INTEGER,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY (key, scope, account_id),
    FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_runs_account_started ON runs(account_id, started_at);
CREATE INDEX IF NOT EXISTS idx_metrics_run_ts ON metrics(run_id, ts);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_account ON events(account_id);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
"""

def _secure_db_file(db_path: Path) -> None:
    try:
        if db_path.exists():
            db_path.chmod(0o600)
    except OSError:
        pass


def init_db_sync(db_path: Path) -> sqlite3.Connection:
    """Initialize database synchronously."""
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.commit()
    _secure_db_file(db_path)
    return conn


async def init_db(db_path: Path) -> aiosqlite.Connection:
    """Initialize database asynchronously."""
    db = await aiosqlite.connect(str(db_path))
    db.row_factory = aiosqlite.Row
    await db.executescript(SCHEMA)
    await db.commit()
    _secure_db_file(db_path)
    return db


async def get_db(db_path: Path) -> aiosqlite.Connection:
    """Get async database connection."""
    db = await aiosqlite.connect(str(db_path))
    db.row_factory = aiosqlite.Row
    await db.executescript(PRAGMAS)
    return db
