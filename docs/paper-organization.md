# Paper organization: collections and filesystem views

> **Status:** Design proposal. The commands in this document are not available
> in `wrq` 0.1.2. The stable command reference remains in the project README
> and in `wrq --help`.

## Motivation

A research library often needs more than one useful hierarchy. The same paper
may belong beside other work on a topic and beside papers from the same venue:

```text
~/papers/topics/transformers/attention-is-all-you-need.pdf

~/Projects/conf-papers/NeurIPS/2017/attention-is-all-you-need.pdf
```

Keeping independent copies in both trees makes browsing convenient, but it
also creates duplicate bytes, split metadata, and uncertainty about which copy
is authoritative. `wrq` should preserve that browsing experience without
turning every organization scheme into another library.

## Proposed model

The design has four layers:

1. **Canonical library:** one authoritative record and one managed copy of each
   PDF asset.
2. **Metadata facets:** multi-value topics plus the existing venue, year,
   track, status, decision, and tags.
3. **Collections:** named explicit lists or saved metadata/search queries.
4. **Views and exports:** derived filesystem layouts generated from the
   canonical library.

A paper may have several topics and can therefore appear in several view
directories. Venue and year remain independent metadata rather than being
encoded only in a pathname.

General tags and topics stay separate. A tag such as `to-read` or `favorite`
should not automatically create a directory, while topics such as
`transformers` and `retrieval` are useful organization facets.

## Proposed command line

### Topics and filtered search

Topics extend the existing metadata command:

```text
wrq meta SELECTOR
  [--topic TOPIC]
  [--remove-topic TOPIC]
  [--venue VENUE]
  [--year YYYY]
  [--track TRACK]
  [--status STATUS]
  [--decision VALUE]
  [--doi DOI]
  [--tag TAG]
  [--remove-tag TAG]
```

`--topic`, `--remove-topic`, `--tag`, and `--remove-tag` are repeatable.
Search gains optional structured filters without losing fuzzy matching:

```text
wrq search [QUERY]
  [--topic TOPIC]
  [--venue VENUE]
  [--year YYYY]
  [--tag TAG]
  [--status STATUS]
```

Examples:

```bash
wrq meta 1706.03762 \
  --topic transformers \
  --topic nlp \
  --venue NeurIPS \
  --year 2017

wrq search "attention" --topic transformers
wrq search --venue NeurIPS --year 2017
```

### Layout-aware import

An import layout maps relative path components into metadata:

```text
wrq import PATH...
  [--recursive]
  [--move]
  [--dry-run]
  [--layout TEMPLATE]
  [--topic TOPIC]
  [--venue VENUE]
  [--year YYYY]
```

For the two motivating directory trees:

```bash
wrq import ~/papers \
  --recursive \
  --layout '{topic}/{filename}' \
  --dry-run

wrq import /Users/mohamedmorsi/Projects/conf-papers \
  --recursive \
  --layout '{venue}/{year}/{filename}' \
  --dry-run
```

After reviewing the preview, repeat without `--dry-run`. Values obtained from
paths are stored with `path-inferred` provenance. They can fill absent fields
but cannot overwrite metadata that the user already curated.

Hash and canonical-identity deduplication continue to apply across every input
tree, so importing both locations does not create two records for identical
papers.

### Collections

Collections provide stable names for explicit lists and dynamic queries:

```text
wrq collection create NAME [FILTERS]
wrq collection add NAME SELECTOR...
wrq collection remove NAME SELECTOR...
wrq collection show NAME
wrq collection open NAME
wrq collection list
wrq collection delete NAME
```

Supported collection filters:

```text
--query QUERY
--topic TOPIC
--venue VENUE
--year YYYY
--tag TAG
--status STATUS
```

Creating a collection with filters produces a dynamic collection. Creating one
without filters produces an explicit collection whose membership changes
through `collection add` and `collection remove`.

```bash
wrq collection create transformers --topic transformers
wrq collection create neurips-2025 --venue NeurIPS --year 2025

wrq collection create reading-list
wrq collection add reading-list 1706.03762 2401.01234
wrq collection open reading-list
```

### Managed filesystem views

A view maps selected records into a directory layout:

```text
wrq view add NAME
  --root PATH
  --layout TEMPLATE
  [--mode symlink|hardlink|copy]
  [--collection NAME]
  [FILTERS]

wrq view list
wrq view show NAME
wrq view sync [NAME] [--dry-run]
wrq view status [NAME]
wrq view clean [NAME] [--dry-run]
wrq view remove NAME [--keep-files]
```

`symlink` is the default mode. With no collection or filter, a view considers
the complete library and skips records that do not contain values required by
its layout.

The motivating setup becomes:

```bash
wrq view add topics \
  --root ~/papers/topics \
  --layout '{topic}/{title}.pdf'

wrq view add conferences \
  --root /Users/mohamedmorsi/Projects/conf-papers \
  --layout '{venue}/{year}/{title}.pdf'

wrq view sync
```

One paper with two topics creates two managed links. The conference view points
to the same canonical asset, so all three paths represent one stored PDF.

`view sync` creates missing entries and updates entries whose active asset or
metadata changed. `view clean` removes stale entries only when the view
manifest proves that `wrq` created them. Neither command removes canonical
records or assets.

### Portable exports

Exports create independent copies for sharing, travel, review packets, or
archival snapshots:

```text
wrq export [SELECTOR...]
  --to PATH
  [--collection NAME]
  [FILTERS]
  [--layout TEMPLATE]
  [--dry-run]
```

Examples:

```bash
wrq export \
  --collection reading-list \
  --to ~/Desktop/reading-list

wrq export \
  --venue NeurIPS \
  --year 2025 \
  --to ~/Desktop/neurips-2025 \
  --layout '{first_author}--{title}.pdf'
```

Exports are snapshots and are never treated as another authoritative library.

## Layout templates

Initial layout placeholders:

| Placeholder | Meaning |
| --- | --- |
| `{topic}` | One output entry per topic. |
| `{venue}` | User-curated or inferred venue. |
| `{year}` | Four-digit publication or venue year. |
| `{track}` | Conference track. |
| `{title}` | Filesystem-safe paper title. |
| `{first_author}` | Filesystem-safe first author. |
| `{arxiv_id}` | Versionless arXiv identifier. |
| `{version}` | Selected asset version. |
| `{filename}` | Original basename during import. |

Every expanded component is slugged and path-confined. Empty components,
absolute paths, `..`, symlink traversal, and NUL bytes are rejected. Filename
collisions receive a deterministic canonical-key or digest suffix rather than
silently replacing another entry.

Views point to the active asset by default. A later version-aware design may
add an explicit option for materializing every retained version.

## Storage-mode tradeoffs

| Mode | Advantages | Costs and risks | Recommended role |
| --- | --- | --- | --- |
| Metadata and collections only | Portable, simple, and no filesystem debris. | Does not co-locate papers in Finder or other tools. | Search and logical grouping. |
| Symlink view | Multiple overlapping layouts with no duplicate bytes. Deleting a link does not delete the paper. | Links depend on the canonical target and may break when a library is moved independently. | Default managed view. |
| Hard-link view | Appears as a normal file and uses no extra PDF storage. | Same filesystem only; editing any path mutates the canonical bytes; semantics can surprise backup tools. | Opt-in advanced mode. |
| Copy view/export | Portable, shareable, and independent of the library. | Uses additional space and becomes stale. | Explicit export or snapshot. |
| Physical canonical layout | Familiar real directories without links. | A file has only one path, metadata changes cause moves, and multi-topic papers need an arbitrary primary location. | Possible future opt-in, not the default. |
| Multiple independent catalogs | Preserves existing directory ownership. | Duplicate detection and metadata become split across roots; every command needs scope rules. | Migration compatibility only. |

## Safety invariants

- Canonical records and assets remain the only source of truth.
- A view has a manifest containing every path and target created by `wrq`.
- Cleanup never removes an untracked path or a user-modified copied export.
- View roots cannot be the canonical `library` directory or any `.wrq`
  directory.
- `--dry-run` shows every proposed import, link, copy, update, and cleanup.
- Missing layout metadata skips a record and reports the reason; it never
  invents a verified venue, year, or topic.
- Metadata changes, provider refreshes, removal, and active-version changes are
  reconciled by the next view sync.
- Removing a view does not remove canonical papers.

## Suggested delivery order

1. Add first-class multi-value topics and structured search filters.
2. Add layout-aware import and dry-run output.
3. Add explicit and dynamic collections.
4. Add manifest-backed symlink views.
5. Add copy-based export.
6. Consider hard-link views and physical canonical layouts as opt-in modes.

Each phase must update the canonical Markdown specifications and shell tests,
and must remain compatible with both MRI and Spinel native builds.
