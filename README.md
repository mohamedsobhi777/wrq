# wrq

`wrq` is a local-first command-line library for research papers. Give it an
arXiv ID to fetch a paper, give it a title or author to search what you already
have, or point it at a Downloads folder to bring an existing PDF collection
under control.

```console
$ wrq 1706.03762
Downloading Attention Is All You Need...
Stored in ~/papers/library/1706.03762-v7--attention-is-all-you-need.pdf

$ wrq 1706.03762
Opening the local copy...

$ wrq "vaswani attention"
```

Once a paper is in the library, opening it does not require a network request.
`wrq` keeps human-visible PDFs and schema-versioned JSON records on disk, with
no account, database server, or shell integration.

> **Project status:** `wrq` 0.1.2 is available from source, Nix, and Homebrew.
> RubyGems publishing will follow once trusted publishing is configured.

## Why wrq

Paper collections accumulate quietly: the arXiv download, the conference copy,
the same PDF under a different filename, and a folder of articles whose titles
you no longer remember. `wrq` treats one paper as one logical work, keeps its
versions and metadata together, and makes the local collection searchable.

- Paste a modern or legacy arXiv ID, an arXiv URL, or a Hugging Face Papers URL.
- Search title, authors, venue, tags, abstract, and canonical ID with the fuzzy
  selector inherited from [`try`](https://github.com/tobi/try).
- Import existing PDFs by copying them safely, or move them only after a
  successful catalog write.
- Detect duplicates by canonical identity and SHA-256. Probable title/author
  matches are review-only and are never merged automatically.
- Add your own conference, track, decision, reading status, and tags without a
  provider refresh overwriting them.
- Keep removals recoverable in the library trash.

## Requirements

- Ruby 3.2 or newer
- macOS or a POSIX-like system
- `open` on macOS or `xdg-open` on Linux for the default PDF viewer

Runtime code uses only the Ruby standard library. `HF_TOKEN` is optional.

## Install

### From source

```bash
git clone https://github.com/mohamedsobhi777/wrq.git
cd wrq
make install PREFIX="$HOME/.local"
```

Ensure `$HOME/.local/bin` is on `PATH`, then run:

```bash
wrq --help
```

The install target keeps `wrq.rb` beside its `lib/` tree under
`$PREFIX/libexec/wrq` and creates the executable in `$PREFIX/bin`. To run
without installing:

```bash
./wrq.rb --help
```

### RubyGems

After the first public gem release:

```bash
gem install wrq-cli
```

The gem is deliberately not published automatically. A maintainer must enable
trusted publishing and explicitly dispatch the release workflow.

### Nix

```bash
nix run github:mohamedsobhi777/wrq -- --help
nix profile install github:mohamedsobhi777/wrq
```

Home Manager:

```nix
{
  inputs.wrq.url = "github:mohamedsobhi777/wrq";
  imports = [ inputs.wrq.homeModules.default ];

  programs.wrq = {
    enable = true;
    path = "~/papers"; # optional; this is the default
  };
}
```

The module installs the package and exports `WRQ_PATH`. It does not inject a
shell function or use `eval`.

### Homebrew

Tap this repository explicitly, then install the stable release:

```bash
brew tap mohamedsobhi777/wrq https://github.com/mohamedsobhi777/wrq
brew install mohamedsobhi777/wrq/wrq
```

Pass `--HEAD` to `brew install` if you want the latest development build.

## Quick start

```bash
# Download from arXiv, catalog, and open
wrq 1706.03762

# The same work resolves to the same record
wrq https://arxiv.org/abs/1706.03762
wrq https://huggingface.co/papers/1706.03762

# Store without launching a viewer
wrq add 1706.03762 --no-open

# Fuzzy-search the local library
wrq "attention transformer"
wrq search "vaswani neurips"

# Import a Downloads folder (copy by default)
wrq import ~/Downloads/papers --recursive

# Add local, user-owned metadata
wrq meta 1706.03762 --venue NeurIPS --year 2017 --tag transformers

# Inspect and validate
wrq info 1706.03762 --json
wrq dedupe
wrq doctor
```

Only a complete recognized arXiv identifier or supported URL triggers a
download. Arbitrary text always remains a local fuzzy-search query.

## Command reference

### Shorthand

| Command | Result |
| --- | --- |
| `wrq` | Browse the complete local library. |
| `wrq ID_OR_URL` | Open a local asset, or fetch, store, and open it when absent. |
| `wrq QUERY` | Start the fuzzy selector with a local query. |

### Library commands

| Command | Purpose |
| --- | --- |
| `wrq add REFERENCE` | Explicitly ingest an arXiv or Hugging Face paper reference. |
| `wrq open SELECTOR` | Open a stored paper selected by ID or fuzzy query. |
| `wrq search [QUERY]` | Search the library interactively. |
| `wrq import PATH...` | Import PDF files or directories. Use `--recursive` and optionally `--move`. |
| `wrq info SELECTOR` | Print the complete stored record. Supports `--json`. |
| `wrq meta SELECTOR ...` | Edit venue, year, track, status, decision, DOI, and tags. |
| `wrq dedupe [PATH]` | Report logical, byte-identical, and probable duplicates without deleting. |
| `wrq update SELECTOR` | Refresh provider metadata and fetch a newer version. `--all` checks the library. |
| `wrq remove SELECTOR` | Confirm with `YES`, then move the record and assets to recoverable trash. |
| `wrq doctor` | Validate records, files, hashes, and path confinement. `--fix` rebuilds safe derived state. |

Common options:

- `--path PATH` overrides the library root for one invocation.
- `--no-open` stores or resolves without starting the PDF viewer.
- `--print-path` writes the selected PDF path instead of opening it.
- `--json` selects machine-readable output where supported.
- `--help` and `--version` do not create the library.

The selector uses `Up`/`Down` or `Ctrl-P`/`Ctrl-N` to navigate, `Enter` to
select, `Backspace` to edit, and `Esc` to cancel.

## Library layout

The default root is `~/papers`. Override it permanently with `WRQ_PATH` or per
command with `--path`.

```text
~/papers/
  library/                  readable PDF filenames
  .wrq/
    records/                authoritative JSON records
    versions/               retained inactive versions
    cache/                  rebuildable provider/search data
    tmp/                    same-filesystem transactional writes
    trash/                  recoverable removals
    lock                    cross-process catalog lock
```

The PDFs and records are authoritative; caches can be rebuilt. A record stores
one logical work and may reference several versioned assets. A typical asset
contains its resolved arXiv version, SHA-256 digest, byte size, source URL,
retrieval time, and relative local path.

Local PDFs without a recognized provider ID begin with a
`sha256:<digest>` identity. They can later gain an arXiv alias without creating
a second physical copy.

## Identity and duplicate handling

`wrq` applies three different checks because "duplicate" can mean different
things:

1. **Logical identity:** versionless arXiv IDs, versioned IDs, arXiv URLs, and
   Hugging Face paper URLs converge on one work.
2. **Exact bytes:** SHA-256 detects the same PDF even when filenames and source
   paths differ.
3. **Probable match:** normalized title and author similarity is reported for
   review. It is never auto-merged or deleted.

Different arXiv versions are assets of the same work, not byte duplicates.
Version-qualified input selects that exact version. Versionless input opens the
active local version immediately; `wrq update` is the explicit network check.

## Metadata

Provider metadata includes title, ordered authors, abstract, arXiv categories,
submission/update dates, comments, journal reference, publication DOI, source
URLs, and requested/resolved versions. Records tolerate unknown upstream fields
so a provider adding data does not invalidate a library.

Conference metadata is intentionally editable. arXiv's `journal_ref` and
comments are free-form and Hugging Face does not provide a canonical conference
record, so `venue`, `year`, `track`, `status`, and `decision` retain provenance.
User-owned values are never silently replaced during refresh.

Search weighting favors exact IDs, then title, authors, venue/tags, and finally
abstract text. Multi-term queries can match across fields, so an author plus a
conference works naturally. Recency breaks otherwise close matches.

## Providers and network behavior

### arXiv

`wrq` accepts modern IDs such as `1706.03762`, legacy IDs such as
`hep-th/9901001`, optional `arXiv:` prefixes, explicit `vN` versions, and arXiv
abstract/PDF/HTML URLs. Metadata comes from the official Atom API and the PDF
comes from arXiv.

Metadata access is serialized through a user-global gate and persistently
rate-limited to at least three seconds between arXiv API requests, even when
different `WRQ_PATH` libraries are used. Responses are cached. See the
[arXiv API manual](https://info.arxiv.org/help/api/user-manual.html) and
[API terms](https://info.arxiv.org/help/api/tou.html).

This project uses arXiv data and PDFs for the user's local research library.
arXiv does not review or endorse `wrq`.

### Hugging Face Papers

A Hugging Face Papers URL is an alias for its arXiv work. Optional enrichment
may add summaries, keywords, upvotes, organization/project links, and related
Hub artifacts. arXiv remains the canonical PDF source, and an unavailable HF
response never prevents ingestion.

Public lookup does not require authentication. If `HF_TOKEN` is present, it is
sent only to an allowlisted Hugging Face host and is stripped on redirects.

## Safety and privacy

- Downloads must return a successful status and begin with `%PDF-`.
- Downloads and JSON writes are staged under `.wrq/tmp` and published with an
  atomic rename. Interrupted operations do not leave a catalog record.
- Imported files are copied by default. `--move` removes the source only after
  successful ingestion.
- Provider hosts and redirect counts are allowlisted; credentials do not cross
  redirect boundaries.
- Every generated/stored relative path is confined to the configured root.
- `dedupe` only reports. `remove` requires confirmation and uses trash.

MRI enforces provider response limits while reading the network stream. The
current Spinel `Net::HTTP` runtime buffers each response before `wrq` can apply
the same rejection limit; native builds therefore do not provide a hard
pre-allocation memory bound for an unexpectedly large provider response.

`WRQ_OPENER` can name a custom viewer executable. The selected file path is
passed as an argument, not interpolated into a shell command.

## Development

```bash
bundle install
rake                         # MRI syntax, unit tests, shell specs
rake lint
rake unit
rake spec
gem build wrq.gemspec
nix build
```

When [Spinel](https://github.com/matz/spinel) is on `PATH`, `rake` also runs its
compatibility checks and native acceptance suite:

```bash
make native SPINEL=/path/to/spinel
./dist/wrq --help
make native-test SPINEL=/path/to/spinel
make native-compare SPINEL=/path/to/spinel
```

`make native` emits both `dist/wrq.c` and `dist/wrq`. Automated provider tests
use local fixtures and fake transports; CI does not depend on live arXiv or
Hugging Face availability.

Behavioral specifications live in [`spec/`](spec/), shell acceptance tests in
[`spec/tests/`](spec/tests/), and Ruby tests in [`test/`](test/).

## Credits and license

`wrq` is a fork of Tobi Lutke's [`try`](https://github.com/tobi/try). Its fuzzy
matching and terminal interaction provided the starting point for the paper
selector. The original copyright notice is retained.

The project is available under the [MIT License](LICENSE). Thanks to
[arXiv](https://arxiv.org/) and [Hugging Face Papers](https://huggingface.co/papers)
for the provider data that users may choose to access.
