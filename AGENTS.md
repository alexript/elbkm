# AGENTS.md

Guidance for AI agents working on the **elbkm** codebase.

## Project overview

`elbkm` is an Emacs Lisp bookmark manager. It is a port of the Go CLI tool
[`bkm`](https://github.com/airRnot1106/bkm), re-expressed as an Emacs package:
instead of subcommands and flags, functionality is exposed through interactive
commands callable via `M-x` (or from Lisp with function arguments).

- **Language:** Emacs Lisp (target Emacs 26.1+)
- **License:** MIT (see [`LICENSE`](LICENSE))
- **Domain:** bookmark management — add, search/open, delete bookmarks
- **Storage:** JSON array at `$XDG_DATA_HOME/elbkm/bookmarks.json`
  (defaults to `~/.local/share/elbkm/bookmarks.json`), on-disk format
  compatible with the original Go `bkm`.

## Architecture (mirrors the original Go layering)

```
elbkm-bookmark.el   <- internal/bookmark/   value objects + validation + UUID
elbkm-storage.el    <- internal/storage/    JSON repository (Add/List/Delete)
elbkm.el            <- cmd/ + usecase/      interactive commands (M-x)
tests/              <- *_test.go            ERT test suite
```

### Domain layer — `elbkm-bookmark.el`

A bookmark is a plist:

```elisp
(:id UUID :url URL :title TITLE :description DESC
      :tags (TAG...) :created-at ISO8601 :updated-at ISO8601)
```

- `elbkm-bookmark-validate-{url,title,description,tags,id}` — return the
  normalized value or signal `error`. Validation rules:
  - URL: non-empty, must have a scheme and host (parsed via
    `url-generic-parse-url`).
  - Title: non-empty after trimming.
  - Description: any string, trimmed (may be empty).
  - Tags: each element non-empty after trimming; `nil` accepted (no tags).
  - ID: canonical or no-dash UUID.
- `elbkm-bookmark-generate-id` — random version-4 UUID (pure Elisp).
- `elbkm-bookmark-create` — builds a bookmark with a fresh ID and timestamps.
- `elbkm-bookmark-reconstitute` — rebuilds a bookmark from persisted fields,
  validating each (used by storage on read).
- Accessors: `elbkm-bookmark-{id,url,title,description,tags,created-at,updated-at}`.

Keep this layer dependency-free (only `subr-x` and `url-parse`).

### Storage layer — `elbkm-storage.el`

JSON repository implementing the same `Add/List/Delete` contract as the Go
`Repository` interface.

- `elbkm-storage-file-path` (defcustom, default nil) — nil means use the
  XDG-compliant default path. Tests override it with a temp path.
- `elbkm-storage--to-alist` / `--from-alist` — JSON <-> plist conversion.
  `omitempty` parity with Go: empty description and nil/empty tags are omitted
  on write.
- `elbkm-storage-list` tolerates a missing or empty file (returns nil) instead
  of erroring — more user-friendly than the strict Go behavior; preserve this.
- `elbkm-storage--alist-get` is key-type-agnostic because `json-read` may
  produce string, symbol, or keyword keys depending on Emacs version. Do not
  "simplify" it to a single key type.

### Commands layer — `elbkm.el`

Interactive commands (autoloaded):

| Command | Args | Behavior |
|---|---|---|
| `elbkm-add` | `&optional url title description tags` | Prompt for nil args (validated loop); create + persist bookmark. |
| `elbkm-search` | `&optional tags` | Filter by tags, `completing-read`, open via `elbkm-open-function`. |
| `elbkm-delete` | `&optional tags` | Filter, select, confirm with `y-or-n-p`, delete. |

Design rules to preserve:

- **`nil` triggers a prompt; a non-nil value is used verbatim.** This is the
  Emacs-idiomatic replacement for the Go "flags provided vs interactive" split.
  In Elisp only `nil` is falsy, so an empty string passed explicitly is treated
  as a real (empty) value, not as "missing". Keep this contract.
- Selection uses **`completing-read`** (not a bespoke fuzzy UI) so any
  completion framework works. Do not hardcode a dependency on Vertico/Ivy/etc.
- Opening uses **`elbkm-open-function`** (defaults to `browse-url`) instead of
  shelling out to `xdg-open`/`open`/`start`.
- `tags` arguments accept either a comma-separated string or a list of strings
  (`elbkm--normalize-tags` handles both).
- Tag filtering is an **AND** of all target tags (a bookmark matches only if it
  has every requested tag), matching the original.

## Conventions

- **Lexical binding** is mandatory (`-*- lexical-binding: t; -*-`).
- One feature per file; `provide` the feature at the end, `;;; file ends here`.
- Public commands get `;;;###autoload`; internal helpers use a `--` name prefix.
- Docstrings on every public function; keep docstring lines ≤ 80 chars.
- No external package dependencies — Emacs built-ins only (`json`, `url-parse`,
  `browse-url`, `cl-lib`, `subr-x`, `ert`).
- Byte-compilation must be warning-clean.

## Build, test, lint

```sh
# Byte-compile (should be warning-free)
emacs --batch --eval \
  '(let ((load-path (cons "." load-path)))
     (byte-compile-file "elbkm-bookmark.el")
     (byte-compile-file "elbkm-storage.el")
     (byte-compile-file "elbkm.el"))'

# Run the ERT suite (must be all green)
emacs --batch --eval \
  '(let ((load-path (append (list "." "tests") load-path)))
     (require (quote elbkm-bookmark-test))
     (require (quote elbkm-storage-test))
     (ert-run-tests-batch-and-exit t))'
```

When changing the domain or storage layers, **run both** — the storage tests
exercise `elbkm-bookmark-reconstitute` on real JSON round-trips.

There is no Makefile or CI; the commands above are the canonical check.

## Testing notes

- Tests live in `tests/` as ERT (`ert-deftest`), mirroring the original Go
  `*_test.go` cases one-to-one where practical.
- Storage tests use a fresh temp file per test by let-binding
  `elbkm-storage-file-path` to `elbkm-storage-test--fresh-file`. Do not mutate
  the real user storage path in tests.
- `should-error` is used where the Go tests check for a returned error.
- When adding a domain rule, add a corresponding ERT case in
  `tests/elbkm-bookmark-test.el`; when changing storage behavior, add a case in
  `tests/elbkm-storage-test.el`.

## Things to avoid

- Do not reintroduce a CLI/subcommand dispatcher — control flow is via function
  arguments and `interactive`, by design.
- Do not depend on a specific completion UI.
- Do not store secrets or log bookmark contents.
- Do not change the on-disk JSON key names (`id`, `url`, `title`,
  `description`, `tags`, `created_at`, `updated_at`) — compatibility with the
  Go `bkm` format is intentional.
