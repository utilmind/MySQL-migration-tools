#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
strip-mysql-compatibility-comments.py

Stream-process a large MySQL/MariaDB dump and remove versioned
compatibility comments of the form:

    /*!<digits> ... */

for versions earlier than MySQL 8.0 (i.e. version number < 80000).

Everything else is written as-is, including regular code comments:

    /* comment inside of the trigger */
    -- some comment
    # another comment

The script never loads the whole file into memory.
It reads line by line and only keeps one versioned comment block
in memory at a time.

Optionally, if a table metadata TSV is provided, it will also
normalize CREATE TABLE statements to include ENGINE, ROW_FORMAT,
DEFAULT CHARSET and COLLATE according to the original server
metadata extracted from information_schema.TABLES.

Usage:
    python strip-mysql-compatibility-comments.py input.sql output.sql
    python strip-mysql-compatibility-comments.py input.sql output.sql tables-meta.tsv
"""

import os
import re
import sys
from typing import Tuple, Optional, Dict, Any


def find_conditional_end(comment: str) -> Tuple[Optional[int], Optional[int]]:
    """
    Given a string that starts with a versioned comment:

        /*!<digits>...

    find the index of the closing "*/" that terminates THIS comment,
    correctly handling nested regular block comments "/* ... */" inside.

    Returns:
        (end_pos, digits_end)

        end_pos   - index where the closing "*/" starts (or None if not found)
        digits_end - index right after the version digits (i.e. start of inner content)
    """
    n = len(comment)
    # comment[0:3] should be "/*!"
    j = 3
    while j < n and comment[j].isdigit():
        j += 1
    digits_end = j
    version_str = comment[3:digits_end]
    if not version_str:
        return None, None

    depth = 0
    k = digits_end
    end_pos = None

    while k < n - 1:
        two = comment[k:k + 2]

        if two == "/*":
            # nested regular block comment
            depth += 1
            k += 2
            continue

        if two == "*/":
            if depth == 0:
                end_pos = k
                break
            else:
                depth -= 1
                k += 2
                continue

        k += 1

    return end_pos, digits_end


def report_progress(processed_bytes: int, total_size: int, last: float) -> float:
    """
    Print progress to stderr on a single line using carriage return.
    Returns the updated 'last' value.
    """
    if total_size <= 0:
        percent = 100.0
    else:
        percent = (processed_bytes / total_size) * 100

    if percent - last >= 1.0 or percent == 100.0:
        sys.stderr.write(f"\r{percent:5.1f}%...")
        sys.stderr.flush()
        return percent

    return last


# --- NEW: table metadata loading and CREATE TABLE enhancement -----------------


def load_table_metadata(tsv_path: str) -> Tuple[Dict[str, Dict[str, Any]], Optional[str]]:
    """
    Load table metadata from TSV file produced by a query like:

        SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA IN (...);

    Returns:
        (meta, default_schema)

        meta: dict with keys "schema.table" and values:
              {
                  "engine": str,
                  "row_format": Optional[str],
                  "table_collation": str
              }

        default_schema: if all rows share the same TABLE_SCHEMA,
                        this schema name is returned, otherwise None.
    """
    meta: Dict[str, Dict[str, Any]] = {}
    schemas = set()

    if not os.path.isfile(tsv_path):
        sys.stderr.write(f"\n[WARN] Table metadata TSV not found: {tsv_path}. "
                         f"CREATE TABLE enhancement will be skipped.\n")
        return meta, None

    sys.stderr.write(f"\nLoading table metadata from '{tsv_path}'...\n")

    with open(tsv_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n\r")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 5:
                continue

            schema, table, engine, row_format, table_collation = parts[:5]

            schemas.add(schema)
            key = f"{schema}.{table}"

            rf = row_format.strip()
            if not rf or rf.upper() == "NULL":
                rf = None
            else:
                rf = rf.upper()

            meta[key] = {
                "engine": engine,
                "row_format": rf,
                "table_collation": table_collation,
            }

    default_schema = None
    if len(schemas) == 1:
        default_schema = next(iter(schemas))

    sys.stderr.write(f"Loaded metadata for {len(meta)} tables"
                     f"{' in schema ' + default_schema if default_schema else ''}.\n")
    return meta, default_schema


# Precompiled regexes for CREATE TABLE / USE detection
USE_DB_RE = re.compile(r'^\s*USE\s+`([^`]+)`;', re.IGNORECASE)
CREATE_TABLE_RE = re.compile(
    r'^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`([^`]+)`', re.IGNORECASE
)
ENGINE_LINE_RE = re.compile(r'\)\s+ENGINE\s*=', re.IGNORECASE)


def enhance_create_table(
    text: str,
    state: Dict[str, Any],
    table_meta: Dict[str, Dict[str, Any]],
    default_schema: Optional[str],
) -> str:
    """
    Enhance CREATE TABLE statements in the given text chunk using table_meta.

    The function tracks:
      - current_schema (via USE `db`;)
      - multi-line CREATE TABLE blocks
      - final line starting with ') ENGINE=...'

    When a full CREATE TABLE is buffered, it rewrites the last line
    to include ENGINE, ROW_FORMAT, DEFAULT CHARSET and COLLATE based
    on information_schema.TABLES metadata.

    If table_meta is empty, the text is returned unchanged.
    """
    if not table_meta:
        return text

    out_lines = []

    # State fields:
    #  state["current_schema"]: current database (from USE)
    #  state["in_create"]: bool
    #  state["current_table"]: str or None
    #  state["buffer"]: str (accumulated CREATE TABLE block)
    current_schema = state.get("current_schema") or default_schema
    in_create = state.get("in_create", False)
    current_table = state.get("current_table")
    buffer = state.get("buffer", "")

    # Process line by line to keep semantics simple
    for line in text.splitlines(keepends=True):
        # Track USE `db`;
        m_use = USE_DB_RE.match(line)
        if m_use:
            current_schema = m_use.group(1)

        if not in_create:
            m_create = CREATE_TABLE_RE.match(line)
            if m_create:
                # Start of CREATE TABLE
                in_create = True
                current_table = m_create.group(1)
                buffer = line
                continue  # do not emit line yet
            else:
                out_lines.append(line)
                continue
        else:
            # Already inside CREATE TABLE block
            buffer += line
            if ENGINE_LINE_RE.search(line):
                # This is the last line of CREATE TABLE (ENGINE=...)
                schema_to_use = current_schema or default_schema

                full = buffer
                if schema_to_use:
                    key = f"{schema_to_use}.{current_table}"
                else:
                    # No schema info: try all schemas for this table name
                    matches = [k for k in table_meta.keys()
                               if k.endswith(f".{current_table}")]
                    key = matches[0] if len(matches) == 1 else None

                info = table_meta.get(key) if key else None

                if info:
                    engine = info["engine"]
                    row_format = info["row_format"]
                    table_collation = info["table_collation"]

                    # Derive charset from collation: e.g. utf8mb4_general_ci -> utf8mb4
                    charset = table_collation.split("_", 1)[0]

                    # Rebuild the last line of CREATE TABLE
                    lines = full.splitlines(keepends=True)
                    last_line = lines[-1]

                    # Preserve indentation before ')'
                    close_idx = last_line.find(")")
                    if close_idx == -1:
                        indent = ""
                        newline = "\n"
                    else:
                        indent = last_line[:close_idx]
                        # Detect newline style
                        if last_line.endswith("\r\n"):
                            newline = "\r\n"
                        elif last_line.endswith("\n"):
                            newline = "\n"
                        else:
                            newline = ""

                    parts = [f"{indent}) ENGINE={engine}"]
                    if row_format:
                        parts.append(f" ROW_FORMAT={row_format}")
                    parts.append(f" DEFAULT CHARSET={charset} COLLATE={table_collation};")
                    new_last_line = "".join(parts) + newline

                    lines[-1] = new_last_line
                    full = "".join(lines)

                # Emit the full CREATE TABLE (modified or original)
                out_lines.append(full)

                # Reset CREATE TABLE state
                in_create = False
                current_table = None
                buffer = ""
            # else: still inside CREATE, keep accumulating

    # Update state
    state["current_schema"] = current_schema
    state["in_create"] = in_create
    state["current_table"] = current_table
    state["buffer"] = buffer

    return "".join(out_lines)


# --- Main stream processing ---------------------------------------------------


def process_dump_stream(
    in_path: str,
    out_path: str,
    version_threshold: int = 80000,
    table_meta: Optional[Dict[str, Dict[str, Any]]] = None,
    default_schema: Optional[str] = None,
) -> None:
    """
    Stream-process input dump:

    - read line by line
    - for each '/*!<digits>' block, read until its matching '*/'
      (across multiple lines, with nested '/* ... */' support)
    - if version < threshold: unwrap (emit only inner content)
    - else: keep the whole comment as-is
    - optionally enhance CREATE TABLE statements using table_meta
    - write everything to out_path
    - print progress to stderr
    """
    if table_meta is None:
        table_meta = {}

    total_size = os.path.getsize(in_path)
    processed_bytes = 0
    last_percent_reported = -1.0

    sys.stderr.write(
        f"Removing MySQL compatibility comments from '{in_path}' "
        f"({total_size:,} bytes) and saving clean dump to '{out_path}'...\n"
    )

    # State for CREATE TABLE enhancement
    create_state: Dict[str, Any] = {
        "current_schema": default_schema,
        "in_create": False,
        "current_table": None,
        "buffer": "",
    }

    def write_out(chunk: str) -> None:
        """Write chunk to fout, optionally enhancing CREATE TABLE."""
        if not chunk:
            return
        enhanced = enhance_create_table(chunk, create_state, table_meta, default_schema)
        fout.write(enhanced)

    with open(in_path, "r", encoding="utf-8", errors="replace") as fin, \
         open(out_path, "w", encoding="utf-8", errors="replace") as fout:

        while True:
            line = fin.readline()
            if not line:
                break  # EOF

            processed_bytes += len(line.encode("utf-8", errors="replace"))
            last_percent_reported = report_progress(processed_bytes, total_size, last_percent_reported)

            # We may modify 'line' as we consume versioned comments
            pos = 0
            while True:
                idx = line.find("/*!", pos)
                if idx == -1:
                    # No more versioned comments in this line/tail
                    write_out(line[pos:])
                    break

                # Check that we actually have digits after /*! (versioned comment)
                j = idx + 3
                while j < len(line) and line[j].isdigit():
                    j += 1
                if j == idx + 3:
                    # Not a "/*!<digits>" pattern; treat as normal text up to "/*!"
                    write_out(line[pos:idx + 3])
                    pos = idx + 3
                    continue

                # We have '/*!<digits>' starting at idx.
                # Collect the full comment block (which may span multiple lines).
                comment = line[idx:]

                while True:
                    end_pos, digits_end = find_conditional_end(comment)
                    if end_pos is not None:
                        break

                    # Need more data (comment not closed yet)
                    next_line = fin.readline()
                    if not next_line:
                        # EOF inside comment - just output what we have and exit
                        write_out(line[pos:idx])
                        write_out(comment)
                        # ensure final progress
                        last_percent_reported = report_progress(total_size, total_size, last_percent_reported)
                        sys.stderr.write(" done.\n")
                        sys.stderr.flush()
                        return

                    processed_bytes += len(next_line.encode("utf-8", errors="replace"))
                    last_percent_reported = report_progress(processed_bytes, total_size, last_percent_reported)
                    comment += next_line

                # At this point we have a full '/*!<digits> ... */' in 'comment'
                version_str = comment[3:digits_end]
                try:
                    version = int(version_str)
                except ValueError:
                    version = 0

                inner = comment[digits_end:end_pos]   # content inside the comment
                tail = comment[end_pos + 2:]          # what follows after '*/' (could be ';;' etc.)

                # Write everything before the comment from the original 'line'
                write_out(line[pos:idx])

                # Decide whether to unwrap or keep the comment
                if version < version_threshold:
                    # Unwrap: emit only the inner content
                    write_out(inner)
                else:
                    # Keep the whole comment block as-is
                    write_out(comment[:end_pos + 2])

                # Now we continue processing the tail of the comment
                line = tail
                pos = 0

    # Final 100% report and newline
    last_percent_reported = report_progress(total_size, total_size, last_percent_reported)
    sys.stderr.write(" done.\n")
    sys.stderr.flush()


def main() -> None:
    if len(sys.argv) not in (3, 4):
        print(
            "Usage:\n"
            "  python strip-mysql-compatibility-comments.py input.sql output.sql\n"
            "  python strip-mysql-compatibility-comments.py input.sql output.sql tables-meta.tsv",
            file=sys.stderr,
        )
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2]
    tsv_path = sys.argv[3] if len(sys.argv) == 4 else None

    if not os.path.isfile(in_path):
        print(f"Input file not found: {in_path}", file=sys.stderr)
        sys.exit(1)

    table_meta: Dict[str, Dict[str, Any]] = {}
    default_schema: Optional[str] = None

    if tsv_path is not None:
        table_meta, default_schema = load_table_metadata(tsv_path)

    process_dump_stream(
        in_path,
        out_path,
        version_threshold=80000,
        table_meta=table_meta,
        default_schema=default_schema,
    )


if __name__ == "__main__":
    main()
