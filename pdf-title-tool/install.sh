#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="pdf-title-tool"
INSTALL_PATH="/usr/local/bin/${PROGRAM_NAME}"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Determine real target user/home.
# Prefer running as a normal user. If run with sudo, try to use the original
# user's home directory for the backup/project folder.
# ---------------------------------------------------------------------------

if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="${SUDO_USER}"
    TARGET_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6 || true)"

    if [[ -z "${TARGET_HOME}" ]]; then
        TARGET_HOME="/home/${TARGET_USER}"
    fi
else
    TARGET_USER="$(whoami)"
    TARGET_HOME="${HOME}"
fi

BACKUP_DIR="${PDF_TITLE_TOOL_BACKUP_DIR:-${TARGET_HOME}/pdf-title-tool}"

echo "=============================================================="
echo " pdf-title-tool installer"
echo "=============================================================="
echo "Program will be installed to: ${INSTALL_PATH}"
echo "Backup/project directory:     ${BACKUP_DIR}"
echo "Target user:                  ${TARGET_USER}"
echo "=============================================================="

if [[ ${EUID} -eq 0 && -z "${SUDO_USER:-}" ]]; then
    echo
    echo "WARNING: You are running this as root."
    echo "         It is better to run this as a normal user:"
    echo
    echo "             bash ${0}"
    echo
    echo "         The script will continue, but the backup directory"
    echo "         may be placed in root's home directory."
fi

if [[ ${EUID} -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo
    echo "ERROR: sudo is required for global installation." >&2
    echo "       Please install sudo or run as root." >&2
    exit 1
fi

SUDO="sudo"
if [[ ${EUID} -eq 0 ]]; then
    SUDO=""
fi

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
fi

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* && "${ID_LIKE:-}" != *"ubuntu"* ]]; then
    echo
    echo "WARNING: This installer is designed for Ubuntu/Debian systems." >&2
    echo "         It will try to continue anyway." >&2
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo
    echo "WSL detected."
fi

# ---------------------------------------------------------------------------
# Install system dependencies
# ---------------------------------------------------------------------------

echo
echo "Updating apt package lists..."
${SUDO} apt-get update -y

echo
echo "Installing python3 and git..."
${SUDO} apt-get install -y python3 git

echo
echo "Checking for PyMuPDF/fitz..."

if ! python3 -c "import fitz" >/dev/null 2>&1; then
    echo
    echo "Trying to install python3-fitz..."
    ${SUDO} apt-get install -y python3-fitz || true
fi

if ! python3 -c "import fitz" >/dev/null 2>&1; then
    echo
    echo "python3-fitz did not provide importable fitz."
    echo "Falling back to global pip3 installation of PyMuPDF."

    ${SUDO} apt-get install -y python3-pip

    if ! command -v pip3 >/dev/null 2>&1; then
        echo
        echo "ERROR: pip3 not found after installing python3-pip." >&2
        exit 1
    fi

    # Newer Ubuntu pip may require --break-system-packages.
    # Older pip will not know that flag.
    if pip3 install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
        echo
        echo "Using: sudo pip3 install --break-system-packages pymupdf"
        ${SUDO} pip3 install --break-system-packages pymupdf || \
            ${SUDO} pip3 install pymupdf
    else
        echo
        echo "Using: sudo pip3 install pymupdf"
        ${SUDO} pip3 install pymupdf
    fi
fi

if ! python3 -c "import fitz" >/dev/null 2>&1; then
    echo
    echo "ERROR: Failed to install PyMuPDF/fitz." >&2
    echo "       Please install python3-fitz or pymupdf manually." >&2
    exit 1
fi

echo
echo "PyMuPDF/fitz is available."

# ---------------------------------------------------------------------------
# Temporary build directory
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Write the actual pdf-title-tool Python program
# ---------------------------------------------------------------------------

echo
echo "Writing ${PROGRAM_NAME} source..."

cat > "${TMP_DIR}/${PROGRAM_NAME}" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import csv
import os
import re
import sqlite3
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

try:
    import fitz
except ImportError:
    print("Missing dependency: PyMuPDF (fitz).", file=sys.stderr)
    print("Install with: sudo apt install python3-fitz", file=sys.stderr)
    sys.exit(1)

try:
    fitz.TOOLS.mupdf_display_errors(False)
except Exception:
    pass

DEFAULT_DB = os.environ.get(
    "PDF_TITLE_DB",
    str(Path.home() / ".cache" / "pdf-title-tool" / "index.db"),
)

CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")

SKIP_PATTERNS = [
    re.compile(r"^doi\b", re.I),
    re.compile(r"^10\.\d{4,}/", re.I),
    re.compile(r"^https?://", re.I),
    re.compile(r"^www\.", re.I),
    re.compile(r"^urn:", re.I),
    re.compile(r"^arxiv:", re.I),
    re.compile(r"^arxiv preprint", re.I),
    re.compile(r"^journal\b", re.I),
    re.compile(r"^proceedings\b", re.I),
    re.compile(r"^ieee\b", re.I),
    re.compile(r"^acm\b", re.I),
    re.compile(r"^springer\b", re.I),
    re.compile(r"^elsevier\b", re.I),
    re.compile(r"^wiley\b", re.I),
    re.compile(r"^volume\b", re.I),
    re.compile(r"^vol\.", re.I),
    re.compile(r"^issue\b", re.I),
    re.compile(r"^no\.\s*\d", re.I),
    re.compile(r"^pages?\b", re.I),
    re.compile(r"^pp\.", re.I),
    re.compile(r"^received\b", re.I),
    re.compile(r"^accepted\b", re.I),
    re.compile(r"^published\b", re.I),
    re.compile(r"^copyright\b", re.I),
    re.compile(r"^©", re.I),
    re.compile(r"^issn\b", re.I),
    re.compile(r"^isbn\b", re.I),
    re.compile(r"^preprint", re.I),
    re.compile(r"^manuscript", re.I),
    re.compile(r"^draft version", re.I),
    re.compile(r"^technical report", re.I),
    re.compile(r"^report no", re.I),
    re.compile(r"^edited by", re.I),
    re.compile(r"^contents$", re.I),
    re.compile(r"^preface$", re.I),
    re.compile(r"^abstract$", re.I),
    re.compile(r"^keywords", re.I),
    re.compile(r"^\d+$"),
    re.compile(r"^\d+[\.\)]\s*$"),
    re.compile(r"^page \d+", re.I),
]


def clean_text(value):
    if value is None:
        return ""

    if isinstance(value, bytes):
        value = value.decode("utf-8", "ignore")

    value = str(value)
    value = CONTROL_CHARS.sub("", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def should_skip_line(text):
    if len(text) < 3:
        return True

    if re.fullmatch(r"[\d\.\-\s:/]+", text):
        return True

    for pattern in SKIP_PATTERNS:
        if pattern.search(text):
            return True

    return False


def guess_title_from_first_page(doc):
    """
    Guess the title from the first page using font size, boldness,
    and vertical position.

    This is heuristic. It is not perfect, but it is useful for
    academic papers and books.
    """
    try:
        page = doc[0]
        data = page.get_text("dict")
        page_height = page.rect.height
        candidates = []

        for block in data.get("blocks", []):
            if block.get("type", 0) != 0:
                continue

            for line in block.get("lines", []):
                spans = line.get("spans", [])
                if not spans:
                    continue

                text = clean_text(
                    "".join(span.get("text", "") for span in spans)
                )

                if should_skip_line(text):
                    continue

                size = max(span.get("size", 0.0) for span in spans)
                bold = any((span.get("flags", 0) & 16) for span in spans)

                bbox = line.get("bbox", [0, 0, 0, 0])
                y = bbox[1]

                word_count = len(text.split())

                score = size * 3.0

                if bold:
                    score += 2.0

                if len(text) >= 8:
                    score += 1.0

                if 2 <= word_count <= 45:
                    score += 2.0

                if y < page_height * 0.85:
                    score += 1.0

                if text.isupper() and word_count >= 2:
                    score += 0.5

                candidates.append(
                    {
                        "score": score,
                        "y": y,
                        "size": size,
                        "text": text,
                    }
                )

        if not candidates:
            plain = page.get_text("text")
            for line in plain.splitlines():
                line = clean_text(line)
                if not should_skip_line(line):
                    return line[:300]
            return ""

        candidates.sort(key=lambda c: (-c["score"], c["y"]))
        best = candidates[0]

        # Try to merge wrapped title lines that have similar font size
        # and are near the best line.
        merged = [best]
        best_size = best["size"]
        best_y = best["y"]

        for candidate in candidates[1:]:
            if len(merged) >= 3:
                break

            size_close = abs(candidate["size"] - best_size) <= 1.0
            near_best_line = (
                candidate["y"] > best_y - 2
                and candidate["y"] < best_y + best_size * 3.5
            )
            score_ok = candidate["score"] >= best["score"] * 0.45

            if size_close and near_best_line and score_ok:
                merged.append(candidate)

        merged.sort(key=lambda c: c["y"])
        title = " ".join(candidate["text"] for candidate in merged)

        return clean_text(title)[:300]

    except Exception:
        return ""


def process_pdf(path):
    p = Path(path)

    try:
        doc = fitz.open(path)

        if doc.needs_pass:
            doc.close()
            return (
                str(p),
                p.name,
                "",
                "",
                "error",
                "password protected",
            )

        meta = doc.metadata or {}

        title = clean_text(meta.get("title"))
        author = clean_text(meta.get("author"))
        source = "metadata"

        # If metadata title is just the filename, ignore it.
        if title:
            lower_title = title.lower()
            if lower_title.endswith(".pdf") or lower_title == p.stem.lower():
                title = ""

        if not title:
            title = guess_title_from_first_page(doc)
            source = "first-page-guess"

        doc.close()

        return (
            str(p),
            p.name,
            title,
            author,
            source,
            "",
        )

    except Exception as e:
        return (
            str(p),
            p.name,
            "",
            "",
            "error",
            str(e),
        )


def open_db(db_path):
    path = Path(db_path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL;")

    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            filename TEXT,
            title TEXT,
            author TEXT,
            source TEXT,
            error TEXT,
            size INTEGER,
            mtime REAL,
            scanned_at REAL
        )
        """
    )

    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_files_title
        ON files(title)
        """
    )

    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_files_filename
        ON files(filename)
        """
    )

    return conn


def iter_pdfs(folder):
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in {".git", ".hg", ".svn"}]

        for name in files:
            if name.lower().endswith(".pdf"):
                yield Path(root) / name


def process_batch(executor, conn, batch):
    if not batch:
        return 0

    paths = [item[0] for item in batch]
    results = executor.map(process_pdf, paths, chunksize=10)

    now = time.time()
    cur = conn.cursor()
    count = 0

    for (path, size, mtime), result in zip(batch, results):
        _, filename, title, author, source, error = result

        cur.execute(
            """
            INSERT OR REPLACE INTO files (
                path,
                filename,
                title,
                author,
                source,
                error,
                size,
                mtime,
                scanned_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                path,
                filename,
                title,
                author,
                source,
                error,
                size,
                mtime,
                now,
            ),
        )

        count += 1

    conn.commit()
    return count


def cmd_scan(args):
    folder = Path(args.folder).expanduser().resolve()

    if not folder.is_dir():
        print(f"Folder not found: {folder}", file=sys.stderr)
        sys.exit(1)

    conn = open_db(args.db)
    cur = conn.cursor()

    batch = []
    processed = 0
    checked = 0
    skipped = 0
    last_report = 0

    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        for pdf in iter_pdfs(folder):
            checked += 1

            try:
                st = pdf.stat()
            except OSError as e:
                now = time.time()
                cur.execute(
                    """
                    INSERT OR REPLACE INTO files (
                        path,
                        filename,
                        title,
                        author,
                        source,
                        error,
                        size,
                        mtime,
                        scanned_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        str(pdf),
                        pdf.name,
                        "",
                        "",
                        "error",
                        str(e),
                        0,
                        0.0,
                        now,
                    ),
                )
                continue

            if not args.rescan:
                cur.execute(
                    """
                    SELECT size, mtime, error
                    FROM files
                    WHERE path = ?
                    """,
                    (str(pdf),),
                )

                row = cur.fetchone()

                if (
                    row
                    and row[0] == st.st_size
                    and row[1] == st.st_mtime
                    and not row[2]
                ):
                    skipped += 1
                    continue

            batch.append((str(pdf), st.st_size, st.st_mtime))

            if len(batch) >= args.batch_size:
                processed += process_batch(executor, conn, batch)
                batch = []

                if processed >= last_report + 1000:
                    print(
                        f"Processed {processed} PDFs...",
                        file=sys.stderr,
                    )
                    last_report = processed

        if batch:
            processed += process_batch(executor, conn, batch)

    conn.commit()

    if args.prune:
        deleted = 0
        delete_batch = []

        for (path,) in conn.execute("SELECT path FROM files"):
            if not Path(path).exists():
                delete_batch.append(path)

            if len(delete_batch) >= 1000:
                conn.executemany(
                    "DELETE FROM files WHERE path = ?",
                    [(p,) for p in delete_batch],
                )
                deleted += len(delete_batch)
                delete_batch = []

        if delete_batch:
            conn.executemany(
                "DELETE FROM files WHERE path = ?",
                [(p,) for p in delete_batch],
            )
            deleted += len(delete_batch)

        conn.commit()
        print(f"Pruned {deleted} missing files from database.", file=sys.stderr)

    print(
        f"Checked {checked} PDFs. "
        f"Processed {processed} new/changed. "
        f"Skipped {skipped} unchanged.",
        file=sys.stderr,
    )

    print(f"Database: {args.db}")


def cmd_search(args):
    conn = open_db(args.db)

    query = args.query.strip()

    if not query:
        print("Empty search query.", file=sys.stderr)
        sys.exit(1)

    if args.filename_too:
        where = """
            instr(lower(title), lower(?)) > 0
            OR instr(lower(filename), lower(?)) > 0
        """
        params = [query, query]
    else:
        where = """
            instr(lower(title), lower(?)) > 0
        """
        params = [query]

    sql = f"""
        SELECT path, title, author, source, error
        FROM files
        WHERE {where}
        ORDER BY title COLLATE NOCASE
    """

    if args.limit and args.limit > 0:
        sql += " LIMIT ?"
        params.append(args.limit)

    count = 0

    for path, title, author, source, error in conn.execute(sql, params):
        count += 1

        display_title = title if title else "[no title]"

        print(display_title)
        print(f"    {path}")

        if args.verbose:
            if author:
                print(f"    author: {author}")
            print(f"    source: {source}")
            if error:
                print(f"    error: {error}")

        print()

    if count == 0:
        print("No matches.", file=sys.stderr)


def cmd_export(args):
    conn = open_db(args.db)

    output = Path(args.output).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)

    with open(output, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)

        writer.writerow(
            [
                "path",
                "filename",
                "title",
                "author",
                "source",
                "error",
                "size",
                "mtime",
                "scanned_at",
            ]
        )

        for row in conn.execute(
            """
            SELECT
                path,
                filename,
                title,
                author,
                source,
                error,
                size,
                mtime,
                scanned_at
            FROM files
            ORDER BY path
            """
        ):
            writer.writerow(row)

    print(f"Exported CSV to: {output}")


def cmd_stats(args):
    conn = open_db(args.db)

    row = conn.execute(
        """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN title IS NOT NULL AND title != '' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN error IS NOT NULL AND error != '' THEN 1 ELSE 0 END), 0)
        FROM files
        """
    ).fetchone()

    total = row[0] or 0
    with_title = row[1] or 0
    errors = row[2] or 0

    print(f"Database: {args.db}")
    print(f"Total PDF entries: {total}")
    print(f"Entries with title: {with_title}")
    print(f"Entries with errors: {errors}")


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--db",
        default=DEFAULT_DB,
        help=f"SQLite database path. Default: {DEFAULT_DB}",
    )

    parser = argparse.ArgumentParser(
        prog="pdf-title-tool",
        description="Scan PDFs, extract internal titles, and search them.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    p_scan = subparsers.add_parser(
        "scan",
        parents=[common],
        help="Scan a folder of PDFs and store titles in the database.",
    )
    p_scan.add_argument("folder")
    p_scan.add_argument(
        "--workers",
        type=int,
        default=max(2, os.cpu_count() or 4),
        help="Number of parallel workers.",
    )
    p_scan.add_argument(
        "--batch-size",
        type=int,
        default=200,
        help="Number of PDFs to process per database batch.",
    )
    p_scan.add_argument(
        "--rescan",
        action="store_true",
        help="Force rescan even if file size/mtime has not changed.",
    )
    p_scan.add_argument(
        "--prune",
        action="store_true",
        help="Remove database entries whose files no longer exist.",
    )
    p_scan.set_defaults(func=cmd_scan)

    p_search = subparsers.add_parser(
        "search",
        parents=[common],
        help="Search stored PDF titles.",
    )
    p_search.add_argument("query")
    p_search.add_argument(
        "--limit",
        type=int,
        default=100,
        help="Maximum number of results. Use 0 for no limit.",
    )
    p_search.add_argument(
        "--filename-too",
        action="store_true",
        help="Also match the filename, not just the internal title.",
    )
    p_search.add_argument(
        "--verbose",
        action="store_true",
        help="Show author/source/error details.",
    )
    p_search.set_defaults(func=cmd_search)

    p_export = subparsers.add_parser(
        "export",
        parents=[common],
        help="Export database to CSV.",
    )
    p_export.add_argument("output")
    p_export.set_defaults(func=cmd_export)

    p_stats = subparsers.add_parser(
        "stats",
        parents=[common],
        help="Show database statistics.",
    )
    p_stats.set_defaults(func=cmd_stats)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
PYEOF

chmod 0755 "${TMP_DIR}/${PROGRAM_NAME}"

# ---------------------------------------------------------------------------
# Install globally
# ---------------------------------------------------------------------------

echo
echo "Installing globally to ${INSTALL_PATH}..."
${SUDO} install -m 0755 "${TMP_DIR}/${PROGRAM_NAME}" "${INSTALL_PATH}"

# ---------------------------------------------------------------------------
# Create backup/project folder in home directory
# ---------------------------------------------------------------------------

echo
echo "Creating backup/project directory: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}/bin"

cp "${TMP_DIR}/${PROGRAM_NAME}" "${BACKUP_DIR}/bin/${PROGRAM_NAME}"
chmod 0755 "${BACKUP_DIR}/bin/${PROGRAM_NAME}"

# Copy this installer script itself, if possible.
SELF="${BASH_SOURCE[0]:-$0}"

if [[ -f "${SELF}" ]]; then
    cp -L "${SELF}" "${BACKUP_DIR}/install.sh"
    chmod 0755 "${BACKUP_DIR}/install.sh"
else
    cat > "${BACKUP_DIR}/install.sh" <<'INSTALLER_EOF'
# The installer was run from a non-file context, so the original script
# could not be copied automatically.
#
# Save the original all-in-one installer script here manually.
INSTALLER_EOF
fi

cat > "${BACKUP_DIR}/README.md" <<'README_EOF'
# pdf-title-tool

Global PDF internal-title scanner and search tool.

## Installed command

```bash
pdf-title-tool
```

## Scan PDFs

```bash
pdf-title-tool scan /path/to/pdfs --workers 8
```

## Search titles

```bash
pdf-title-tool search principia
```

## Search with details

```bash
pdf-title-tool search "principia mathematica" --verbose
```

## Export database to CSV

```bash
pdf-title-tool export ~/pdf_titles.csv
```

## Show database stats

```bash
pdf-title-tool stats
```

## Default database

```bash
~/.cache/pdf-title-tool/index.db
```

You can override the database path with:

```bash
export PDF_TITLE_DB=/path/to/custom.db
```

or per command:

```bash
pdf-title-tool scan /path/to/pdfs --db /path/to/custom.db
```

## Notes

- The tool first checks PDF metadata.
- If metadata title is missing, it guesses from the first page.
- Scanned PDFs without text may need OCR later.
- The first scan can take a long time for large libraries.
- Later scans skip unchanged files unless `--rescan` is used.
README_EOF

cat > "${BACKUP_DIR}/.gitignore" <<'GITIGNORE_EOF'
__pycache__/
*.pyc
*.db
*.db-wal
*.db-shm
GITIGNORE_EOF

# If root created the backup directory for another user, fix ownership.
if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo
    echo "Fixing ownership of ${BACKUP_DIR} for ${TARGET_USER}..."
    chown -R "${TARGET_USER}" "${BACKUP_DIR}"
fi

# ---------------------------------------------------------------------------
# Git repository initialization
# ---------------------------------------------------------------------------

if [[ "${PDF_TITLE_TOOL_GIT:-1}" != "0" ]] && command -v git >/dev/null 2>&1; then
    echo
    echo "Initializing/updating git repository in ${BACKUP_DIR}..."

    if [[ ! -d "${BACKUP_DIR}/.git" ]]; then
        (
            cd "${BACKUP_DIR}"
            git init -b main 2>/dev/null || git init
            git add -A

            if ! git config user.email >/dev/null 2>&1; then
                git config user.email "pdf-title-tool-installer@localhost"
            fi

            if ! git config user.name >/dev/null 2>&1; then
                git config user.name "pdf-title-tool installer"
            fi

            git commit -m "Initial pdf-title-tool installer backup" || true
        )
    else
        (
            cd "${BACKUP_DIR}"
            git add -A
            git commit -m "Update pdf-title-tool installer backup" || true
        )
    fi
else
    echo
    echo "Skipping git initialization."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
echo "=============================================================="
echo " Installation complete."
echo "=============================================================="
echo
echo "Installed command:"
echo
echo "    ${INSTALL_PATH}"
echo
echo "Backup/project folder:"
echo
echo "    ${BACKUP_DIR}"
echo
echo "Try:"
echo
echo "    pdf-title-tool --help"
echo "    pdf-title-tool stats"
echo "    pdf-title-tool scan /path/to/pdfs --workers 8"
echo "    pdf-title-tool search principia"
echo
