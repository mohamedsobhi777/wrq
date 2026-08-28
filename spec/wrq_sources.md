# wrq provider specification

## arXiv

`wrq` accepts modern identifiers, legacy identifiers, optional `arXiv:`
prefixes, optional versions, and arXiv abstract, PDF, and HTML URLs. The base ID
is the logical identity while the requested and resolved versions remain asset
metadata.

Metadata comes from the official Atom API. Stored provider metadata includes
the canonical/versioned ID, title, abstract, ordered authors, submitted and
updated dates, categories, primary category, PDF and abstract URLs, comments,
journal reference, and publication DOI when present.

arXiv requests use one connection at a time and a persistent minimum
three-second interval. Responses are cached. A useful project User-Agent and
the official acknowledgement are included. PDFs are for the user's local
personal/research library and are not served or redistributed by `wrq`.

## Hugging Face Papers

Hugging Face paper references are aliases for base arXiv identifiers. HF
enrichment may add summaries, keywords, upvotes, organization, repository and
project URLs, and linked Hub artifacts. It is optional, tolerant of missing or
new fields, and does not provide the canonical PDF.

Public paper lookup does not require a token. When `HF_TOKEN` is present it is
sent only to an allowlisted Hugging Face host and is never forwarded across a
redirect to another host.

## Testing

All automated source tests use checked-in Atom, JSON, and PDF fixtures or a
local fake transport. CI must not depend on live provider availability.

