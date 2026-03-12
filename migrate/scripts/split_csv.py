#!/usr/bin/env python3

"""
split_csv.py - Split migration CSV into smaller batches for parallel processing
"""

import csv
import os
import sys
import argparse
import math
from pathlib import Path


def validate_csv(filepath):
    """Validate CSV has required columns"""
    required_columns = {'src_user', 'src_pass', 'dst_user', 'dst_pass'}

    try:
        with open(filepath, 'r', newline='', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            headers = set(reader.fieldnames or [])

            missing = required_columns - headers
            if missing:
                raise ValueError(f"Missing required columns: {', '.join(missing)}")

            # Count rows
            row_count = sum(1 for _ in reader)
            if row_count == 0:
                raise ValueError("CSV file contains no data rows")

            return row_count + 1  # Include header

    except FileNotFoundError:
        raise ValueError(f"CSV file not found: {filepath}")
    except Exception as e:
        raise ValueError(f"Error reading CSV: {e}")


def split_csv(input_file, batch_size=None, num_batches=None, output_dir='migrate/config/batches'):
    """Split CSV into smaller batch files"""

    # Validate input
    total_rows = validate_csv(input_file) - 1  # Exclude header

    # Determine split strategy
    if batch_size and num_batches:
        raise ValueError("Cannot specify both batch_size and num_batches")
    elif batch_size:
        num_batches = math.ceil(total_rows / batch_size)
        rows_per_batch = batch_size
    elif num_batches:
        rows_per_batch = math.ceil(total_rows / num_batches)
    else:
        # Default: max 10 users per batch
        rows_per_batch = min(10, total_rows)
        num_batches = math.ceil(total_rows / rows_per_batch)

    # Create output directory
    Path(output_dir).mkdir(parents=True, exist_ok=True)

    # Read input CSV
    with open(input_file, 'r', newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        headers = reader.fieldnames

    # Split into batches
    batch_files = []
    batch_stats = []

    for batch_num in range(num_batches):
        start_idx = batch_num * rows_per_batch
        end_idx = min(start_idx + rows_per_batch, total_rows)
        batch_rows = rows[start_idx:end_idx]

        if not batch_rows:
            break

        # Generate batch filename
        batch_file = Path(output_dir) / f"batch_{batch_num + 1:03d}.csv"
        batch_files.append(str(batch_file))

        # Write batch file
        with open(batch_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=headers)
            writer.writeheader()
            writer.writerows(batch_rows)

        # Collect statistics
        batch_stats.append({
            'batch_num': batch_num + 1,
            'file': str(batch_file),
            'users': len(batch_rows),
            'first_user': batch_rows[0]['dst_user'],
            'last_user': batch_rows[-1]['dst_user']
        })

    return batch_files, batch_stats


def print_summary(batch_stats, total_rows):
    """Print batch splitting summary"""
    print("\n" + "=" * 60)
    print("CSV Split Summary")
    print("=" * 60)
    print(f"Total users: {total_rows}")
    print(f"Number of batches: {len(batch_stats)}")
    print(f"Average users per batch: {total_rows / len(batch_stats):.1f}")
    print("\nBatch Details:")
    print("-" * 60)

    for stat in batch_stats:
        print(f"Batch {stat['batch_num']:3d}: {stat['users']:3d} users | "
              f"{stat['first_user']} ... {stat['last_user']}")

    print("-" * 60)
    print("\nBatch files created in:", os.path.dirname(batch_stats[0]['file']))
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description='Split migration CSV into smaller batches for parallel processing',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Split into batches of 5 users each
  python3 split_csv.py migration_map.csv --batch-size 5

  # Split into exactly 10 batches
  python3 split_csv.py migration_map.csv --num-batches 10

  # Use default (10 users per batch)
  python3 split_csv.py migration_map.csv

  # Specify custom output directory
  python3 split_csv.py migration_map.csv --output-dir /tmp/batches
        """
    )

    parser.add_argument('input_csv',
                       help='Path to the input CSV file')

    parser.add_argument('--batch-size',
                       type=int,
                       metavar='N',
                       help='Number of users per batch')

    parser.add_argument('--num-batches',
                       type=int,
                       metavar='N',
                       help='Total number of batches to create')

    parser.add_argument('--output-dir',
                       default='migrate/config/batches',
                       help='Directory to store batch files (default: migrate/config/batches)')

    parser.add_argument('--quiet',
                       action='store_true',
                       help='Suppress summary output')

    args = parser.parse_args()

    try:
        # Validate input
        total_rows = validate_csv(args.input_csv) - 1

        # Split CSV
        batch_files, batch_stats = split_csv(
            args.input_csv,
            batch_size=args.batch_size,
            num_batches=args.num_batches,
            output_dir=args.output_dir
        )

        # Print summary unless quiet
        if not args.quiet:
            print_summary(batch_stats, total_rows)

        # Print batch files for scripting
        if args.quiet:
            for batch_file in batch_files:
                print(batch_file)

        return 0

    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())