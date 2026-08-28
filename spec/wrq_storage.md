# wrq storage and deduplication specification

## Layout

The default root is `~/papers`:

```text
~/papers/
  library/                  human-visible PDF files
  .wrq/
    records/                authoritative schema-versioned JSON records
    versions/               inactive versions when retained
    cache/                  rebuildable provider/search data
    tmp/                    same-filesystem temporary downloads and writes
    trash/                  recoverable removals
    lock                    cross-process catalog lock
```

The JSON records and PDFs are authoritative. Any aggregate index is a
rebuildable cache.

## Identity

- One logical record represents one work.
- An arXiv work key uses the versionless identifier, such as
  `arxiv:1706.03762` or `arxiv:hep-th/9901001`.
- Each downloaded version is a distinct asset with its resolved `vN`, SHA-256,
  byte size, source URL, retrieval time, and relative local path.
- A versionless reference means the latest version at initial ingestion. Once
  present, it opens the active local version without a network request.
- A version-qualified reference resolves that exact asset, downloading it only
  when it is not already stored.
- Local PDFs without a recognized external identifier use `sha256:<digest>` as
  their initial record key and may later gain aliases or merge into a canonical
  external record.

## Metadata

Records include `schema_version`, canonical key, aliases, title, ordered
authors, abstract, categories, dates, source URLs, provider data, publication
DOI, raw journal reference/comment, local venue/year/track/status/decision,
tags, provenance, assets, active asset, added time, updated time, and last-opened
time. Unknown upstream fields are tolerated.

User-owned metadata is never silently overwritten by provider refreshes.
Inferred conference data retains provenance and is not presented as verified.

## Deduplication

1. Canonical identifiers and aliases detect the same logical work.
2. SHA-256 detects byte-identical assets regardless of filename or source.
3. Normalized title and author similarity produces review-only probable matches.

Different arXiv versions belong to one work but are not byte duplicates. No
probable match is merged or removed automatically.

## Safety

- Downloads and record writes use temporary files followed by atomic rename.
- A failed or interrupted download creates neither an asset nor a record.
- Downloaded content must have a successful status and begin with `%PDF-`.
- Provider redirects are bounded and credentials never cross host boundaries.
- Generated and stored paths must remain under the configured library root.
- Destructive removal is recoverable through `.wrq/trash`.

