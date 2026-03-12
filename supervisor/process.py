"""Process discovery and management using psutil."""

import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional
import psutil

@dataclass
class ImapsyncProcess:
    """Represents a running imapsync process."""
    pid: int
    account: str
    cmdline: str
    rss_mb: int
    uptime_secs: int
    create_time: float

def _is_imapsync_cmd(cmdline: List[str]) -> bool:
    for arg in cmdline:
        base = Path(arg).name
        if base == "imapsync_cmd.sh":
            continue
        if base == "imapsync" or base.startswith("imapsync-") or base.startswith("imapsync_") or base.startswith("imapsync."):
            return True
    return False


def discover_imapsync_processes() -> List[ImapsyncProcess]:
    """Find all running imapsync processes."""
    processes = []
    
    for proc in psutil.process_iter(['pid', 'name', 'cmdline', 'memory_info', 'create_time']):
        try:
            info = proc.info
            cmdline = info.get('cmdline') or []
            cmdline_str = ' '.join(cmdline)
            
            # Match imapsync processes (perl or direct)
            if not _is_imapsync_cmd(cmdline):
                continue
            
            # Skip watchdog and monitor processes
            if 'migration_watchdog' in cmdline_str or 'universal_monitor' in cmdline_str:
                continue
            
            # Extract account (prefer --user2, fall back to --user1)
            account = extract_account_from_cmdline(cmdline)
            if not account:
                continue
            
            # Get memory and uptime
            mem_info = info.get('memory_info')
            rss_mb = (mem_info.rss // (1024 * 1024)) if mem_info else 0
            
            create_time = info.get('create_time', 0)
            uptime_secs = int(time.time() - create_time) if create_time else 0
            
            processes.append(ImapsyncProcess(
                pid=info['pid'],
                account=account,
                cmdline=cmdline_str,
                rss_mb=rss_mb,
                uptime_secs=uptime_secs,
                create_time=create_time,
            ))
            
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
    
    return processes


def extract_account_from_cmdline(cmdline: List[str]) -> Optional[str]:
    """Extract account email from imapsync command line."""
    # Try --user2 first (destination = canonical)
    for i, arg in enumerate(cmdline):
        if arg == '--user2' and i + 1 < len(cmdline):
            return cmdline[i + 1].strip("'\"")
        if arg.startswith('--user2='):
            return arg.split('=', 1)[1].strip("'\"")
    
    # Fall back to --user1
    for i, arg in enumerate(cmdline):
        if arg == '--user1' and i + 1 < len(cmdline):
            return cmdline[i + 1].strip("'\"")
        if arg.startswith('--user1='):
            return arg.split('=', 1)[1].strip("'\"")
    
    return None


def get_process_rss_mb(pid: int) -> Optional[int]:
    """Get RSS memory in MB for a PID."""
    try:
        proc = psutil.Process(pid)
        return proc.memory_info().rss // (1024 * 1024)
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None


def is_process_alive(pid: int) -> bool:
    """Check if a process is still running."""
    try:
        proc = psutil.Process(pid)
        return proc.is_running() and proc.status() != psutil.STATUS_ZOMBIE
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False


def kill_process(pid: int, force: bool = False) -> bool:
    """Kill a process. Use force=True for SIGKILL."""
    try:
        proc = psutil.Process(pid)
        if force:
            proc.kill()
        else:
            proc.terminate()
        return True
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False
