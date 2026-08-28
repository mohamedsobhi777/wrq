# Repository Guidelines

## Project structure

- `wrq.rb`: executable Ruby CLI entrypoint and command dispatch.
- `lib/wrq/`: paper identities, catalog/storage, providers, search, selector,
  compatibility helpers, and version.
- `lib/fuzzy.rb` and `lib/tui.rb`: terminal primitives inherited from `try`.
- `bin/wrq`: RubyGems executable that loads the repository entrypoint.
- `spec/*.md`: canonical human-readable behavior.
- `spec/tests/`: shell acceptance suite runnable against MRI or a native binary.
- `test/`: Minitest unit and integration tests with offline provider fixtures.
- `flake.nix`, `wrq.gemspec`, `Formula/wrq.rb`: distribution packaging.
- `docs/`: static project site.

Libraries live outside this repository. The default root is `~/papers`, set
globally with `WRQ_PATH` or for one invocation with `--path`.

## CLI interface

- `wrq`: browse the complete local library in the selector.
- `wrq <arxiv-id-or-supported-url>`: open the local copy, or fetch metadata and
  the PDF atomically when absent.
- `wrq <text query>`: fuzzy-search local title, authors, venue, tags, abstract,
  and canonical ID. Only complete recognized references may trigger networking.
- `wrq add REFERENCE`: explicit provider ingestion.
- `wrq open SELECTOR`: open a stored paper.
- `wrq search [QUERY]`: explicitly search the local library.
- `wrq import PATH... [--recursive] [--move]`: ingest existing PDFs. Copy is
  the default; move only after a successful record and asset write.
- `wrq info SELECTOR [--json]`: show the stored record.
- `wrq meta SELECTOR ...`: update user-owned venue, year, track, status,
  decision, DOI, and tags.
- `wrq dedupe [PATH]`: report canonical, byte-identical, and probable
  duplicates. Never delete or merge probable matches automatically.
- `wrq update SELECTOR` / `wrq update --all`: refresh provider metadata and
  retrieve newer arXiv versions.
- `wrq remove SELECTOR`: require `YES` unless `--yes`, then move the paper to
  recoverable trash.
- `wrq doctor [--fix]`: validate records, assets, hashes, path confinement, and
  rebuildable state.
- Global flags: `--path PATH`, `--json`, `--no-open`, `--print-path`,
  `--help`, and `--version`.
- Selector keys: arrows or `Ctrl-P/N` navigate, `Enter` selects, `Backspace`
  edits, and `Esc` cancels.

The CLI opens files directly with `open`, `xdg-open`, or `WRQ_OPENER`. It
does not emit shell scripts and requires no wrapper function or `eval`.

## Storage and identity invariants

The library layout is:

```text
ROOT/
  library/
  .wrq/
    records/
    versions/
    cache/
    tmp/
    trash/
    lock
```

- JSON records and PDF assets are authoritative. Aggregate indexes are caches.
- One logical arXiv work uses its versionless ID as the canonical record key.
  Versions are distinct assets on that record.
- Local PDFs begin with a SHA-256 identity and may later acquire provider aliases.
- Canonical aliases and exact hashes deduplicate automatically. Title/author
  similarity only produces a review suggestion.
- User-owned metadata is never overwritten by provider refresh.
- Every stored relative path must remain confined beneath the configured root.
- Downloads and metadata writes stage in `.wrq/tmp` and publish atomically.
- A downloaded asset must have a successful response and a `%PDF-` signature.
- Destructive removal remains recoverable through `.wrq/trash`.

## Build and development commands

- `rake` / `rake test`: MRI syntax checks, unit tests, shell specs, and
  optional Spinel checks when `spinel` is available.
- `rake lint`: syntax-check `wrq.rb` and every `lib/**/*.rb` file with MRI,
  plus the Spinel compatibility pass when configured.
- `rake unit`: run Minitest under `test/**/*_test.rb`.
- `rake spec`: run `spec/tests/wrq_runner.sh ./wrq.rb`.
- `rake spec_spinel`: build `dist/wrq.c` and `dist/wrq`, run native shell
  specs, and compare normalized MRI/native behavior.
- `make native SPINEL=/path/to/spinel`: AOT-build `dist/wrq.c` and
  `dist/wrq`.
- `make install PREFIX="$HOME/.local"`: install the entrypoint beside its
  complete library tree and link `$PREFIX/bin/wrq`.
- `gem build wrq.gemspec`: build the `wrq-cli` gem.
- `nix run . -- --help` / `nix build`: run or build the Nix package.

Spinel is optional locally. A missing compiler emits a warning rather than
failing MRI development. Use `SPINEL=/absolute/path/to/spinel` to select a
specific compiler; CI pins the tested revision.

## MRI and Spinel compatibility

`wrq` must continue working on both:

- MRI: `ruby wrq.rb`, the source install, and the `wrq-cli` gem.
- Spinel AOT: `dist/wrq`.

A construct supported by only one runtime is a bug. Prefer the standard library
and small explicit compatibility helpers. Avoid `eval`, `method_missing`,
`FileUtils`, `IO#raw`, and `IO.console`. Keep process spawning argument-safe
and avoid passing paths through a shell.

## Coding style

- Ruby with 2-space indentation.
- Prefer small, testable functions and explicit data flow.
- Keep provider/network behavior behind source adapters and injectable transports.
- Keep selector rendering in `Wrq::Selector` and reusable terminal primitives
  in `Tui`.
- Keep identity normalization centralized. Do not parse arXiv/HF references in
  individual commands.
- Use lowercase kebab-case for generated PDF filename slugs.
- Runtime dependencies remain standard-library-only. Any new dependency
  requires deliberate MRI, Spinel, gem, and Nix packaging updates.

## Specifications and tests

The markdown specs are the portable source of truth for implementations in any
language:

- `spec/wrq_command_line.md`: dispatch, commands, output channels, and status.
- `spec/wrq_storage.md`: layout, identity, metadata, deduplication, and safety.
- `spec/wrq_sources.md`: arXiv and Hugging Face provider behavior.

When behavior changes, update the relevant markdown and add a shell acceptance
test under `spec/tests/`. Add focused Ruby tests for library logic. Provider
tests must use checked-in Atom/JSON/PDF fixtures or a local fake transport; CI
must not depend on live services.

Run shell specs against any implementation:

```bash
bash spec/tests/wrq_runner.sh ./wrq.rb
bash spec/tests/wrq_runner.sh dist/wrq
```

Prefer assertions on stable stdout/stderr and exit status. Use
`WRQ_TEST_OPEN_LOG` rather than launching a desktop viewer in automation.

## Version bumps and releases

For a version bump:

1. Update `VERSION`.
2. Update `Wrq::VERSION` in `lib/wrq/version.rb`.
3. Run the full MRI, gem-content, Nix, and native gates.
4. Commit, then tag `vX.Y.Z` and push the tag.

RubyGems publication is never automatic on tag push. It requires an explicit
workflow dispatch, the publish input, and configured trusted publishing.

## Commit and pull request guidelines

- Use short imperative subjects, optionally scoped:
  - `feat: import local paper collections`
  - `fix: keep HF token across no redirects`
  - `nix: package xdg-open on Linux`
- Keep commits phase-oriented and independently verifiable.
- PRs should describe behavior and storage changes, link relevant issues, list
  tests run, and include a terminal recording or screenshot for selector changes.
- Update `README.md` whenever commands, defaults, metadata, providers, or safety
  behavior changes.

## Security and provider etiquette

- Treat `WRQ_PATH` as user-controlled. Never escape it through generated paths.
- Never send `HF_TOKEN` outside the exact Hugging Face host allowlist or across
  redirects.
- Serialize and persistently throttle arXiv metadata requests to at least three
  seconds apart.
- Bound redirects and response sizes. Clean partial downloads on every failure.
- Do not weaken typed confirmation or recoverable-trash safeguards.

## Fork attribution

`wrq` is an MIT-licensed fork of
[`tobi/try`](https://github.com/tobi/try). Preserve Tobi Lutke's copyright
notice and the upstream attribution when redistributing substantial inherited
code.
