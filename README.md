<div align="center">
<samp>

# elbkm

Bookmark manager for Emacs, integrated with `completing-read`

</samp>
</div>

`elbkm` is an Emacs Lisp port of the [`bkm`](https://github.com/airRnot1106/bkm)
command-line bookmark manager.  Where `bkm` is driven by subcommands and
flags, `elbkm` exposes its functionality through interactive commands
reachable via `M-x`.  Bookmark selection uses `completing-read`, so it works
with any completion framework (Icomplete/Fido, Vertico, Ivy, Helm, Selectrum,
…), and opening a bookmark delegates to `browse-url`.

## Features

- Add bookmarks via an interactive minibuffer flow (with validation)
- Add bookmarks directly by passing arguments from Lisp
- Search bookmarks with `completing-read` (fuzzy/filtered by your framework)
- Open the selected bookmark in your browser (`browse-url`)
- Delete bookmarks with a confirmation prompt
- Filter candidates by tags
- Registers an `org-capture` template under key `b` when `org-capture` is loaded

## Installation

### Manual

Add the directory to `load-path` and load the package:

```elisp
(add-to-list 'load-path "/path/to/elbkm")
(require 'elbkm)
```

### Straight.el / use-package

```elisp
(use-package elbkm
  :straight (elbkm :type git :host github :repo "alexript/elbkm"))
```

The three commands are autoloaded, so you can call `M-x elbkm-add`,
`M-x elbkm-search` and `M-x elbkm-delete` right away.

## Data storage

Bookmarks are stored as a JSON array in:

- `$XDG_DATA_HOME/elbkm/bookmarks.json` (when `XDG_DATA_HOME` is set)
- `~/.local/share/elbkm/bookmarks.json` otherwise

This follows the XDG Base Directory Specification and is compatible with the
on-disk format of the original Go `bkm` tool.  Override the path with
`elbkm-storage-file-path`.

## Usage

All commands are callable interactively (`M-x`) or from Lisp with arguments.
Any `nil` argument is prompted for in the minibuffer.

### Add a bookmark

Interactive (prompts for each field, validating as you type):

```
M-x elbkm-add
```

From Lisp:

```elisp
(elbkm-add "https://example.com" "Example Site"
           "An example website" "example,web")
```

Arguments (all optional — `nil` triggers a prompt):

| Argument     | Description                          |
|--------------|--------------------------------------|
| `url`        | URL of the bookmark (required)       |
| `title`      | Title of the bookmark (required)     |
| `description` | Description (optional, may be empty) |
| `tags`        | List of strings or comma-separated string |

### Search and open a bookmark

```
M-x elbkm-search
```

From Lisp, filter by tags:

```elisp
(elbkm-search "go,cli")     ; comma-separated string
(elbkm-search '("go" "cli")) ; or a list
(elbkm-search)               ; search all bookmarks
```

You will be presented with a `completing-read` list where you can:

1. Type to filter bookmarks
2. Navigate with arrow keys / `C-n` / `C-p`
3. Press `RET` to open the selected bookmark in your browser
4. Press `C-g` to cancel

### Delete a bookmark

```
M-x elbkm-delete
```

From Lisp:

```elisp
(elbkm-delete "go,cli")
```

This opens the selector to pick a bookmark, then asks for confirmation before
deleting it.

### Org-capture integration

When `org-capture` is loaded, `elbkm` automatically registers a template
under key `b`.  Selecting `b` from `org-capture` runs `elbkm-add`
interactively and finalizes immediately without inserting anything into
the capture target.

To register it manually (for example after customizing
`org-capture-templates`), call:

```elisp
M-x elbkm-register-org-capture-template
```

## Configuration

| Variable                  | Default        | Description                                                  |
|---------------------------|----------------|--------------------------------------------------------------|
| `elbkm-storage-file-path` | XDG default    | Path to the bookmarks JSON file                              |
| `elbkm-open-function`     | `browse-url`   | Function called with a URL to open a bookmark                |
| `elbkm-history`           | `nil`          | Minibuffer history shared by `elbkm-add`, `-search`, `-delete` |

`elbkm-storage-file-path` defaults to
`$XDG_DATA_HOME/elbkm/bookmarks.json` (or
`~/.local/share/elbkm/bookmarks.json` when `XDG_DATA_HOME` is unset).
The parent directory is created automatically on the first write, so
pointing it at any writable path works out of the box.  You can also set
it interactively via `M-x customize-variable`.

`elbkm-open-function` is invoked with the bookmark URL as its single
argument.  The default `browse-url` honours `browse-url-browser-function`,
so configuring your browser there is enough for `elbkm` to follow suit.
Override it to integrate with another tool, e.g.:

```elisp
(setq elbkm-open-function
      (lambda (url) (start-process "bkm-open" nil "xdg-open" url)))
```

`elbkm-history` is the minibuffer history list shared by `elbkm-add`,
`-search` and `-delete`.  Emacs populates it as you use the commands;
you usually do not need to touch it.  Customize `history-length` to
control how many entries are retained.

## Running the tests

```sh
emacs --batch --eval \
  '(let ((load-path (append (list "." "tests") load-path)))
     (require (quote elbkm-bookmark-test))
     (require (quote elbkm-storage-test))
     (ert-run-tests-batch-and-exit t))'
```

## License

MIT.  See [LICENSE](LICENSE).
