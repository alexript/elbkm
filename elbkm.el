;;; elbkm.el --- Bookmark manager for Emacs  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 elbkm contributors

;; Author: elbkm contributors
;; Version: 1.0.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: hypermedia, convenience, bookmarks
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; `elbkm' is an Emacs Lisp port of the `bkm' command-line bookmark manager.
;; Where `bkm' is driven by subcommands and flags, `elbkm' exposes its
;; functionality through interactive commands reachable via `M-x':
;;
;;     M-x elbkm-add           Add a bookmark (interactive or programmatic).
;;     M-x elbkm-search        Fuzzy-search bookmarks and open one in a browser.
;;     M-x elbkm-delete        Fuzzy-search bookmarks and delete one.
;;
;; Each command also accepts arguments when called from Lisp, so they can be
;; used non-interactively.  Bookmark selection uses `completing-read', which
;; integrates with any completion framework (Icomplete, Vertico, Ivy, Helm,
;; Selectrum, ...).  Opening a bookmark delegates to `browse-url'.
;;
;; When `org-capture' is loaded, `elbkm' registers a template under key "b"
;; so selecting "b" from `org-capture' adds a bookmark via `elbkm-add'.
;;
;; Bookmarks are stored as JSON under
;; `$XDG_DATA_HOME/elbkm/bookmarks.json' (or `~/.local/share/elbkm/bookmarks.json'),
;; the same layout used by the original Go tool.
;;
;; After a bookmark is successfully added or deleted, every function in
;; `elbkm-after-add-functions' or `elbkm-after-delete-functions'
;; (respectively) is invoked with the affected bookmark plist as its
;; single argument.  These are abnormal hooks: use `add-hook' to register.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

(require 'elbkm-bookmark)
(require 'elbkm-storage)

(defgroup elbkm nil
  "Bookmark manager for Emacs."
  :group 'external
  :link '(url-link :tag "Original bkm" "https://github.com/airRnot1106/bkm"))

(defcustom elbkm-open-function #'browse-url
  "Function called with a URL to open a bookmark.
Defaults to `browse-url', which respects `browse-url-browser-function'."
  :type 'function)

(defcustom elbkm-after-add-functions nil
  "Abnormal hook run after a bookmark is successfully added.

Each function is called with one argument: the newly created bookmark
plist.  Use `add-hook' to register.  Errors in a hook are demoted to
messages and do not interrupt the user's flow."
  :type 'hook)

(defcustom elbkm-after-delete-functions nil
  "Abnormal hook run after a bookmark is successfully deleted.

Each function is called with one argument: the bookmark plist that was
just removed from storage.  Use `add-hook' to register.  Errors in a hook
are demoted to messages and do not interrupt the user's flow."
  :type 'hook)

(defcustom elbkm-use-list-buffer nil
  "When non-nil, `elbkm-search' shows results in a dedicated buffer.
The buffer, named `*elbkm-search*', uses `tabulated-list-mode' so it
behaves like `*Packages*' from `M-x list-packages': RET on an entry
opens the bookmark URL via `elbkm-open-function'; `g' refreshes the
buffer from storage; `q' buries the window.
When this option is nil, `elbkm-search' uses `completing-read' as
before."
  :type 'boolean)

(defvar elbkm-history nil
  "Minibuffer history for `elbkm' commands.")

;;; Helpers

(defun elbkm--normalize-tags (tags)
  "Normalize TAGS into a list of trimmed non-empty strings.
Accepts nil, a comma-separated string, or a list of strings."
  (cond
   ((null tags) nil)
   ((stringp tags)
    (if (string-empty-p (string-trim tags))
        nil
      (mapcar #'string-trim (split-string tags ","))))
   ((consp tags)
    (delq nil (mapcar
               (lambda (tag)
                 (let ((trimmed (string-trim tag)))
                   (and (not (string-empty-p trimmed)) trimmed)))
               tags)))
   (t nil)))

(defun elbkm--filter-by-tags (bookmarks tags)
  "Return the subset of BOOKMARKS that contain every tag in TAGS.
TAGS is a list of strings.  When TAGS is nil, BOOKMARKS is returned as-is."
  (if (or (null tags) (null bookmarks))
      bookmarks
    (let ((targets (mapcar #'string-trim tags)))
      (cl-remove-if-not
       (lambda (bm)
         (let ((bm-tags (elbkm-bookmark-tags bm)))
           (cl-every (lambda (tag) (member tag bm-tags)) targets)))
       bookmarks))))

(defun elbkm--format-bookmark (bm)
  "Return a single-line display string for bookmark BM."
  (format "%s | %s | %s | %s"
          (elbkm-bookmark-title bm)
          (elbkm-bookmark-url bm)
          (mapconcat #'identity (elbkm-bookmark-tags bm) ",")
          (elbkm-bookmark-description bm)))

(defun elbkm--select-bookmark (bookmarks)
  "Let the user select a bookmark from BOOKMARKS via `completing-read'.
Return the selected bookmark plist, or nil if the user cancelled."
  (if (null bookmarks)
      (error "No bookmarks to select from")
    (let* ((candidates (mapcar
                        (lambda (bm)
                          (cons (elbkm--format-bookmark bm) bm))
                        bookmarks))
           (choice (condition-case nil
                       (completing-read "Bookmark: " candidates nil t)
                     (quit nil))))
      (when choice
        (cdr (assoc choice candidates))))))

(defun elbkm--display-bookmark (bm)
  "Print a human-readable summary of bookmark BM to the echo area."
  (let* ((desc (elbkm-bookmark-description bm))
         (tags (mapconcat #'identity (elbkm-bookmark-tags bm) ", "))
         (parts (list (format "Title: %s" (elbkm-bookmark-title bm))
                      (format "URL:   %s" (elbkm-bookmark-url bm))))
         (with-desc (if (and desc (not (string-empty-p desc)))
                        (append parts (list (format "Desc:  %s" desc)))
                      parts))
         (with-tags (if (and tags (not (string-empty-p tags)))
                        (append with-desc (list (format "Tags:  %s" tags)))
                      with-desc)))
    (message "%s" (mapconcat #'identity with-tags "\n"))))

(defun elbkm--run-hooks-with-bookmark (functions bookmark)
  "Run each function in FUNCTIONS with BOOKMARK as its single argument.
Errors raised by a hook are demoted to messages and do not stop later
hooks or the calling command."
  (dolist (fn functions)
    (with-demoted-errors "elbkm hook error: %S"
      (funcall fn bookmark))))

;;; Interactive input

(defun elbkm--read-url ()
  "Read a URL from the minibuffer, re-prompting until it is valid."
  (let ((prompt "URL: "))
    (catch 'done
      (while t
        (let ((input (read-string prompt nil 'elbkm-history)))
          (condition-case nil
              (progn (elbkm-bookmark-validate-url input)
                     (throw 'done input))
            (error (setq prompt "Invalid URL. URL: "))))))))

(defun elbkm--read-title ()
  "Read a title from the minibuffer, re-prompting until it is non-empty."
  (let ((prompt "Title: "))
    (catch 'done
      (while t
        (let ((input (read-string prompt nil 'elbkm-history)))
          (condition-case nil
              (progn (elbkm-bookmark-validate-title input)
                     (throw 'done input))
            (error (setq prompt "Title cannot be empty. Title: "))))))))

(defun elbkm--read-description ()
  "Read an optional description from the minibuffer."
  (read-string "Description: " nil 'elbkm-history))

(defun elbkm--read-tags ()
  "Read optional comma-separated tags from the minibuffer.
Return a list of trimmed strings, or nil when left empty."
  (let ((prompt "Tags (comma-separated, optional): "))
    (catch 'done
      (while t
        (let* ((input (read-string prompt nil 'elbkm-history))
               (trimmed (string-trim input)))
          (if (string-empty-p trimmed)
              (throw 'done nil)
            (let ((norm (elbkm--normalize-tags input)))
              (condition-case nil
                  (progn (elbkm-bookmark-validate-tags norm)
                         (throw 'done norm))
                (error
                 (setq prompt "Invalid tag. Tags (comma-separated): "))))))))))

;;; Commands

;;;###autoload
(defun elbkm-add (&optional url title description tags)
  "Add a bookmark.

Interactively, prompt for URL, TITLE, DESCRIPTION and TAGS in the
minibuffer, validating each field as it is entered.

When called from Lisp, every argument is optional.  Any nil argument is
prompted for interactively; a non-nil argument is used verbatim (an empty
string is valid only for DESCRIPTION).  TAGS may be a list of strings or a
comma-separated string.

Return the newly created bookmark plist."
  (interactive)
  (let* ((url (or url (elbkm--read-url)))
         (title (or title (elbkm--read-title)))
         (description (or description (elbkm--read-description)))
         (tags (elbkm--normalize-tags
                (or tags (elbkm--read-tags))))
         (bm (elbkm-bookmark-create url title description tags)))
    (elbkm-storage-add bm)
    (message "Bookmark added: %s — %s"
             (elbkm-bookmark-title bm)
             (elbkm-bookmark-url bm))
    (elbkm--run-hooks-with-bookmark elbkm-after-add-functions bm)
    bm))

;;;###autoload
(defun elbkm-search (&optional tags)
  "Search bookmarks and open the selected one in a browser.

Interactively, prompt for optional comma-separated TAGS used to filter the
candidate list, then select a bookmark with `completing-read' and open its
URL with `elbkm-open-function' (by default `browse-url').

When `elbkm-use-list-buffer' is non-nil, results are shown in the
dedicated `*elbkm-search*' buffer instead, using `tabulated-list-mode'
(similar to `*Packages*' from `M-x list-packages').  In that buffer,
RET opens the entry at point via `elbkm-open-function', `g' reloads
from storage, and `q' buries the window.

When called from Lisp, TAGS may be a list of strings or a comma-separated
string.  Pass nil to search all bookmarks.

Return the opened bookmark plist, or nil if the user cancelled.
When the list-buffer UI is active, return the buffer object instead."
  (interactive)
  (let ((tags (elbkm--normalize-tags (or tags (elbkm--read-tags)))))
    (if elbkm-use-list-buffer
        (elbkm-search-list-show tags)
      (let* ((bookmarks (elbkm-storage-list))
             (filtered (elbkm--filter-by-tags bookmarks tags))
             (bm (elbkm--select-bookmark filtered)))
        (if bm
            (progn
              (funcall elbkm-open-function (elbkm-bookmark-url bm))
              (message "Opening: %s" (elbkm-bookmark-url bm))
              bm)
          (message "Cancelled.")
          nil)))))

;;; Search list buffer (`tabulated-list-mode' based UI)

(defvar-local elbkm-search-list--tags nil
  "Tag filter active in the current `*elbkm-search*' buffer.
Buffer-local so `revert-buffer' (`g') reapplies it on refresh.")

(defvar-local elbkm-search-list--entries nil
  "List of bookmark plists currently shown in the `*elbkm-search*' buffer.
Buffer-local; preserves display order so the bookmark at point can be
resolved from the ID returned by `tabulated-list-get-id'.")

(defvar elbkm-search-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'elbkm-search-list--open)
    map)
  "Keymap for `elbkm-search-list-mode'.")

(define-derived-mode elbkm-search-list-mode tabulated-list-mode "elbkm-search"
  "Major mode for browsing elbkm search results.
Inherits from `tabulated-list-mode'.  RET opens the bookmark at point
via `elbkm-open-function'; `g' reloads the buffer from storage; `q'
buries the window."
  (setq tabulated-list-format
        [("Title" 40 t)
         ("URL" 50 t)
         ("Tags" 20 t)
         ("Description" 0 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "Title" nil))
  (setq revert-buffer-function #'elbkm-search-list--revert))

(defun elbkm-search-list--revert (&optional _ignore-auto _noconfirm)
  "Refresh the `*elbkm-search*' buffer from storage, preserving filter."
  (elbkm-search-list--populate elbkm-search-list--tags))

(defun elbkm-search-list--entry (bm)
  "Return a `tabulated-list-entry' describing bookmark BM."
  (let* ((id (elbkm-bookmark-id bm))
         (tags (mapconcat #'identity (elbkm-bookmark-tags bm) ", "))
         (cols (vector (elbkm-bookmark-title bm)
                       (elbkm-bookmark-url bm)
                       (or tags "")
                       (elbkm-bookmark-description bm))))
    (list id cols)))

(defun elbkm-search-list--populate (&optional tags)
  "Replace current buffer's entries with bookmarks filtered by TAGS.
TAGS is a list of tag strings or nil (no filter)."
  (let* ((bookmarks (elbkm-storage-list))
         (filtered (elbkm--filter-by-tags bookmarks tags)))
    (setq elbkm-search-list--tags tags
          elbkm-search-list--entries filtered)
    (setq tabulated-list-entries
          (mapcar #'elbkm-search-list--entry filtered))
    (tabulated-list-print t nil)))

(defun elbkm-search-list--bookmark-at-point ()
  "Return the bookmark plist at point in the search list buffer, or nil."
  (let ((id (tabulated-list-get-id)))
    (when id
      (cl-find-if (lambda (b) (equal (elbkm-bookmark-id b) id))
                  elbkm-search-list--entries))))

(defun elbkm-search-list--open ()
  "Open the bookmark at point via `elbkm-open-function'."
  (interactive)
  (let ((bm (elbkm-search-list--bookmark-at-point)))
    (unless bm
      (user-error "No bookmark at point"))
    (funcall elbkm-open-function (elbkm-bookmark-url bm))
    (message "Opening: %s" (elbkm-bookmark-url bm))))

(defun elbkm-search-list-show (tags)
  "Display bookmarks in the `*elbkm-search*' buffer filtered by TAGS.
TAGS is a list of strings, a comma-separated string, or nil (no
filter).  Reuses an existing buffer if present, otherwise creates one
and activates `elbkm-search-list-mode'.  Returns the buffer."
  (let* ((buf-name "*elbkm-search*")
         (tags (elbkm--normalize-tags tags))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'elbkm-search-list-mode)
        (elbkm-search-list-mode))
      (elbkm-search-list--populate tags))
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun elbkm-delete (&optional tags)
  "Search bookmarks and delete the selected one.

Interactively, prompt for optional comma-separated TAGS to filter the
candidate list, select a bookmark with `completing-read', show its details
and ask for confirmation before deleting it.

When called from Lisp, TAGS may be a list of strings or a comma-separated
string.  Pass nil to consider all bookmarks.

Return t if a bookmark was deleted, nil otherwise."
  (interactive)
  (let* ((tags (elbkm--normalize-tags (or tags (elbkm--read-tags))))
         (bookmarks (elbkm-storage-list))
         (filtered (elbkm--filter-by-tags bookmarks tags))
         (bm (elbkm--select-bookmark filtered)))
    (cond
     ((null bm)
      (message "Deletion cancelled.")
      nil)
     ((y-or-n-p (format "Delete %s? " (elbkm-bookmark-title bm)))
      (elbkm-storage-delete (elbkm-bookmark-id bm))
      (message "Bookmark deleted: %s" (elbkm-bookmark-title bm))
      (elbkm--run-hooks-with-bookmark elbkm-after-delete-functions bm)
      t)
     (t
      (message "Deletion cancelled.")
      nil))))

;;; Org-capture integration

;; Declared in `org-capture' (loaded lazily below); tell the byte-compiler.
(defvar org-capture-templates)

(defun elbkm--org-capture-add ()
  "Add a bookmark from inside `org-capture' and return an empty string.
This is the function bound to the `elbkm' `org-capture' template body.
It calls `elbkm-add' for its side effects (creating and persisting a
bookmark) and returns \"\" so that nothing is inserted into the capture
target.  With `:immediate-finish t' the capture finalizes immediately
without ever showing the buffer to the user."
  (elbkm-add)
  "")

;;;###autoload
(defun elbkm-register-org-capture-template ()
  "Register an `org-capture' template that adds a bookmark via `elbkm-add'.

The template uses key \"b\" and description \"Bookmark\".  It invokes
`elbkm--org-capture-add' and is finalized immediately, so selecting \"b\"
from `org-capture' simply runs `elbkm-add' interactively.

This is called automatically when `org-capture' is loaded (see
`with-eval-after-load' below), but it is exposed as a public command so
users can call it manually after customizing `org-capture-templates'."
  (add-to-list 'org-capture-templates
               '("b" "Bookmark" plain (file "")
                 "%(elbkm--org-capture-add)"
                 :immediate-finish t)))

;;;###autoload
(with-eval-after-load 'org-capture
  (elbkm-register-org-capture-template))

(provide 'elbkm)
;;; elbkm.el ends here
