"""Configuration management for the migration supervisor."""

import os
from pathlib import Path
from dataclasses import dataclass, field
from typing import List

@dataclass
class Config:
    """Supervisor configuration."""
    
    # Paths
    state_dir: Path = field(default_factory=lambda: Path("/var/tmp/migration_watchdog"))
    db_path: Path = field(default_factory=lambda: Path("/var/tmp/migration_watchdog/supervisor.db"))
    heartbeat_dir: Path = field(default_factory=lambda: Path("/var/tmp/migration_watchdog/heartbeats"))
    log_dirs: List[Path] = field(default_factory=lambda: [
        Path("LOG_imapsync/migrate/logs"),
        Path("migrate/logs"),
        Path("LOG_imapsync/LOG_imapsync/logs"),
    ])
    
    # Timing
    check_interval: int = 5  # seconds
    heartbeat_ttl: int = 300  # 5 minutes
    
    # Memory
    memory_limit_mb: int = 40960  # 40GB
    
    # Restart policy
    max_restarts: int = 6
    backoff_seconds: List[int] = field(default_factory=lambda: [60, 120, 300])  # 1m, 2m, 5m
    reset_restarts_after: int = 300  # 5 minutes
    
    # Mode
    mode: str = "observe"  # observe | control
    
    @classmethod
    def from_env(cls) -> "Config":
        """Load configuration from environment variables."""
        config = cls()

        def _parse_int(value: str, default: int) -> int:
            try:
                return int(value)
            except (TypeError, ValueError):
                return default
        
        if state_dir := os.environ.get("STATE_DIR"):
            config.state_dir = Path(state_dir)
            config.db_path = config.state_dir / "supervisor.db"
            config.heartbeat_dir = config.state_dir / "heartbeats"
            
        if check_interval := os.environ.get("CHECK_INTERVAL"):
            config.check_interval = _parse_int(check_interval, config.check_interval)
            
        if heartbeat_ttl := os.environ.get("HEARTBEAT_TTL"):
            config.heartbeat_ttl = _parse_int(heartbeat_ttl, config.heartbeat_ttl)
            
        if memory_limit := os.environ.get("MEMORY_LIMIT_MB"):
            config.memory_limit_mb = _parse_int(memory_limit, config.memory_limit_mb)
            
        if max_restarts := os.environ.get("MAX_RESTARTS"):
            config.max_restarts = _parse_int(max_restarts, config.max_restarts)
            
        if mode := os.environ.get("SUPERVISOR_MODE"):
            config.mode = mode
            
        return config
    
    def ensure_dirs(self) -> None:
        """Create required directories."""
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.heartbeat_dir.mkdir(parents=True, exist_ok=True)
        # Secure permissions
        self.state_dir.chmod(0o700)
        self.heartbeat_dir.chmod(0o700)
