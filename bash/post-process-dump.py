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

    depth = 1  # we are inside one block comment already
    i = j
    while i < n - 1:
        pair = comment[i : i + 2]
        if pair == "/*":
            depth += 1
            i += 2
            continue
        if pair == "*/":
            depth -= 1
            if depth == 0:
                return i, digits_end
            i += 2
            continue
        i += 1

    return None, digits_end


def strip_version_from_comment_text(comment):
    """
    Given the full content of a versioned comment string that begins
    with "/*!<digits>", return the inner content with:

      1) The leading '/*!<digits>' removed
      2) The trailing '*/' removed

    and preserving everything else (including nested comments, etc.).
    """
    if not comment.startswith("/*!"):
        return comment

    end_pos, digits_end = find_conditional_end(comment)
    if end_pos is None:
        return comment

    inner = comment[digits_end:end_pos]
    return inner


def extract_version_number(comment):
    """
    Extract leading digits from a "/*!<digits>" comment.

    For example:
        "/*!40101 SET ..." -> 40101
        "/*!80000 CREATE ..." -> 80000

    If no digits found, return None.
    """
    if not comment.startswith("/*!"):
        return None

    i = 3
    n = len(comment)
    while i < n and comment[i].isdigit():
        i += 1
    digits = comment[3:i]
    if not digits:
        return None
    return int(digits)


def find_matching_paren(s, start_index):
    """
    Given a string `s` and an index `start_index` such that s[start_index]
    is an opening parenthesis '(', find the index of the matching closing
    parenthesis ')', taking into account nested parentheses.

    Returns:
        index of the matching ')' or None if not found.
    """
    depth = 0
    for i in range(start_index, len(s)):
        c = s[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
    return None


def parse_qualified_table_name(token):
    """
    Parse a qualified table name of the form:

        `schema`.`table`
        schema.table
        table

    and return (schema_name, table_name).

    The backticks may be present or absent. We also handle a single
    backtick-wrapped identifier like `table` as (None, "table").

    Examples:
        "mydb.mytable"         -> ("mydb", "mytable")
        "`mydb`.`mytable`"     -> ("mydb", "mytable")
        "mytable"              -> (None, "mytable")
        "`weird-db`.`t-1`"     -> ("weird-db", "t-1")
    """
    token = token.strip()

    m = re.match(r"^`([^`]+)`\.`([^`]+)`$", token)
    if m:
        return m.group(1), m.group(2)

    m = re.match(r"^`([^`]+)`$", token)
    if m:
        return None, m.group(1)

    if "." in token:
        parts = token.split(".", 1)
        schema = parts[0].strip("`")
        table = parts[1].strip("`")
        return schema, table

    return None, token.strip("`")


def apply_table_options(create_stmt, tbl_meta, use_ddl_collate=True):
    """
    Given a full CREATE TABLE statement (excluding the trailing semicolon),
    and a table metadata dict with keys:

        ENGINE          - e.g. "InnoDB"
        ROW_FORMAT      - e.g. "Compact", "Dynamic", or "Fixed", etc.
        TABLE_COLLATION - e.g. "utf8mb4_unicode_ci"

    produce a normalized CREATE TABLE statement that includes:

        ENGINE=<value>
        ROW_FORMAT=<value>
        COLLATE=<value>

    if they are not already explicitly present in the CREATE statement.
    """
    engine = tbl_meta.get("ENGINE")
    row_format = tbl_meta.get("ROW_FORMAT")
    table_collation = tbl_meta.get("TABLE_COLLATION")

    stmt_up = create_stmt.upper()
    engine_present = " ENGINE=" in stmt_up
    row_format_present = " ROW_FORMAT=" in stmt_up
    collate_present = " COLLATE=" in stmt_up

    def _ensure_option(statement, key, value):
        if not value:
            return statement

        upper_stmt = statement.upper()
        key_pattern = f" {key}="

        if key_pattern not in upper_stmt:
            return statement + f" {key}={value}"

        pattern = re.compile(rf"({key_pattern})(\S+)", flags=re.IGNORECASE)
        new_statement = pattern.sub(
            rf"\1{value}",
            statement,
            count=1,
        )
        return new_statement

    new_stmt = create_stmt

    if engine and not engine_present:
        new_stmt = _ensure_option(new_stmt, "ENGINE", engine)
        stmt_up = new_stmt.upper()

    if row_format and not row_format_present:
        new_stmt = _ensure_option(new_stmt, "ROW_FORMAT", row_format)
        stmt_up = new_stmt.upper()

    if use_ddl_collate and table_collation and not collate_present:
        coll = table_collation
        if "_" in coll:
            charset = coll.split("_", 1)[0]
        else:
            charset = None

        if charset:
            if " CHARACTER SET " not in stmt_up and "CHARSET=" not in stmt_up:
                new_stmt = new_stmt + f" DEFAULT CHARACTER SET {charset}"
            stmt_up = new_stmt.upper()

        new_stmt = _ensure_option(new_stmt, "COLLATE", coll)

    return new_stmt


def load_table_metadata(tsv_path):
    """
    Load table metadata from a TSV file with columns:

        TABLE_SCHEMA    - database (schema) name
        TABLE_NAME      - table name
        ENGINE
        ROW_FORMAT
        TABLE_COLLATION

    Returns:
        (table_meta, default_schema)

        table_meta     dict keyed by (schema, table_name) with small dict values
        default_schema string or None
    """
    table_meta = {}
    default_schema = None

    if tsv_path is None:
        return table_meta, default_schema

    with open(tsv_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 5:
                continue
            schema, table, engine, row_format, coll = parts[:5]

            if default_schema is None and schema and schema.lower() not in (
                "information_schema",
                "performance_schema",
                "mysql",
                "sys",
            ):
                default_schema = schema

            table_meta[(schema, table)] = {
                "ENGINE": engine or None,
                "ROW_FORMAT": row_format or None,
                "TABLE_COLLATION": coll or None,
            }

    return table_meta, default_schema


def normalize_create_table(stmt, table_meta, default_schema=None):
    """
    Try to detect CREATE TABLE and fill in ENGINE, ROW_FORMAT and COLLATE
    using the provided metadata.
    """
    stripped = stmt.strip()
    upper_stmt = stripped.upper()
    if not upper_stmt.startswith("CREATE TABLE"):
        return stmt

    m = re.match(
        r"(?is)CREATE\s+TABLE\s+(.+?)\s*\(",
        stripped,
    )
    if not m:
        return stmt

    table_token = m.group(1).strip()
    schema, table = parse_qualified_table_name(table_token)

    if schema is None:
        schema = default_schema

    if not table:
        return stmt

    key = (schema, table)
    tbl_meta = table_meta.get(key)
    if not tbl_meta:
        return stmt

    before_paren_index = stripped.upper().find(table_token.upper())
    if before_paren_index == -1:
        return apply_table_options(stripped, tbl_meta)

    open_paren_index = stripped.find("(", before_paren_index + len(table_token))
    if open_paren_index == -1:
        return apply_table_options(stripped, tbl_meta)

    close_paren_index = find_matching_paren(stripped, open_paren_index)
    if close_paren_index is None:
        return apply_table_options(stripped, tbl_meta)

    new_stmt = apply_table_options(stripped, tbl_meta)
    return new_stmt


def remove_time_zone_utc_literal(stmt):
    """
    Replace:

        SET time_zone = 'UTC';

    with:

        SET time_zone = '+00:00';

    when it appears as a standalone statement (ignoring whitespace).
    """
    stripped = stmt.strip().rstrip(";")

    upper_line = stripped.upper()
    if upper_line == "SET TIME_ZONE = 'UTC'":
        return "SET time_zone = '+00:00';"

    if upper_line == "SET TIME_ZONE = '+00:00'":
        return stripped + ";"

    return stmt


def process_dump_stream(
    in_path,
    out_path,
    version_threshold=80000,
    table_meta=None,
    default_schema=None,
    db_name=None,
    no_drop=False,
    prepend_file=None,
):
    """
    Single-pass stream-processing:

      1) Optionally write USE `db_name`; and prepend_file to out_path.
      2) Read the input dump once, chunk by chunk.
      3) Inside each chunk:
           - Remove legacy versioned comments /*!<digits> ... */
             (for versions < version_threshold), preserving important SQL.
           - Feed cleaned text into a statement builder that:
               * Splits on ';' boundaries,
               * Applies no_drop / time_zone fix / normalize_create_table,
               * Writes final SQL to out_path.
      4) At the end, flush the remaining partial statement (if any).
    """
    if table_meta is None:
        table_meta = {}

    file_size = os.path.getsize(in_path)
    tenth = max(file_size // 100, 1)

    with open(in_path, "r", encoding="utf-8", errors="replace") as fin, open(
        out_path,
        "w",
        encoding="utf-8",
        errors="replace",
    ) as fout:
        # Optional "USE `db_name`;"
        if db_name:
            fout.write(f"USE `{db_name}`;\n\n")

        # Optional prepend file (e.g. users & grants)
        if prepend_file:
            with open(prepend_file, "r", encoding="utf-8", errors="replace") as pf:
                prepend_content = pf.read()
            fout.write(prepend_content)
            if prepend_content and not prepend_content.endswith("\n"):
                fout.write("\n")

        # --- State for comment removal ---
        buffer = []
        in_version_comment = False
        in_regular_comment = False
        nested_comment_depth = 0

        # --- State for statement assembly on cleaned SQL ---
        stmt_buffer = []

        def emit_statement(stmt):
            """
            Apply all statement-level transformations and write to fout.
            """
            if not stmt:
                return

            # Optionally skip DROP statements
            if no_drop:
                upper = stmt.strip().upper()
                if upper.startswith("DROP TABLE") or upper.startswith("DROP DATABASE"):
                    return

            # Fix time zone literal if needed
            stmt2 = remove_time_zone_utc_literal(stmt)

            # Normalize CREATE TABLE using metadata
            upper_stmt = stmt2.strip().upper()
            if upper_stmt.startswith("CREATE TABLE"):
                stmt_no_semicolon = stmt2.rstrip().rstrip(";")
                stmt_no_semicolon = normalize_create_table(
                    stmt_no_semicolon,
                    table_meta,
                    default_schema=default_schema,
                )
                stmt2 = stmt_no_semicolon + ";\n"

            fout.write(stmt2)

        def handle_clean_text(text):
            """
            Accept a chunk of already-cleaned SQL text (without legacy comments),
            accumulate it into stmt_buffer, and whenever we see ';',
            emit full statements.
            """
            nonlocal stmt_buffer
            if not text:
                return

            stmt_buffer.append(text)
            buf = "".join(stmt_buffer)

            while True:
                idx = buf.find(";")
                if idx == -1:
                    break
                # Statement includes the semicolon
                stmt = buf[: idx + 1]
                emit_statement(stmt)
                buf = buf[idx + 1 :]

            stmt_buffer = [buf] if buf else []

        def flush_buffer():
            """
            Flush the comment-removal buffer into the statement builder.
            """
            if buffer:
                handle_clean_text("".join(buffer))
                buffer.clear()

        processed_bytes = 0
        last_progress = 0

        print(
            "Removing MySQL compatibility comments from '{0}' ({1:,} bytes)...".format(
                in_path, file_size
            )
        )

        # --- Main streaming loop: remove comments + build statements ---
        while True:
            chunk = fin.read(8192)
            if not chunk:
                break

            processed_bytes += len(chunk)

            while chunk:
                if not in_version_comment and not in_regular_comment:
                    idx = chunk.find("/*")
                    if idx == -1:
                        buffer.append(chunk)
                        break

                    buffer.append(chunk[:idx])
                    rest = chunk[idx:]

                    if rest.startswith("/*!"):
                        end_pos, _ = find_conditional_end(rest)

                        if end_pos is None:
                            # Legacy comment not closed in this chunk, keep text
                            # (we will handle at the next chunk).
                            in_version_comment = True
                            buffer.append(rest)
                            chunk = ""
                        else:
                            comment = rest[: end_pos + 2]
                            remainder = rest[end_pos + 2 :]

                            version_number = extract_version_number(comment)
                            if (
                                version_number is not None
                                and version_number < version_threshold
                            ):
                                inner = strip_version_from_comment_text(comment)
                                buffer.append(inner)
                            else:
                                buffer.append(comment)

                            chunk = remainder
                    else:
                        # Regular /* ... */ block comment (non-versioned)
                        end_pos = rest.find("*/")
                        if end_pos == -1:
                            in_regular_comment = True
                            nested_comment_depth = 1
                            buffer.append(rest)
                            chunk = ""
                        else:
                            buffer.append(rest[: end_pos + 2])
                            chunk = rest[end_pos + 2 :]

                elif in_version_comment:
                    # Continue until we see the closing "*/"
                    end_pos = chunk.find("*/")
                    if end_pos == -1:
                        buffer.append(chunk)
                        chunk = ""
                    else:
                        comment_part = chunk[: end_pos + 2]
                        comment = buffer.pop() + comment_part

                        version_number = extract_version_number(comment)
                        if (
                            version_number is not None
                            and version_number < version_threshold
                        ):
                            inner = strip_version_from_comment_text(comment)
                            buffer.append(inner)
                        else:
                            buffer.append(comment)

                        in_version_comment = False
                        chunk = chunk[end_pos + 2 :]

                else:
                    # We are inside a regular (non-versioned) block comment
                    i = 0
                    n = len(chunk)
                    while i < n - 1:
                        pair = chunk[i : i + 2]
                        if pair == "/*":
                            nested_comment_depth += 1
                            i += 2
                        elif pair == "*/":
                            nested_comment_depth -= 1
                            i += 2
                            if nested_comment_depth == 0:
                                in_regular_comment = False
                                i_rem = i
                                buffer.append(chunk[:i_rem])
                                chunk = chunk[i_rem:]
                                break
                        else:
                            i += 1
                    else:
                        buffer.append(chunk)
                        chunk = ""

            # Flush cleaned text from comment-filter buffer into statement builder
            flush_buffer()

            if processed_bytes - last_progress >= tenth:
                pct = min(int(processed_bytes * 100 / file_size), 100)
                print(f"\r {pct:>3.1f}%...", end="", flush=True)
                last_progress = processed_bytes

        # End of file: final flush
        flush_buffer()
        print("\r100.0%... done.")

        # If there is a final partial statement without ';', process it too
        if stmt_buffer:
            stmt = "".join(stmt_buffer)
            if stmt.strip():
                if no_drop:
                    upper = stmt.strip().upper()
                    if upper.startswith("DROP TABLE") or upper.startswith(
                        "DROP DATABASE"
                    ):
                        return
                stmt = remove_time_zone_utc_literal(stmt)
                upper_stmt = stmt.strip().upper()
                if upper_stmt.startswith("CREATE TABLE"):
                    stmt_no_semicolon = stmt.rstrip().rstrip(";")
                    stmt_no_semicolon = normalize_create_table(
                        stmt_no_semicolon,
                        table_meta,
                        default_schema=default_schema,
                    )
                    stmt = stmt_no_semicolon + ";\n"
                fout.write(stmt)


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
        dest="no_drop",
        action="store_true",
        help="If set, DROP TABLE and DROP DATABASE statements are skipped.",
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

    # Validate output path early, so we fail fast on empty or invalid output
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
    )


if __name__ == "__main__":
    main()
