"""CLI for the migration supervisor."""

import time
import re
from pathlib import Path
from collections import deque
from typing import Optional, List, Set
from datetime import datetime

import typer
from rich.console import Console
from rich.table import Table

from .config import Config
from .db import init_db_sync
from .process import discover_imapsync_processes

app = typer.Typer(help="Migration Supervisor - Monitor and manage imapsync migrations")
console = Console()

RETRY_EXIT_CODES = {6, 11, 74, 75, 111, 162}


def _sanitize_account(account: str) -> str:
    safe = account.replace("@", "_at_")
    return re.sub(r"[^a-zA-Z0-9._+\-]", "_", safe)


def _sanitize_legacy(account: str) -> str:
    safe = account.replace("@", "_")
    return re.sub(r"[^a-zA-Z0-9._\-]", "", safe)


def _read_manifest_log_path(manifest_path: Path) -> Optional[Path]:
    try:
        lines = manifest_path.read_text(errors="ignore").splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("LOG_FILE="):
            value = line.split("=", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            if value:
                path = Path(value)
                if path.exists():
                    return path
    return None


def _find_log_file(account: str, state_dir: Path, log_dirs: List[Path]) -> Optional[Path]:
    safe = _sanitize_account(account)
    legacy = _sanitize_legacy(account)

    for name in (safe, legacy):
        manifest_path = state_dir / f"{name}.manifest"
        if manifest_path.exists():
            log_path = _read_manifest_log_path(manifest_path)
            if log_path:
                return log_path

    for log_dir in log_dirs:
        if not log_dir.is_dir():
            continue
        latest_link = log_dir / f"{safe}_latest.log"
        if latest_link.exists():
            try:
                resolved = latest_link.resolve()
            except OSError:
                resolved = latest_link
            if resolved.exists():
                return resolved
        matches = sorted(log_dir.glob(f"{safe}_*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
        if matches:
            return matches[0]
    return None


def _parse_exit_code(log_path: Optional[Path]) -> Optional[int]:
    if not log_path or not log_path.exists():
        return None
    try:
        with log_path.open("r", errors="ignore") as handle:
            tail = deque(handle, maxlen=200)
    except OSError:
        return None
    for line in reversed(tail):
        match = re.search(r"Exiting with return value (\d+)", line)
        if match:
            return int(match.group(1))
    return None


def _classify_status(exit_code: Optional[int], log_path: Optional[Path]) -> str:
    if exit_code is not None:
        if exit_code == 0:
            return "complete"
        if exit_code in (137, 143):
            return "user-stop"
        if exit_code == 162:
            return "rate-limited"
        if exit_code in RETRY_EXIT_CODES:
            return "retryable"
        return "fatal"

    if log_path and log_path.exists():
        try:
            with log_path.open("r", errors="ignore") as handle:
                tail = "".join(deque(handle, maxlen=200))
        except OSError:
            tail = ""
        if re.search(r"EXIT_BY_SIGNAL|Killed by signal|SIGTERM|SIGKILL", tail):
            return "retryable"
        if re.search(r"Connection reset|timeout|temporarily unavailable|Network is unreachable", tail):
            return "retryable"

    return "fatal"


@app.command()
def init_db_cmd(
    db: Path = typer.Option(
        Path("/var/tmp/migration_watchdog/supervisor.db"),
        "--db",
        help="Database path",
    ),
):
    """Initialize the SQLite database with schema."""
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = init_db_sync(db)
    conn.close()
    console.print(f"[green]Database initialized:[/green] {db}")


@app.command()
def status(
    db: Path = typer.Option(
        Path("/var/tmp/migration_watchdog/supervisor.db"),
        "--db",
        help="Database path",
    ),
):
    """Show current migration status."""
    if not db.exists():
        console.print("[yellow]Database not found. Run 'init-db-cmd' first.[/yellow]")
        console.print("\nLive process discovery:")
        _show_live_processes()
        return
    
    conn = init_db_sync(db)
    
    # Get accounts with active runs
    cursor = conn.execute("""
        SELECT a.email, a.policy, r.pid, r.status, r.started_at, r.restarts, r.exit_code
        FROM accounts a
        LEFT JOIN runs r ON r.account_id = a.id AND r.ended_at IS NULL
        WHERE a.active = 1
        ORDER BY a.email
    """)
    
    table = Table(title="Migration Status")
    table.add_column("Account", style="cyan")
    table.add_column("Policy")
    table.add_column("PID")
    table.add_column("Status")
    table.add_column("Started")
    table.add_column("Restarts")
    
    for row in cursor:
        pid_str = str(row['pid']) if row['pid'] else "-"
        status_str = row['status'] or "no run"
        started = row['started_at'][:19] if row['started_at'] else "-"
        restarts = str(row['restarts']) if row['restarts'] else "0"
        
        # Color status
        if row['status'] == 'running':
            status_str = f"[green]{status_str}[/green]"
        elif row['status'] == 'retryable':
            status_str = f"[yellow]{status_str}[/yellow]"
        elif row['status'] == 'rate-limited':
            status_str = f"[yellow]{status_str}[/yellow]"
        elif row['status'] == 'user-stop':
            status_str = f"[yellow]{status_str}[/yellow]"
        elif row['status'] == 'fatal':
            status_str = f"[red]{status_str}[/red]"
        elif row['status'] == 'complete':
            status_str = f"[blue]{status_str}[/blue]"
        
        table.add_row(
            row['email'],
            row['policy'],
            pid_str,
            status_str,
            started,
            restarts,
        )
    
    conn.close()
    console.print(table)
    
    # Also show live processes
    console.print("\n[bold]Live Processes:[/bold]")
    _show_live_processes()


def _show_live_processes():
    """Display currently running imapsync processes."""
    processes = discover_imapsync_processes()
    
    if not processes:
        console.print("[yellow]No imapsync processes running[/yellow]")
        return
    
    table = Table()
    table.add_column("PID", style="cyan")
    table.add_column("Account")
    table.add_column("Memory (MB)")
    table.add_column("Uptime")
    
    for proc in processes:
        uptime = _format_uptime(proc.uptime_secs)
        table.add_row(
            str(proc.pid),
            proc.account,
            str(proc.rss_mb),
            uptime,
        )
    
    console.print(table)


def _format_uptime(seconds: int) -> str:
    """Format uptime in human-readable form."""
    if seconds < 60:
        return f"{seconds}s"
    elif seconds < 3600:
        m, s = divmod(seconds, 60)
        return f"{m}m {s}s"
    else:
        h, rem = divmod(seconds, 3600)
        m = rem // 60
        return f"{h}h {m}m"


@app.command()
def events(
    db: Path = typer.Option(
        Path("/var/tmp/migration_watchdog/supervisor.db"),
        "--db",
        help="Database path",
    ),
    limit: int = typer.Option(20, "--limit", "-n", help="Number of events to show"),
    event_type: Optional[str] = typer.Option(None, "--type", help="Filter by event type"),
):
    """Show recent events."""
    if not db.exists():
        console.print("[yellow]Database not found. Run 'init-db-cmd' first.[/yellow]")
        return
    
    conn = init_db_sync(db)
    
    query = """
        SELECT e.ts, e.event_type, e.message, a.email
        FROM events e
        LEFT JOIN accounts a ON e.account_id = a.id
    """
    params = []
    
    if event_type:
        query += " WHERE e.event_type = ?"
        params.append(event_type)
    
    query += " ORDER BY e.ts DESC LIMIT ?"
    params.append(limit)
    
    cursor = conn.execute(query, params)
    
    table = Table(title="Recent Events")
    table.add_column("Time", style="dim")
    table.add_column("Type", style="cyan")
    table.add_column("Account")
    table.add_column("Message")
    
    for row in cursor:
        ts = datetime.fromtimestamp(row['ts']).strftime('%Y-%m-%d %H:%M:%S')
        table.add_row(
            ts,
            row['event_type'],
            row['email'] or "-",
            row['message'] or "",
        )
    
    conn.close()
    console.print(table)


@app.command()
def scan(
    db: Path = typer.Option(
        Path("/var/tmp/migration_watchdog/supervisor.db"),
        "--db",
        help="Database path",
    ),
    state_dir: Path = typer.Option(
        Path("/var/tmp/migration_watchdog"),
        "--state-dir",
        help="State directory with manifests",
    ),
):
    """One-shot scan: discover processes and update database."""
    if not db.exists():
        console.print("[yellow]Initializing database...[/yellow]")
        db.parent.mkdir(parents=True, exist_ok=True)
        init_db_sync(db).close()
    
    conn = init_db_sync(db)
    now = int(time.time())
    
    processes = discover_imapsync_processes()
    console.print(f"[cyan]Discovered {len(processes)} imapsync process(es)[/cyan]")
    
    for proc in processes:
        # Upsert account
        conn.execute("""
            INSERT INTO accounts (email, src_host, dst_host, policy)
            VALUES (?, 'unknown', 'unknown', 'monitor')
            ON CONFLICT(email) DO UPDATE SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
        """, (proc.account,))
        
        # Get account id
        cursor = conn.execute("SELECT id FROM accounts WHERE email = ?", (proc.account,))
        account_id = cursor.fetchone()['id']
        
        # Check for existing run
        cursor = conn.execute("""
            SELECT id, pid FROM runs WHERE account_id = ? AND ended_at IS NULL
        """, (account_id,))
        existing = cursor.fetchone()
        
        if existing:
            if existing['pid'] != proc.pid:
                # PID changed - close old run, start new
                conn.execute("""
                    UPDATE runs SET ended_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                                    status = 'retryable'
                    WHERE id = ?
                """, (existing['id'],))
                
                conn.execute("""
                    INSERT INTO runs (account_id, pid, status)
                    VALUES (?, ?, 'running')
                """, (account_id, proc.pid))
            else:
                conn.execute("""
                    UPDATE runs SET status = 'running'
                    WHERE id = ?
                """, (existing['id'],))
        else:
            # New run
            conn.execute("""
                INSERT INTO runs (account_id, pid, status)
                VALUES (?, ?, 'running')
            """, (account_id, proc.pid))
        
        # Log discovery event
        conn.execute("""
            INSERT INTO events (ts, account_id, event_type, message)
            VALUES (?, ?, 'discovered', ?)
        """, (now, account_id, f"PID {proc.pid}, {proc.rss_mb}MB"))
        
        console.print(f"  [green]✓[/green] {proc.account} (PID {proc.pid})")
    
    conn.commit()
    conn.close()
    console.print("[green]Scan complete[/green]")


@app.command()
def supervise(
    db: Path = typer.Option(
        Path("/var/tmp/migration_watchdog/supervisor.db"),
        "--db",
        help="Database path",
    ),
    state_dir: Path = typer.Option(
        Path("/var/tmp/migration_watchdog"),
        "--state-dir",
        help="State directory",
    ),
    interval: int = typer.Option(5, "--interval", "-i", help="Check interval in seconds"),
    mode: str = typer.Option("observe", "--mode", "-m", help="Mode: observe or control"),
):
    """Run the supervisor daemon."""
    console.print(f"[cyan]Starting supervisor in {mode} mode...[/cyan]")
    console.print(f"  Database: {db}")
    console.print(f"  State dir: {state_dir}")
    console.print(f"  Interval: {interval}s")

    config = Config.from_env()
    log_dirs = config.log_dirs
    
    if not db.exists():
        console.print("[yellow]Initializing database...[/yellow]")
        db.parent.mkdir(parents=True, exist_ok=True)
        init_db_sync(db).close()
    
    try:
        while True:
            # Scan for processes
            conn = init_db_sync(db)
            now = int(time.time())
            
            processes = discover_imapsync_processes()
            live_pids: Set[int] = {proc.pid for proc in processes}
            
            # Update database
            for proc in processes:
                # Upsert account
                conn.execute("""
                    INSERT INTO accounts (email, src_host, dst_host, policy)
                    VALUES (?, 'unknown', 'unknown', 'monitor')
                    ON CONFLICT(email) DO UPDATE SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
                """, (proc.account,))
                
                cursor = conn.execute("SELECT id FROM accounts WHERE email = ?", (proc.account,))
                account_id = cursor.fetchone()['id']
                
                # Get or create run
                cursor = conn.execute("""
                    SELECT id, pid FROM runs WHERE account_id = ? AND ended_at IS NULL
                """, (account_id,))
                existing = cursor.fetchone()
                
                if not existing or existing['pid'] != proc.pid:
                    if existing:
                        conn.execute("""
                            UPDATE runs SET ended_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
                            WHERE id = ?
                        """, (existing['id'],))
                    
                    conn.execute("""
                        INSERT INTO runs (account_id, pid, status)
                        VALUES (?, ?, 'running')
                    """, (account_id, proc.pid))
                    
                    cursor = conn.execute("""
                        SELECT id FROM runs WHERE account_id = ? AND pid = ?
                    """, (account_id, proc.pid))
                    run_id = cursor.fetchone()['id']
                else:
                    run_id = existing['id']
                    conn.execute("""
                        UPDATE runs SET status = 'running'
                        WHERE id = ?
                    """, (run_id,))
                
                # Record metrics
                conn.execute("""
                    INSERT INTO metrics (run_id, ts, rss_mb)
                    VALUES (?, ?, ?)
                """, (run_id, now, proc.rss_mb))
            
            # Check for dead processes
            cursor = conn.execute("""
                SELECT r.id, r.pid, r.account_id, a.email
                FROM runs r
                JOIN accounts a ON r.account_id = a.id
                WHERE r.ended_at IS NULL
            """)
            
            for row in cursor.fetchall():
                if row['pid'] not in live_pids:
                    log_path = _find_log_file(row['email'], state_dir, log_dirs)
                    exit_code = _parse_exit_code(log_path)
                    status = _classify_status(exit_code, log_path)
                    event_type = "failed"
                    if status == "complete":
                        event_type = "completed"
                    elif status == "rate-limited":
                        event_type = "rate-limited"
                    elif status == "retryable":
                        event_type = "retryable"
                    elif status == "user-stop":
                        event_type = "user-stop"

                    conn.execute("""
                        UPDATE runs SET ended_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                                        status = ?,
                                        exit_code = ?
                        WHERE id = ?
                    """, (status, exit_code, row['id']))
                    
                    conn.execute("""
                        INSERT INTO events (ts, account_id, run_id, event_type, message)
                        VALUES (?, ?, ?, ?, ?)
                    """, (now, row['account_id'], row['id'], event_type, f"Process {row['pid']} ended ({status})"))
                    
                    if status == "complete":
                        console.print(f"[green]✓[/green] {row['email']} (PID {row['pid']}) completed")
                    elif status == "retryable":
                        console.print(f"[yellow]↻[/yellow] {row['email']} (PID {row['pid']}) ended retryable")
                    elif status == "user-stop":
                        console.print(f"[yellow]■[/yellow] {row['email']} (PID {row['pid']}) stopped")
                    else:
                        console.print(f"[red]✗[/red] {row['email']} (PID {row['pid']}) failed")
            
            conn.commit()
            conn.close()
            
            time.sleep(interval)
            
    except KeyboardInterrupt:
        console.print("\n[yellow]Supervisor stopped[/yellow]")


def main():
    """Entry point."""
    app()


if __name__ == "__main__":
    main()
