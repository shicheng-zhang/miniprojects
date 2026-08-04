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
