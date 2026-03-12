"""Data models for the migration supervisor."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from enum import Enum

class Status(str, Enum):
    """Migration run status."""
    PENDING = "pending"
    RUNNING = "running"
    PAUSED = "paused"
    COMPLETE = "complete"
    RETRYABLE = "retryable"
    FATAL = "fatal"
    USER_STOP = "user-stop"

class Policy(str, Enum):
    """Account restart policy."""
    MONITOR = "monitor"
    AUTO = "auto"
    NEVER = "never"

class EventType(str, Enum):
    """Event types for the events table."""
    DISCOVERED = "discovered"
    STARTED = "started"
    PROGRESS = "progress"
    STALL = "stall"
    RESTART = "restart"
    COMPLETED = "completed"
    FAILED = "failed"
    ERROR = "error"
    SNAPSHOT = "snapshot"
    POLICY_CHANGE = "policy"

@dataclass
class Account:
    """An email account being migrated."""
    id: Optional[int] = None
    email: str = ""
    src_host: str = ""
    dst_host: str = ""
    policy: Policy = Policy.MONITOR
    active: bool = True
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

@dataclass
class Run:
    """A migration run for an account."""
    id: Optional[int] = None
    account_id: int = 0
    pid: Optional[int] = None
    status: Status = Status.RUNNING
    started_at: Optional[datetime] = None
    ended_at: Optional[datetime] = None
    exit_code: Optional[int] = None
    restarts: int = 0
    manifest_cmd: Optional[str] = None
    log_path: Optional[str] = None
    last_reason: Optional[str] = None
    last_heartbeat_ts: Optional[int] = None

@dataclass
class Metric:
    """Point-in-time metrics for a run."""
    id: Optional[int] = None
    run_id: int = 0
    ts: int = 0  # epoch seconds
    rss_mb: Optional[int] = None
    heartbeat_age_s: Optional[int] = None
    msgs_found: Optional[int] = None
    msgs_copied: Optional[int] = None
    bytes_copied: Optional[int] = None
    current_folder: Optional[str] = None
    rate_msgs_s: Optional[float] = None

@dataclass
class Event:
    """An event in the migration lifecycle."""
    id: Optional[int] = None
    ts: int = 0  # epoch seconds
    account_id: Optional[int] = None
    run_id: Optional[int] = None
    event_type: EventType = EventType.PROGRESS
    message: Optional[str] = None
    metadata_json: Optional[str] = None
