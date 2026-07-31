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

When called from Lisp, TAGS may be a list of strings or a comma-separated
string.  Pass nil to search all bookmarks.

Return the opened bookmark plist, or nil if the user cancelled."
  (interactive)
  (let* ((tags (elbkm--normalize-tags (or tags (elbkm--read-tags))))
         (bookmarks (elbkm-storage-list))
         (filtered (elbkm--filter-by-tags bookmarks tags))
         (bm (elbkm--select-bookmark filtered)))
    (if bm
        (progn
          (funcall elbkm-open-function (elbkm-bookmark-url bm))
          (message "Opening: %s" (elbkm-bookmark-url bm))
          bm)
      (message "Cancelled.")
      nil)))

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
