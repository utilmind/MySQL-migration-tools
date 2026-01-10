#!/usr/bin/env python3
"""
pre-import.py

Copyright (c) 2025 utilmind
All rights reserved.
https://github.com/utilmind/MySQL-Migration-tools/

Pre-process a MySQL/MariaDB SQL dump before import.

Behavior:
- Never modifies the original dump; always writes a new output dump.
- Detects collations referenced in the dump.
- Checks whether each referenced collation is supported by the target server.
- If the dump contains collations NOT supported by the target server:
    - if mapping has a non-empty replacement -> it will be used
    - otherwise the script adds missing keys with empty values to the mapping JSON and exits with error

Target collation source (choose one):
1) --mysql-command "mysql ...": query target server directly
2) --target-collations file.txt: read collations list from a file

Mapping format:
{
  "from_collation": "to_collation",
  "unsupported_collation_without_choice_yet": ""
}
    * empty values should be filled manually.

USAGE (examples)

1) Preprocess dump by querying the TARGET server for supported collations (recommended):

   python3 pre-import.py --mysql-command "mysql -h127.0.0.1 -uroot -pPASS -N" --map collation-map.json input.sql output.patched.sql

2) Preprocess dump using a pre-exported list of supported collations (no DB connection from Python):

   mysql -h127.0.0.1 -uroot -pPASS -N -e "SELECT COLLATION_NAME FROM information_schema.COLLATIONS" > target-collations.txt
   python3 pre-import.py --target-collations target-collations.txt --map collation-map.json input.sql output.patched.sql

3) Dry run (scan + update mapping file, do NOT write output file):

   python3 pre-import.py --target-collations target-collations.txt --map collation-map.json --dry-run --show-summary input.sql output.patched.sql

"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import OrderedDict
from typing import Dict, Set, Tuple, Optional, List


# Common dump patterns:
#   COLLATE=xxx
#   COLLATE xxx
#   SET collation_connection=xxx
RE_COLLATE_EQ = re.compile(r"(?i)\bCOLLATE\s*=\s*([0-9A-Za-z_]+)\b")
RE_COLLATE_WS = re.compile(r"(?i)\bCOLLATE\s+([0-9A-Za-z_]+)\b")
RE_SET_COLLATION_CONN = re.compile(
    r"(?i)\bSET\s+(?:@@session\.)?collation_connection\s*=\s*'?(?P<coll>[0-9A-Za-z_]+)'?\s*;"
)


def load_mapping(path: str) -> "OrderedDict[str, str]":
    if not os.path.exists(path):
        return OrderedDict()
    raw = open(path, "r", encoding="utf-8").read().strip()
    if not raw:
        return OrderedDict()
    data = json.loads(raw, object_pairs_hook=OrderedDict)
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: Mapping file must contain a JSON object: {path}")
    out: "OrderedDict[str, str]" = OrderedDict()
    for k, v in data.items():
        if not isinstance(k, str):
            raise SystemExit(f"ERROR: Mapping key must be a string, got: {k!r}")
        if v is None:
            v = ""
        if not isinstance(v, str):
            raise SystemExit(f"ERROR: Mapping value must be a string (or empty), got {k!r}: {v!r}")
        out[k] = v
    return out


def save_mapping(path: str, mapping: "OrderedDict[str, str]") -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        # Pretty JSON: one key-value per line
        json.dump(mapping, f, ensure_ascii=False, indent=2)
        f.write("\n")


def load_target_collations_from_file(path: str) -> Set[str]:
    """
    Accepts:
    - one collation per line OR
    - tabular output (first column is collation name)
    """
    out: Set[str] = set()
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            # first token
            name = re.split(r"[\s\t|]+", s)[0].strip()
            if re.fullmatch(r"[0-9A-Za-z_]+", name):
                out.add(name)
    return out


def load_target_collations_via_mysql(mysql_command: str) -> Set[str]:
    """
    Uses mysql client to query supported collations from target server.
    mysql_command should accept SQL on stdin.
    """
    sql = "SELECT COLLATION_NAME FROM information_schema.COLLATIONS;"
    proc = subprocess.run(
        mysql_command,
        input=sql,
        text=True,
        capture_output=True,
        shell=True,
    )
    if proc.returncode != 0:
        raise SystemExit(
            "ERROR: Failed to query target collations via mysql client.\n"
            f"Command: {mysql_command}\n"
            f"Exit code: {proc.returncode}\n"
            f"STDERR:\n{proc.stderr.strip()}\n"
        )
    out: Set[str] = set()
    for line in proc.stdout.splitlines():
        name = line.strip()
        if re.fullmatch(r"[0-9A-Za-z_]+", name):
            out.add(name)
    if not out:
        raise SystemExit(
            "ERROR: Target collation query returned no rows. "
            "Check connection/permissions."
        )
    return out


def scan_dump_for_collations(path: str, chunk_size: int = 1024 * 1024) -> Set[str]:
    found: Set[str] = set()
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            for m in RE_COLLATE_EQ.finditer(chunk):
                found.add(m.group(1))
            for m in RE_COLLATE_WS.finditer(chunk):
                found.add(m.group(1))
            for m in RE_SET_COLLATION_CONN.finditer(chunk):
                found.add(m.group("coll"))
    return found


def build_replacements(
    referenced: Set[str],
    supported: Set[str],
    mapping: "OrderedDict[str, str]",
) -> Tuple[Dict[str, str], Set[str], Dict[str, str]]:
    """
    Returns:
      replacements: unsupported->mapped_to (only where mapped_to non-empty)
      missing: unsupported collations with no mapping or empty mapping
      invalid_targets: mapping points to a collation not supported by target
    """
    replacements: Dict[str, str] = {}
    missing: Set[str] = set()
    invalid_targets: Dict[str, str] = {}

    for c in sorted(referenced):
        if c in supported:
            continue

        mapped = mapping.get(c, "").strip()
        if not mapped:
            missing.add(c)
            continue

        if mapped not in supported:
            invalid_targets[c] = mapped
            continue

        replacements[c] = mapped

    return replacements, missing, invalid_targets


def apply_replacements_stream(
    input_path: str,
    output_path: str,
    replacements: Dict[str, str],
    chunk_size: int = 1024 * 1024,
) -> None:
    # Compile regex substitutions per collation
    subs: List[Tuple[re.Pattern, str]] = []
    for src, dst in replacements.items():
        subs.append((re.compile(rf"(?i)(\bCOLLATE\s*=\s*){re.escape(src)}\b"), r"\1" + dst))
        subs.append((re.compile(rf"(?i)(\bCOLLATE\s+){re.escape(src)}\b"), r"\1" + dst))
        subs.append(
            (
                re.compile(
                    rf"(?i)(\bSET\s+(?:@@session\.)?collation_connection\s*=\s*'?)"
                    + re.escape(src)
                    + r"(\b'?\s*;)"
                ),
                r"\1" + dst + r"\2",
            )
        )

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(input_path, "r", encoding="utf-8", errors="replace", newline="") as fin, \
         open(output_path, "w", encoding="utf-8", errors="replace", newline="\n") as fout:
        while True:
            chunk = fin.read(chunk_size)
            if not chunk:
                break
            new_chunk = chunk
            for pat, repl in subs:
                new_chunk = pat.sub(repl, new_chunk)
            fout.write(new_chunk)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Pre-process SQL dump: validate & replace unsupported collations.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--mysql-command", help="Shell command to run mysql client (reads SQL from stdin).")
    src.add_argument("--target-collations", help="File containing supported target collations.")
    ap.add_argument("--map", dest="map_file", default="collation-map.json", help="Mapping JSON file.")
    ap.add_argument("--dry-run", action="store_true", help="Scan + update mapping file, but do not write output dump.")
    ap.add_argument("--report", help="Write a JSON report.")
    ap.add_argument("--show-summary", action="store_true", help="Print a summary.")
    ap.add_argument("input", help="Input dump (.sql)")
    ap.add_argument("output", help="Output dump (.sql) to be created")
    args = ap.parse_args(argv)

    mapping = load_mapping(args.map_file)

    if args.mysql_command:
        supported = load_target_collations_via_mysql(args.mysql_command)
    else:
        supported = load_target_collations_from_file(args.target_collations)

    referenced = scan_dump_for_collations(args.input)
    unsupported = {c for c in referenced if c not in supported}

    # Ensure every unsupported collation appears in mapping (even if empty)
    mapping_changed = False
    for c in sorted(unsupported):
        if c not in mapping:
            mapping[c] = ""
            mapping_changed = True

    replacements, missing, invalid_targets = build_replacements(referenced, supported, mapping)

    # Save mapping if new keys were added
    if mapping_changed:
        save_mapping(args.map_file, mapping)

    if invalid_targets:
        print("ERROR: Mapping points to collations NOT supported by the target server:", file=sys.stderr)
        for src, dst in sorted(invalid_targets.items()):
            print(f"  {src} -> {dst}", file=sys.stderr)
        print("Please fix the mapping file and rerun.", file=sys.stderr)
        return 2

    if missing:
        # Also guarantee missing are present (they are), keep values empty.
        if not mapping_changed:
            # still rewrite to keep formatting consistent if file existed but was messy
            save_mapping(args.map_file, mapping)

        missing_list = "\n".join(f"\t{c}" for c in sorted(missing))
        print(
            "Not all collations can be auto-replaced.\n\n"
            "Found collations in the dump that are NOT supported by the target server, "
            "and there is no mapping for them (or the mapping value is empty).\n\n"
            f"Added {len(missing)} missing keys to the mapping file with empty values: {args.map_file}\n"
            f"{missing_list}\n\n"
            f"Please open '{args.map_file}' and fill in the replacement collation names. "
            "Then rerun the import for auto-replacement of unsupported collations.\n",
            file=sys.stderr,
        )
        if args.show_summary:
            print(f"Missing mappings ({len(missing)}):", file=sys.stderr)
            for c in sorted(missing):
                print(f"  - {c}", file=sys.stderr)

        if args.report:
            rep = {
                "referenced_collations": sorted(referenced),
                "unsupported_collations": sorted(unsupported),
                "replacements": dict(sorted(replacements.items())),
                "missing_mappings": sorted(missing),
                "invalid_mapping_targets": dict(sorted(invalid_targets.items())),
                "target_supported_collations_count": len(supported),
            }
            os.makedirs(os.path.dirname(args.report) or ".", exist_ok=True)
            with open(args.report, "w", encoding="utf-8", newline="\n") as f:
                json.dump(rep, f, ensure_ascii=False, indent=2)
                f.write("\n")

        return 2

    if args.dry_run:
        if args.show_summary:
            print("=== pre-import.py summary ===")
            print(f"Referenced collations: {len(referenced)}")
            print(f"Unsupported collations: {len(unsupported)}")
            print(f"Replacements planned: {len(replacements)}")
            for s, d in sorted(replacements.items()):
                print(f"  {s} -> {d}")
        return 0

    apply_replacements_stream(args.input, args.output, replacements)

    if args.show_summary:
        print("=== pre-import.py summary ===")
        print(f"Referenced collations: {len(referenced)}")
        print(f"Unsupported collations: {len(unsupported)}")
        print(f"Replacements applied: {len(replacements)}")
        for s, d in sorted(replacements.items()):
            print(f"  {s} -> {d}")

    if args.report:
        rep = {
            "referenced_collations": sorted(referenced),
            "unsupported_collations": sorted(unsupported),
            "replacements": dict(sorted(replacements.items())),
            "missing_mappings": [],
            "invalid_mapping_targets": {},
            "target_supported_collations_count": len(supported),
        }
        os.makedirs(os.path.dirname(args.report) or ".", exist_ok=True)
        with open(args.report, "w", encoding="utf-8", newline="\n") as f:
            json.dump(rep, f, ensure_ascii=False, indent=2)
            f.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
