#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
post-process-dump.py

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

Additionally:
  * Optionally, if a table metadata TSV is provided, normalize
    CREATE TABLE using metadata from information_schema.TABLES
    (ENGINE, ROW_FORMAT, DEFAULT CHARSET and COLLATE), according
    to the original server metadata extracted from information_schema.TABLES.

  * Optionally provide a database name via the --db-name / --db option.
    In that case the script will prepend the following lines at
    the very top of the output dump:     USE `your_db_name`;

  * Optionally prepend an extra SQL file.

  * Optionally skip DROP TABLE / DROP DATABASE when --no-drop option used.

  * Replace standalone `SET time_zone = 'UTC';` → `SET time_zone = '+00:00';`.

Usage:
    python strip-mysql-compatibility-comments.py \
        [--no-drop] [--db-name DB_NAME] [--prepend-file FILE] \
        input.sql output.sql [tables-meta.tsv]
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


def dump_has_use_statement(path):
    """
    Return True if the input dump selects a database via a 'USE `db`;' statement
    *before* any CREATE TABLE statement.

    The file is scanned line by line and stops as soon as a relevant statement
    is found, so it does not need to read the entire dump for this check.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                # A USE statement before any DDL means the dump is already safe.
                if USE_DB_RE.search(line):
                    return True
                # If we see a CREATE/DROP TABLE first, then there is no selected
                # database yet, and such statements would fail on import.
                if CREATE_TABLE_RE.search(line):
                    return False
    except OSError:
        # If we cannot read the file here, main() will fail later anyway.
        return False
    # No USE and no relevant DDL found; treat as "no database selected".
    return False


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


# --- DDL reproducibility helpers ---------------------------------------------
#
# When generating schema-only ("DDL") dumps for version control, we want the output
# to be stable if the real schema did not change. Unfortunately, mysqldump embeds
# a few volatile pieces of information:
#   * AUTO_INCREMENT=<current value> in CREATE TABLE options
#   * a trailing comment like: "-- Dump completed on YYYY-MM-DD HH:MM:SS"
#
# The helpers below normalize those volatile pieces so that repeated dumps produce
# identical output and Git diffs show only real DDL changes.

# Normalize AUTO_INCREMENT to a deterministic value (0) for diff-friendly DDL.
AUTO_INCREMENT_RE = re.compile(r"\bAUTO_INCREMENT=\d+\b", re.IGNORECASE)

# Normalize the trailing completion comment emitted by mysqldump.
DUMP_COMPLETED_ON_RE = re.compile(r"(?m)^--\s+Dump\s+completed\s+on\s+.*$")

def sanitize_ddl_for_reproducibility(text):
    """
    Normalize volatile parts of a schema-only dump so Git diffs are meaningful.

    Rules:
      - Replace any 'AUTO_INCREMENT=<number>' with 'AUTO_INCREMENT=0'
      - Replace '-- Dump completed on <timestamp>' with '-- Dump completed.'

    Note: This function is intended for schema-only dumps. It is NOT enabled by
    default for full data dumps, because altering comment lines in data dumps can
    make debugging harder (even though it is generally safe).
    """
    if not text:
        return text
    text = AUTO_INCREMENT_RE.sub("AUTO_INCREMENT=0", text)
    text = DUMP_COMPLETED_ON_RE.sub("-- Dump completed.", text)
    return text


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
    prepend_file=None,
    ddl=False,
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
    - optionally sanitize volatile DDL parts (AUTO_INCREMENT, completion timestamp) when ddl is True
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
        "Removing MySQL compatibility comments from '{0}' ({1:,} bytes)...\n".format(in_path, total_size)
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
        normalizing time_zone, optionally sanitizing DDL for reproducibility,
        and, if requested, stripping DROP* statements."""
        if not chunk:
            return
        enhanced = enhance_create_table(chunk, create_state, table_meta, default_schema)
        # Normalize SET time_zone = 'UTC' to SET time_zone = '+00:00'
        enhanced = replace_utc_time_zone(enhanced)

        # If --ddl is enabled, normalize volatile DDL parts like AUTO_INCREMENT values
        # and mysqldump completion timestamps to keep schema dumps deterministic.
        if ddl:
            enhanced = sanitize_ddl_for_reproducibility(enhanced)

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
            "https://github.com/utilmind/MySQL-migration-tools )\n\n"
        )

        # Optionally prepend external SQL file right after the header line
        if prepend_file:
            sys.stderr.write(
                "Prepending file '{0}' at the top of the dump...\n".format(prepend_file)
            )
            with open(prepend_file, "r", encoding="utf-8", errors="replace") as pf:
                prepend_content = pf.read()
            if prepend_content:
                fout.write(prepend_content)
                # Ensure the prepend block ends with a newline
                if not prepend_content.endswith(("\n", "\r")):
                    fout.write("\n")
                fout.write("\n")  # extra separator after prepend block

        if db_name:
            # If a database name is provided, also select it explicitly.
            fout.write("\nUSE `{0}`;\n\n".format(db_name))

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
                    # Unwrap: emit only the inner content.
                    #
                    # Important: mysqldump often places the terminating semicolon *after* the
                    # versioned comment, e.g. "/*!50001 VIEW ... */;". When we unwrap, that
                    # semicolon becomes a standalone line in the output, which creates noisy diffs.
                    # To keep output stable, we "re-attach" a single leading semicolon from the
                    # tail back to the unwrapped inner statement.
                    if tail.startswith(";"):
                        # mysqldump often puts the terminator semicolon after the closing '*/' of
                        # a versioned comment, e.g. "/*!50001 CREATE VIEW ... */;".
                        #
                        # When we unwrap the comment, that semicolon becomes part of `tail`.
                        # A naive `inner + ";"` can accidentally create a standalone ';' line when
                        # `inner` ends with a newline. To keep output deterministic and idempotent,
                        # we attach exactly one leading ';' to the end of the last non-whitespace
                        # character in `inner`, preserving trailing whitespace/newlines.
                        def _attach_leading_semicolon(inner_sql: str) -> str:
                            # Preserve trailing whitespace/newlines exactly as-is.
                            m_ws = re.search(r"(\s*)\Z", inner_sql)
                            trailing_ws = m_ws.group(1) if m_ws else ""
                            body = inner_sql[: len(inner_sql) - len(trailing_ws)] if trailing_ws else inner_sql

                            # If the body already ends with ';', return unchanged.
                            if body.rstrip().endswith(";"):
                                return inner_sql

                            return body + ";" + trailing_ws

                        if inner.rstrip().endswith(";"):
                            # Inner already ends with a semicolon; just drop one from the tail.
                            tail = tail[1:]
                            # Normalize possible blank line after consuming the semicolon.
                            # mysqldump may output "*/;\n\nSET ..." (semicolon terminator plus an empty line).
                            # After consuming ';', `tail` begins with a blank line, which can toggle across runs.
                            # If we have 2+ leading newlines, drop exactly one.
                            if inner.endswith("\n") and (tail.startswith("\n\n") or tail.startswith("\r\n\r\n")):
                                tail = tail[1:] if tail.startswith("\n\n") else tail[len("\r\n"):]
                            write_out(inner)
                        else:
                            # Move one semicolon from tail into the inner statement in a safe way.
                            write_out(_attach_leading_semicolon(inner))
                            tail = tail[1:]
                            # Normalize possible blank line after consuming the semicolon (see above).
                            if inner.endswith("\n") and (tail.startswith("\n\n") or tail.startswith("\r\n\r\n")):
                                tail = tail[1:] if tail.startswith("\n\n") else tail[len("\r\n"):]
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
            "top of the output dump. If not provided and the input dump does not "
            "contain any USE statement, you will be prompted for a database name "
            "when running in an interactive terminal."
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
        "--ddl",
        action="store_true",
        dest="ddl",
        help=(
            "Enable DDL reproducibility mode: set all AUTO_INCREMENT values to 0 "
            "and remove mysqldump completion timestamps (e.g. '-- Dump completed on ...'). "
            "Intended for schema-only dumps committed to version control."
        ),
    )
    parser.add_argument(
        "--prepend-file",
        dest="prepend_file",
        help=(
            "Optional SQL file to prepend right after the standard header "
            "in the output dump."
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
    prepend_file = args.prepend_file
    ddl = bool(getattr(args, 'ddl', False))

    if not out_path:
        print(
            "Output file path is empty. "
            "Make sure the second positional argument is a valid file path.",
            file=sys.stderr,
        )
        sys.exit(1)

    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.isdir(out_dir):
        print(
            "Directory for output file does not exist: {0}".format(out_dir),
            file=sys.stderr,
        )
        sys.exit(1)

    if not os.path.isfile(in_path):
        print("Input file not found: {0}".format(in_path), file=sys.stderr)
        sys.exit(1)

    # If no explicit db_name is provided, check whether the dump already selects
    # a database via a USE `db`; statement. If it does not, we may ask the user
    # which database should be used (interactive mode only).
    if not db_name:
        has_use = dump_has_use_statement(in_path)
        if not has_use:
            if sys.stdin.isatty():
                # Explain the situation to the user (to stderr, to not pollute stdout).
                sys.stderr.write(
                    "This dump does not select any database.\n"
                    "Please provide a database name to import data into a specific database.\n"
                    "Or leave it blank and press Enter if you want to skip database selection.\n"
                )
                try:
                    user_db = input("Database name (leave blank to skip): ").strip()
                except EOFError:
                    user_db = ""
                if user_db:
                    db_name = user_db
            else:
                # Non-interactive mode (e.g. cron): just continue without a USE header.
                sys.stderr.write(
                    "No USE statement found in the dump and no --db-name was provided. "
                    "Standard input is not interactive; continuing without selecting a database.\n"
                )


    if prepend_file is not None and not os.path.isfile(prepend_file):
        print(
            "Prepend file not found: {0}".format(prepend_file),
            file=sys.stderr,
        )
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
        prepend_file=prepend_file,
        ddl=ddl,
    )


if __name__ == "__main__":
    main()
