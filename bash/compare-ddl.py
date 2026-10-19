#!/usr/bin/env python3
"""
Compare table structures in two MySQL/MariaDB DDL dumps.

Inputs must be schema-only dumps produced by mysqldump or
mariadb-dump, with standard "Table structure for table" headers.

Only real base tables are compared. Temporary CREATE TABLE
statements used for views are ignored.

Outputs:
  compatible-tables.txt
  incompatible-tables.tsv
  table-structure-diff.txt

The script never connects to or modifies databases.

Requires Python 3.6+.
"""

import argparse
import difflib
import os
import re
import sys
import tempfile
from pathlib import Path


class DDLError(Exception):
    pass


HEADER_RE = re.compile(
    r"^\s*--\s*"
    r"(Table structure for table|"
    r"Temporary view structure for view|"
    r"Final view structure for view)"
    r"\s+`((?:``|[^`])+)`\s*$",
    re.IGNORECASE,
)

CREATE_RE = re.compile(
    r"^\s*CREATE\s+TABLE\s+"
    r"(?:IF\s+NOT\s+EXISTS\s+)?"
    r"`((?:``|[^`])+)`",
    re.IGNORECASE,
)

REPORT_NAMES = (
    "compatible-tables.txt",
    "incompatible-tables.tsv",
    "table-structure-diff.txt",
)


def skip_quoted(text, start):
    """Return the position after a quoted SQL token."""
    quote = text[start]
    i = start + 1

    while i < len(text):
        char = text[i]

        if char == "\\":
            i += 2
            continue

        if char == quote:
            if i + 1 < len(text) and text[i + 1] == quote:
                i += 2
                continue
            return i + 1

        i += 1

    return None


def skip_line_comment(text, start):
    end = text.find("\n", start)
    return len(text) if end < 0 else end + 1


def is_dash_comment(text, i):
    return (
        text.startswith("--", i)
        and (i + 2 >= len(text) or text[i + 2].isspace())
    )


def statement_end(sql):
    """Find the first real semicolon outside strings/comments."""
    i = 0

    while i < len(sql):
        char = sql[i]

        if char in ("'", '"', "`"):
            end = skip_quoted(sql, i)
            if end is None:
                return None
            i = end
            continue

        if sql.startswith("/*", i):
            end = sql.find("*/", i + 2)
            if end < 0:
                return None
            i = end + 2
            continue

        if is_dash_comment(sql, i) or char == "#":
            i = skip_line_comment(sql, i)
            continue

        if char == ";":
            return i + 1

        i += 1

    return None


def sql_tokens(sql):
    """Tokenize DDL without changing string or identifier values."""
    tokens = []
    i = 0

    while i < len(sql):
        char = sql[i]

        if char.isspace():
            i += 1
            continue

        if char in ("'", '"', "`"):
            end = skip_quoted(sql, i)
            if end is None:
                raise DDLError("Unterminated quoted SQL token")
            tokens.append(sql[i:end])
            i = end
            continue

        if sql.startswith("/*", i):
            end = sql.find("*/", i + 2)
            if end < 0:
                raise DDLError("Unterminated SQL block comment")

            comment = sql[i:end + 2]

            # Executable version comments and hints may matter.
            if comment.startswith(("/*!", "/*M!", "/*+")):
                tokens.append(comment)

            i = end + 2
            continue

        if is_dash_comment(sql, i) or char == "#":
            i = skip_line_comment(sql, i)
            continue

        if char.isalnum() or char in "_$@":
            end = i + 1
            while end < len(sql):
                c = sql[end]
                if not (c.isalnum() or c in "_$@"):
                    break
                end += 1

            tokens.append(sql[i:end])
            i = end
            continue

        tokens.append(char)
        i += 1

    return tokens


def normalize_table(sql):
    """
    Normalize formatting and volatile table AUTO_INCREMENT value.

    This is deliberately conservative: SQL keywords, column types,
    defaults, indexes, constraints, charsets and collations retain
    their original tokens.
    """
    tokens = sql_tokens(sql)
    result = []

    depth = 0
    found_body = False
    after_body = False
    i = 0

    while i < len(tokens):
        token = tokens[i]

        if token == "(":
            depth += 1
            found_body = True

        elif token == ")":
            depth -= 1

            if depth < 0:
                raise DDLError("Unbalanced parentheses in CREATE TABLE")

            if found_body and depth == 0:
                after_body = True

        if (
            after_body
            and token.upper() == "AUTO_INCREMENT"
            and i + 2 < len(tokens)
            and tokens[i + 1] == "="
            and tokens[i + 2].isdigit()
        ):
            result.extend(("AUTO_INCREMENT", "=", "0"))
            i += 3
            continue

        result.append(token)
        i += 1

    if not found_body or depth != 0:
        raise DDLError("Invalid or unbalanced CREATE TABLE definition")

    return tuple(result)


def check_name(name):
    if any(char in name for char in "\r\n\t"):
        raise DDLError(
            "Table name cannot be represented in line/TSV output: {!r}"
            .format(name)
        )


def load_tables(path):
    """Read genuine CREATE TABLE definitions from a DDL dump."""
    try:
        text = Path(path).read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as exc:
        raise DDLError("Cannot read {!s}: {}".format(path, exc))

    # Require the mysqldump completion marker to reject truncated
    # dumps rather than silently accept an incomplete table list.
    lines = text.rstrip().splitlines()

    if not lines or not re.match(
        r"^--\s*Dump completed\b", lines[-1], re.IGNORECASE
    ):
        raise DDLError(
            "Missing final mysqldump completion marker in {!s}"
            .format(path)
        )

    tables = {}
    section_name = None
    waiting_for_create = False
    pending_sql = None
    header_count = 0

    def store(sql, expected_name):
        match = CREATE_RE.match(sql)

        if not match:
            raise DDLError(
                "Unexpected CREATE TABLE syntax for {!r}"
                .format(expected_name)
            )

        actual_name = match.group(1).replace("``", "`")

        if actual_name != expected_name:
            raise DDLError(
                "Table header {!r} does not match CREATE TABLE {!r}"
                .format(expected_name, actual_name)
            )

        check_name(actual_name)

        if actual_name in tables:
            raise DDLError(
                "Duplicate CREATE TABLE for {!r}".format(actual_name)
            )

        try:
            normalized = normalize_table(sql)
        except DDLError as exc:
            raise DDLError(
                "Cannot normalize table {!r}: {}"
                .format(actual_name, exc)
            )

        tables[actual_name] = (sql, normalized)

    for line_number, line in enumerate(text.splitlines(True), 1):
        if pending_sql is not None:
            pending_sql += line
            end = statement_end(pending_sql)

            if end is not None:
                store(pending_sql[:end], section_name)
                pending_sql = None
                waiting_for_create = False

            continue

        header = HEADER_RE.match(line)

        if header:
            if waiting_for_create:
                raise DDLError(
                    "Missing CREATE TABLE for {!r} before line {}"
                    .format(section_name, line_number)
                )

            kind = header.group(1).lower()
            name = header.group(2).replace("``", "`")

            if kind == "table structure for table":
                section_name = name
                waiting_for_create = True
                header_count += 1
            else:
                # mysqldump uses CREATE TABLE placeholders for views.
                section_name = None
                waiting_for_create = False

            continue

        if line.lstrip().lower().startswith(
            "-- table structure for table"
        ):
            raise DDLError(
                "Unrecognized table header at line {}"
                .format(line_number)
            )

        if waiting_for_create and re.match(
            r"^\s*CREATE\s+TABLE\b", line, re.IGNORECASE
        ):
            pending_sql = line
            end = statement_end(pending_sql)

            if end is not None:
                store(pending_sql[:end], section_name)
                pending_sql = None
                waiting_for_create = False

    if pending_sql is not None:
        raise DDLError(
            "Unterminated CREATE TABLE for {!r}".format(section_name)
        )

    if waiting_for_create:
        raise DDLError(
            "Missing CREATE TABLE for {!r}".format(section_name)
        )

    if header_count == 0:
        raise DDLError(
            "No recognized table structure sections in {!s}"
            .format(path)
        )

    return tables


def atomic_write(path, content):
    """Write a report without leaving a partially written file."""
    fd, temp_path = tempfile.mkstemp(
        prefix=".compare-ddl-",
        dir=str(path.parent),
    )

    try:
        with os.fdopen(
            fd, "w", encoding="utf-8", newline="\n"
        ) as handle:
            handle.write(content)

        os.replace(temp_path, str(path))

    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def compare_tables(production, local):
    compatible = []
    incompatible = {}
    diff_lines = []

    all_names = sorted(set(production) | set(local))

    for name in all_names:
        if name not in local:
            incompatible[name] = "MISSING_LOCAL"
            diff_lines.append(
                "{}: exists only in production\n".format(name)
            )
            continue

        if name not in production:
            incompatible[name] = "MISSING_PRODUCTION"
            diff_lines.append(
                "{}: exists only locally\n".format(name)
            )
            continue

        production_sql, production_normalized = production[name]
        local_sql, local_normalized = local[name]

        if production_normalized == local_normalized:
            compatible.append(name)
            continue

        incompatible[name] = "DDL_MISMATCH"

        diff = difflib.unified_diff(
            production_sql.splitlines(),
            local_sql.splitlines(),
            fromfile="production/{}".format(name),
            tofile="local/{}".format(name),
            lineterm="",
        )

        diff_lines.append(
            "\n===== {} =====\n".format(name)
        )
        diff_lines.extend(line + "\n" for line in diff)

    return compatible, incompatible, diff_lines


def main():
    parser = argparse.ArgumentParser(
        description="Compare MySQL/MariaDB DDL table structures."
    )

    parser.add_argument(
        "--production", required=True,
        help="Production .ddl.sql file"
    )
    parser.add_argument(
        "--local", required=True,
        help="Local .ddl.sql file"
    )
    parser.add_argument(
        "--out-dir", default=".",
        help="Directory for comparison reports"
    )

    args = parser.parse_args()
    output_dir = Path(args.out_dir)

    try:
        output_dir.mkdir(parents=True, exist_ok=True)

        # Remove old results first. A failed comparison must never
        # leave a stale compatible-tables.txt that looks current.
        for name in REPORT_NAMES:
            old_path = output_dir / name
            if old_path.is_file():
                old_path.unlink()

        production = load_tables(args.production)
        local = load_tables(args.local)

        compatible, incompatible, diff_lines = compare_tables(
            production, local
        )

        compatible_text = "".join(
            name + "\n" for name in compatible
        )

        incompatible_text = "table_name\treason\n"
        incompatible_text += "".join(
            "{}\t{}\n".format(name, reason)
            for name, reason in sorted(incompatible.items())
        )

        diff_text = "".join(diff_lines)
        if not diff_text:
            diff_text = "No table structure differences.\n"

        # Publish the compatible list last, after other reports.
        atomic_write(
            output_dir / "incompatible-tables.tsv",
            incompatible_text,
        )
        atomic_write(
            output_dir / "table-structure-diff.txt",
            diff_text,
        )
        atomic_write(
            output_dir / "compatible-tables.txt",
            compatible_text,
        )

        reasons = list(incompatible.values())

        print("[INFO] Production tables:  {}".format(len(production)))
        print("[INFO] Local tables:       {}".format(len(local)))
        print("[OK]   Compatible tables: {}".format(len(compatible)))
        print("[SKIP] DDL differences:   {}".format(
            reasons.count("DDL_MISMATCH")
        ))
        print("[SKIP] Missing locally:   {}".format(
            reasons.count("MISSING_LOCAL")
        ))
        print("[SKIP] Local-only:        {}".format(
            reasons.count("MISSING_PRODUCTION")
        ))
        print("[INFO] Reports: {}".format(output_dir.resolve()))

        if not compatible:
            print("[WARN] No compatible tables found.")
            return 2

        return 0

    except (DDLError, OSError) as exc:
        print("[ERROR] {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
