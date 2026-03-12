#!/usr/bin/env python3
"""Migration Supervisor CLI entry point."""

import sys
from pathlib import Path

# Add supervisor package to path
sys.path.insert(0, str(Path(__file__).parent))

from supervisor.cli import main

if __name__ == "__main__":
    main()
