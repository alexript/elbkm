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
- Pluggable `elbkm-after-add-functions` and `elbkm-after-delete-functions`
  hooks for reacting to successful add/delete events

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

Alternatively, set `elbkm-use-list-buffer` to `t` (for example in your
`init.el`) to display results in a dedicated `*elbkm-search*` buffer
similar to `*Packages*` from `M-x list-packages`:

```elisp
(custom-set-variables '(elbkm-use-list-buffer t))
```

In that buffer: `RET` opens the entry at point, `a` adds a new bookmark,
`d` deletes the entry at point after confirmation, `g` reloads from storage,
`q` buries the window.  The list is refreshed after a successful add or
delete.

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
| `elbkm-after-add-functions`    | `nil`     | Abnormal hook run after a successful add (see [Hooks](#hooks))    |
| `elbkm-after-delete-functions` | `nil`     | Abnormal hook run after a successful delete (see [Hooks](#hooks)) |

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

### Hooks

`elbkm` exposes two abnormal hooks (use the standard `add-hook` /
`remove-hook` to manage them):

| Hook                              | Fired when                       | Argument                  |
|-----------------------------------|----------------------------------|---------------------------|
| `elbkm-after-add-functions`       | `elbkm-add` successfully persists a bookmark | the newly created bookmark plist |
| `elbkm-after-delete-functions`    | `elbkm-delete` successfully removes a bookmark (after `y-or-n-p` confirmation) | the deleted bookmark plist |

Each function in the hook list is called with the affected bookmark
plist as its single argument.  Errors raised by a hook are demoted to
`*Messages*` and do not interrupt the calling command, so a faulty
hook cannot break `elbkm`.

Example: log every new bookmark via `messages-buffer`:

```elisp
(add-hook 'elbkm-after-add-functions
          (lambda (bm)
            (message "Added bookmark: %s (%s)"
                     (elbkm-bookmark-title bm)
                     (elbkm-bookmark-url bm))))
```

Example: keep a personal audit trail of deletions in a buffer:

```elisp
(add-hook 'elbkm-after-delete-functions
          (lambda (bm)
            (with-current-buffer (get-buffer-create "*elbkm-deleted*")
              (goto-char (point-max))
              (insert (format "- %s | %s\n"
                              (elbkm-bookmark-title bm)
                              (elbkm-bookmark-url bm))))))
```

## Running the tests

```sh
emacs --batch --eval \
  '(let ((load-path (append (list "." "tests") load-path)))
     (require (quote elbkm-bookmark-test))
     (require (quote elbkm-storage-test))
     (ert-run-tests-batch-and-exit t))'
```

## Acknowledgments

`elbkm` stands on the shoulders of great projects:

- [bkm](https://github.com/airRnot1106/bkm) — the original CLI bookmark
  manager by **airRnot1106**, whose design and on-disk format `elbkm` ports
  to Emacs Lisp.
- [Crush](https://github.com/charmbracelet/crush) — the AI coding assistant
  by the **charmbracelet** team, used while developing `elbkm`.
- [GNU Emacs](https://www.gnu.org/software/emacs/) — the extensible,
  customizable, self-documenting real-time display editor and the platform
  that makes `elbkm` possible.  Thanks to all its contributors and
  maintainers over the decades.

## License

MIT.  See [LICENSE](LICENSE).
