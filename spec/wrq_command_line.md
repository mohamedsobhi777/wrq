# wrq command-line specification

`wrq` is a local-first research-paper library. It stores PDFs and metadata in
one library, opens papers with the platform viewer, and never requires a shell
wrapper or `eval`.

## Global behavior

- `WRQ_PATH` sets the library root. The default is `~/papers`.
- `--path PATH` overrides the root for one invocation.
- `--json` selects machine-readable output where the command supports it.
- `--no-open` stores or resolves a paper without launching a viewer.
- `--print-path` prints the selected PDF path instead of launching a viewer.
- `--help` and `--version` succeed without creating the library.
- Diagnostics and the interactive interface use stderr. Structured output and
  paths use stdout.

## Shorthand dispatch

- `wrq` opens the interactive selector for the complete local library.
- `wrq <arxiv-id-or-url>` opens the local paper when present. When absent it
  fetches metadata and the PDF, stores them atomically, and then opens it.
- `wrq <hugging-face-paper-url>` extracts the base arXiv identifier and follows
  the same flow. Hugging Face enrichment is optional and never blocks storage.
- `wrq <other text>` opens the selector with that local fuzzy-search query.
- Only complete recognized identifiers and URLs trigger network access.

## Commands

- `wrq add REFERENCE` explicitly adds an arXiv or Hugging Face paper.
- `wrq open SELECTOR` opens an existing paper selected by ID or fuzzy query.
- `wrq search [QUERY]` searches the local library.
- `wrq import PATH...` imports PDF files. Directories are non-recursive unless
  `--recursive` is present. Import copies by default; `--move` removes a source
  only after its destination and record have been written successfully.
- `wrq info SELECTOR` prints complete stored metadata.
- `wrq meta SELECTOR` updates user-owned metadata fields including venue, year,
  track, publication status, decision, publication DOI, and tags.
- `wrq dedupe [PATH]` reports logical, byte-identical, and probable duplicates.
  It does not delete files.
- `wrq update SELECTOR` refreshes provider metadata and downloads a newer arXiv
  version when one exists. `--all` applies this to all arXiv records.
- `wrq remove SELECTOR` requires typing `YES` unless `--yes` is supplied, then
  moves the record and its assets to the library trash rather than deleting.
- `wrq doctor` validates records, assets, hashes, and path confinement. `--fix`
  may remove abandoned temporary files and rebuild derived caches.

## Exit status

- `0`: requested operation completed.
- `1`: operational failure, invalid local state, or cancelled interaction.
- `2`: invalid command-line usage.

