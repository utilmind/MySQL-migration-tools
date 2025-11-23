#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
strip-mysql-compatibility-comments.py

Copyright (c) 2025 utilmind
All rights reserved.
https://github.com/utilmind/MySQL-Migration-tools/

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

Optionally provide a database name via the --db-name / --db option.
In that case the script will prepend the following lines at
the very top of the output dump:     USE `your_db_name`;

Optionally strip DROP* statements when --no_drop option used.

Usage:
    python strip-mysql-compatibility-comments.py [--no-drop] [--db-name DB_NAME] input.sql output.sql [tables-meta.tsv]
"""

import os
import re
import sys
import argparse


def find_conditional_end(comment):
    """
    Given a string that starts with a versioned comment:

        /*!<digits>...

    find the index of the closing "*/" that terminates THIS comment,
    correctly handling nested regular block comments "/* ... */" inside.

    Returns:
        (end_pos, digits_end)

        end_pos    - index where the closing "*/" starts (or None if not found)
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


def report_progress(processed_bytes, total_size, last):
    """
    Print progress to stderr on a single line using carriage return.
    Returns the updated 'last' value.
    """
    if total_size <= 0:
        percent = 100.0
    else:
        percent = (processed_bytes / float(total_size)) * 100.0

    if percent - last >= 1.0 or percent == 100.0:
        sys.stderr.write("\r{0:5.1f}%...".format(percent))
        sys.stderr.flush()
        return percent

    return last


# --- Table metadata loading and CREATE TABLE enhancement ----------------------


def load_table_metadata(tsv_path):
    """
    Load table metadata from TSV file produced by a query like:

        SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA IN (...);

    Returns:
        (meta, default_schema)

        meta: dict with keys "schema.table" and values:
              {
                  "engine": Optional[str],
                  "row_format": Optional[str],
                  "table_collation": Optional[str]
              }

        default_schema: if all rows share the same TABLE_SCHEMA,
                        this schema name is returned, otherwise None.
    """
    meta = {}
    schemas = set()

    if not os.path.isfile(tsv_path):
        sys.stderr.write(
            "\n[WARN] Table metadata TSV not found: {0}. "
            "CREATE TABLE enhancement will be skipped.\n".format(tsv_path)
        )
        return meta, None

    sys.stderr.write("\nLoading table metadata from '{0}'...\n".format(tsv_path))

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
            key = "{0}.{1}".format(schema, table)

            # Normalize engine
            eng = (engine or "").strip()
            if not eng or eng.upper() == "NULL":
                eng = None

            # Normalize row_format
            rf = (row_format or "").strip()
            if not rf or rf.upper() == "NULL":
                rf = None
            else:
                rf = rf.upper()

            # Normalize collation
            tc = (table_collation or "").strip()
            if not tc or tc.upper() == "NULL":
                tc = None

            meta[key] = {
                "engine": eng,
                "row_format": rf,
                "table_collation": tc,
            }

    default_schema = None
    if len(schemas) == 1:
        default_schema = next(iter(schemas))

    msg = "Loaded metadata for {0} tables".format(len(meta))
    if default_schema:
        msg += " in schema {0!r}".format(default_schema)
    sys.stderr.write(msg + "\n")
    return meta, default_schema


# Precompiled regexes for CREATE TABLE / USE detection
USE_DB_RE = re.compile(r'^\s*USE\s+`([^`]+)`;', re.IGNORECASE)
CREATE_TABLE_RE = re.compile(
    r'^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`([^`]+)`', re.IGNORECASE
)
ENGINE_LINE_RE = re.compile(r'\)\s+ENGINE\s*=', re.IGNORECASE)

# Detect "DROP VIEW IF EXISTS `name`;"
DROP_VIEW_RE = re.compile(
    r'^\s*DROP\s+VIEW\s+IF\s+EXISTS\s+`([^`]+)`;',
    re.IGNORECASE
)

# Generic detection of DROP* statements for optional stripping.
# Matches lines that begin (ignoring leading whitespace) with DROP ...;
# and a special case for versioned comments like "/*!50001 DROP ... */".
DROP_STMT_RE = re.compile(r'^\s*DROP\b', re.IGNORECASE)
VERSIONED_DROP_STMT_RE = re.compile(r'^\s*/\*![0-9]+\s*DROP\b', re.IGNORECASE)

# Normalize "SET time_zone = 'UTC';" to "SET time_zone = '+00:00';"
# Handles arbitrary spaces and one or more semicolons at the end of the line.
TIME_ZONE_UTC_RE = re.compile(
    r'(?im)^(\s*SET\s+time_zone\s*=\s*)([\'"])UTC\2(.*)$'
)


def replace_utc_time_zone(text):
    """
    Replace any standalone "SET time_zone = 'UTC';" statement (with arbitrary
    spacing and one or more semicolons) with "SET time_zone = '+00:00';".

    This is done in a multiline-safe manner and should not affect data payloads,
    because the pattern is anchored to the beginning of the line.
    """
    return TIME_ZONE_UTC_RE.sub(r"\1'+00:00'\3", text)


def enhance_create_table(text, state, table_meta, default_schema):
    """
    Enhance CREATE TABLE statements in the given text chunk using table_meta.

    Skips enhancement for temporary CREATE TABLE emitted before a VIEW:
      DROP VIEW IF EXISTS `v`;
      CREATE TABLE `v` (...);   -- do not touch it

    Only *adds* missing tokens; never removes existing ones
    (AUTO_INCREMENT, COMMENT, STATS_*, etc. are preserved).
    """
    if not table_meta:
        return text

    out_lines = []

    # State fields:
    current_schema = state.get("current_schema") or default_schema
    in_create = state.get("in_create", False)
    current_table = state.get("current_table")
    buffer = state.get("buffer", "")

    # Remember that next CREATE TABLE for this name is a VIEW-shadow
    skip_for_table = state.get("skip_for_table")
    if skip_for_table is None:
        skip_for_table = set()

    def append_chunk(s):
        out_lines.append(s)

    for line in text.splitlines(keepends=True):
        # Track USE `db`;
        m_use = USE_DB_RE.match(line)
        if m_use:
            current_schema = m_use.group(1)

        # Track "DROP VIEW IF EXISTS `x`;"
        m_dv = DROP_VIEW_RE.match(line)
        if m_dv:
            skip_for_table.add(m_dv.group(1))
            append_chunk(line)
            continue

        if not in_create:
            m_create = CREATE_TABLE_RE.match(line)
            if m_create:
                in_create = True
                current_table = m_create.group(1)
                buffer = line
                continue
            else:
                append_chunk(line)
                continue
        else:
            buffer += line
            if ENGINE_LINE_RE.search(line):
                # Got last line of CREATE TABLE
                full = buffer

                # If this CREATE TABLE is the temporary one used for a VIEW — skip enhancement once
                if current_table in skip_for_table:
                    append_chunk(full)
                    skip_for_table.discard(current_table)
                    in_create = False
                    current_table = None
                    buffer = ""
                    continue

                # Resolve metadata key (schema.table)
                schema_to_use = current_schema or default_schema
                if schema_to_use:
                    key = "{0}.{1}".format(schema_to_use, current_table)
                else:
                    # No schema info: try by table name uniqueness
                    matches = [
                        k for k in table_meta.keys()
                        if k.endswith(".{0}".format(current_table))
                    ]
                    if len(matches) == 1:
                        key = matches[0]
                    else:
                        key = None

                info = table_meta.get(key) if key else None

                if info:
                    engine = info["engine"]
                    row_format = info["row_format"]      # None or UPPER
                    table_collation = info["table_collation"]  # may be None

                    # If metadata looks broken — do not inject NULLs; warn and pass through
                    if not engine or not table_collation:
                        sys.stderr.write(
                            "\n[WARN] Missing metadata for {0}: ENGINE={1!r}, "
                            "COLLATION={2!r}. CREATE TABLE kept as-is.\n".format(
                                key or current_table, engine, table_collation
                            )
                        )
                        append_chunk(full)
                    else:
                        # Derive charset from collation: e.g. utf8mb4_general_ci -> utf8mb4
                        charset = table_collation.split("_", 1)[0]

                        # --- augment last line tokens instead of replacing the whole line ---
                        lines = full.splitlines(keepends=True)
                        last_line = lines[-1]

                        close_idx = last_line.find(")")
                        if close_idx == -1:
                            # Degenerate case: just emit as-is
                            append_chunk(full)
                        else:
                            prefix = last_line[:close_idx]   # indentation + ')'
                            rest = last_line[close_idx + 1:]  # tokens part

                            # Parse existing tokens
                            has_engine = re.search(r'\bENGINE\s*=', rest, re.I) is not None
                            has_rowfmt = re.search(r'\bROW_FORMAT\s*=', rest, re.I) is not None
                            has_def_charset = re.search(
                                r'\bDEFAULT\s+CHARSET\s*=', rest, re.I
                            ) is not None
                            has_collate = re.search(
                                r'\bCOLLATE\s*=', rest, re.I
                            ) is not None

                            additions = []

                            if not has_engine:
                                additions.append(" ENGINE={0}".format(engine))
                            if row_format and not has_rowfmt:
                                additions.append(" ROW_FORMAT={0}".format(row_format))
                            if not has_def_charset:
                                additions.append(" DEFAULT CHARSET={0}".format(charset))
                                if not has_collate:
                                    additions.append(" COLLATE={0}".format(table_collation))
                            else:
                                # DEFAULT CHARSET present; add COLLATE if missing
                                if not has_collate:
                                    additions.append(" COLLATE={0}".format(table_collation))

                            # Detect newline at the end
                            nl = ""
                            if rest.endswith("\r\n"):
                                nl = "\r\n"
                                rest_core = rest[:-2]
                            elif rest.endswith("\n"):
                                nl = "\n"
                                rest_core = rest[:-1]
                            else:
                                rest_core = rest

                            # If rest_core already ends with ';', insert additions before it
                            if rest_core.rstrip().endswith(";"):
                                semi_pos = rest_core.rfind(";")
                                new_rest_core = (
                                    rest_core[:semi_pos]
                                    + "".join(additions)
                                    + rest_core[semi_pos:]
                                )
                            else:
                                new_rest_core = rest_core + "".join(additions)

                            new_last_line = "{0}){1}{2}".format(prefix, new_rest_core, nl)
                            lines[-1] = new_last_line
                            full = "".join(lines)
                            append_chunk(full)
                else:
                    # No metadata — keep as-is
                    append_chunk(full)

                # reset CREATE state
                in_create = False
                current_table = None
                buffer = ""

    # Update state
    state["current_schema"] = current_schema
    state["in_create"] = in_create
    state["current_table"] = current_table
    state["buffer"] = buffer
    state["skip_for_table"] = skip_for_table

    return "".join(out_lines)


# --- Main stream processing ---------------------------------------------------


def process_dump_stream(
    in_path,
    out_path,
    version_threshold=80000,
    table_meta=None,
    default_schema=None,
    db_name=None,
    no_drop=False,
):
    """
    Stream-process input dump:

    - write a header line and optional USE `db_name`; at the very top
    - read line by line
    - for each '/*!<digits>' block, read until its matching '*/'
      (across multiple lines, with nested '/* ... */' support)
    - if version < threshold: unwrap (emit only inner content)
    - else: keep the whole comment as-is
    - optionally enhance CREATE TABLE statements using table_meta
    - optionally strip DROP* statements when no_drop is True
    - write everything to out_path
    - print progress to stderr
    """
    if table_meta is None:
        table_meta = {}

    total_size = os.path.getsize(in_path)
    processed_bytes = 0
    last_percent_reported = -1.0

    sys.stderr.write(
        "Removing MySQL compatibility comments from '{0}' ({1:,} bytes)\n"
        "Saving clean dump to '{2}'...\n".format(in_path, total_size, out_path)
    )

    # State for CREATE TABLE enhancement
    create_state = {
        "current_schema": default_schema,
        "in_create": False,
        "current_table": None,
        "buffer": "",
        "skip_for_table": set(),
    }

    def write_out(chunk):
        """Write chunk to fout, optionally enhancing CREATE TABLE,
        normalizing time_zone and, if requested, stripping DROP* statements."""
        if not chunk:
            return
        enhanced = enhance_create_table(chunk, create_state, table_meta, default_schema)
        # Normalize SET time_zone = 'UTC' to SET time_zone = '+00:00'
        enhanced = replace_utc_time_zone(enhanced)

        if no_drop:
            # Split into lines (keeping line endings) and drop any line whose first
            # non-whitespace token is DROP, including versioned comments like
            # "/*!50001 DROP VIEW ... */".
            kept_lines = []
            for line in enhanced.splitlines(True):
                stripped = line.lstrip()
                if not stripped:
                    kept_lines.append(line)
                    continue
                if VERSIONED_DROP_STMT_RE.match(stripped):
                    continue
                if DROP_STMT_RE.match(stripped):
                    continue
                kept_lines.append(line)
            enhanced = "".join(kept_lines)
            if not enhanced:
                return

        fout.write(enhanced)

    with open(in_path, "r", encoding="utf-8", errors="replace") as fin, \
         open(out_path, "w", encoding="utf-8", errors="replace") as fout:

        fout.write(
            "-- Dump created with DB migration tools ( "
            "https://github.com/utilmind/MySQL-migration-tools )\n"
        )

        if db_name:
            # If a database name is provided, also select it explicitly.
            fout.write("\nUSE `{0}`;\n\n".format(db_name))
        else:
            # Just add a blank line separator if no db_name is given.
            fout.write("\n")

        while True:
            line = fin.readline()
            if not line:
                break  # EOF

            processed_bytes += len(line.encode("utf-8", errors="replace"))
            last_percent_reported = report_progress(
                processed_bytes,
                total_size,
                last_percent_reported,
            )

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
                        last_percent_reported = report_progress(
                            total_size,
                            total_size,
                            last_percent_reported,
                        )
                        sys.stderr.write(" done.\n")
                        sys.stderr.flush()
                        return

                    processed_bytes += len(next_line.encode("utf-8", errors="replace"))
                    last_percent_reported = report_progress(
                        processed_bytes,
                        total_size,
                        last_percent_reported,
                    )
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


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Stream-process a MySQL/MariaDB dump: remove versioned compatibility "
            "comments and optionally normalize CREATE TABLE statements using table metadata."
        )
    )
    parser.add_argument(
        "--db-name",
        "--db",
        dest="db_name",
        help=(
            "Optional database name to prepend a 'USE `DB_NAME`;' statement at the "
            "top of the output dump."
        ),
    )
    parser.add_argument(
        "--no-drop",
        action="store_true",
        dest="no_drop",
        help=(
            "If set, strip any DROP* statements from the output, including "
            "versioned comments like '/*!50001 DROP ... */'."
        ),
    )
    parser.add_argument(
        "input",
        help="Path to the input SQL dump file.",
    )
    parser.add_argument(
        "output",
        help="Path to the output (processed) SQL dump file.",
    )
    parser.add_argument(
        "tables_meta",
        nargs="?",
        default=None,
        help=(
            "Optional TSV file with table metadata "
            "(TABLE_SCHEMA, TABLE_NAME, ENGINE, ROW_FORMAT, TABLE_COLLATION)."
        ),
    )

    args = parser.parse_args()

    in_path = args.input
    out_path = args.output
    tsv_path = args.tables_meta
    db_name = args.db_name
    no_drop = bool(args.no_drop)

    if not os.path.isfile(in_path):
        print("Input file not found: {0}".format(in_path), file=sys.stderr)
        sys.exit(1)

    table_meta = {}
    default_schema = None

    if tsv_path is not None:
        table_meta, default_schema = load_table_metadata(tsv_path)

    process_dump_stream(
        in_path,
        out_path,
        version_threshold=80000,
        table_meta=table_meta,
        default_schema=default_schema,
        db_name=db_name,
        no_drop=no_drop,
    )


if __name__ == "__main__":
    main()
