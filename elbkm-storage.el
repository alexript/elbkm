;;; elbkm-storage.el --- JSON storage backend for elbkm  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 elbkm contributors

;; Author: elbkm contributors
;; Package-Requires: ((emacs "26.1"))
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

;; JSON-backed bookmark repository for `elbkm'.  Bookmarks are persisted as a
;; JSON array of objects with the keys `id', `url', `title', `description',
;; `tags', `created_at' and `updated_at', mirroring the on-disk format of the
;; original Go `bkm' tool.  The storage path follows the XDG Base Directory
;; Specification, defaulting to `$XDG_DATA_HOME/elbkm/bookmarks.json' (or
;; `~/.local/share/elbkm/bookmarks.json' when XDG_DATA_HOME is unset).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(require 'elbkm-bookmark)

(defgroup elbkm-storage nil
  "Storage configuration for the `elbkm' bookmark manager."
  :group 'external
  :prefix "elbkm-storage-")

(defcustom elbkm-storage-file-path nil
  "Path to the bookmarks JSON file.
When nil, the default XDG-compliant path is used:
`$XDG_DATA_HOME/elbkm/bookmarks.json', or `~/.local/share/elbkm/bookmarks.json'
when XDG_DATA_HOME is unset."
  :type '(choice (const :tag "Use default XDG path" nil)
                 (file :tag "Custom file path")))

(defun elbkm-storage-file-path ()
  "Return the path to the bookmarks storage file."
  (or elbkm-storage-file-path
      (let ((data-home (or (getenv "XDG_DATA_HOME")
                           (expand-file-name "~/.local/share"))))
        (expand-file-name "elbkm/bookmarks.json" data-home))))

(defun elbkm-storage--ensure-dir (file)
  "Create the parent directory of FILE if it does not exist."
  (let ((dir (file-name-directory file)))
    (unless (or (null dir) (file-directory-p dir))
      (make-directory dir t))))

(defun elbkm-storage--alist-get (key alist)
  "Return the value for string KEY from a JSON-decoded ALIST.
Handles keys stored as strings, plain symbols or keyword symbols, since
`json-read' key representation differs across Emacs versions."
  (let ((cell (or (assoc key alist)
                  (assq (intern key) alist)
                  (assq (intern (concat ":" key) obarray) alist)
                  (cl-find-if
                   (lambda (c)
                     (and (consp c)
                          (let ((k (car c)))
                            (and (symbolp k)
                                 (let ((name (symbol-name k)))
                                   (string= (if (string-prefix-p ":" name)
                                                (substring name 1)
                                              name)
                                            key))))))
                   alist))))
    (and (consp cell) (cdr cell))))

(defun elbkm-storage--from-alist (alist)
  "Build a bookmark plist from a JSON-decoded ALIST.
Validate every field, mirroring the Go `fromDTO' conversion."
  (elbkm-bookmark-reconstitute
   (elbkm-storage--alist-get "id" alist)
   (elbkm-storage--alist-get "url" alist)
   (elbkm-storage--alist-get "title" alist)
   (elbkm-storage--alist-get "description" alist)
   (elbkm-storage--alist-get "tags" alist)
   (elbkm-storage--alist-get "created_at" alist)
   (elbkm-storage--alist-get "updated_at" alist)))

(defun elbkm-storage--to-alist (bm)
  "Convert bookmark plist BM into a JSON-serializable alist.
Empty descriptions and missing tag lists are omitted, matching the
`omitempty' behaviour of the original Go DTOs."
  (let ((desc (elbkm-bookmark-description bm))
        (tags (elbkm-bookmark-tags bm)))
    `(("id" . ,(elbkm-bookmark-id bm))
      ("url" . ,(elbkm-bookmark-url bm))
      ("title" . ,(elbkm-bookmark-title bm))
      ,@(unless (or (null desc) (string-empty-p desc))
          `(("description" . ,desc)))
      ,@(when (and tags (consp tags))
          `(("tags" . ,tags)))
      ("created_at" . ,(elbkm-bookmark-created-at bm))
      ("updated_at" . ,(elbkm-bookmark-updated-at bm)))))

(defun elbkm-storage--encode (bookmarks)
  "Encode BOOKMARKS (list of plists) as a pretty-printed JSON string."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-null :null)
        (json-false :false)
        (json-encoding-pretty-print t)
        (json-encoding-default-indentation "  "))
    (json-encode (mapcar #'elbkm-storage--to-alist bookmarks))))

(defun elbkm-storage--write (bookmarks)
  "Write BOOKMARKS (list of plists) to the storage file."
  (let ((file (elbkm-storage-file-path))
        (data (elbkm-storage--encode bookmarks)))
    (elbkm-storage--ensure-dir file)
    (with-temp-file file
      (insert data))))

;;; Repository operations

(defun elbkm-storage-list ()
  "Return a list of all bookmark plists from storage.
Return an empty list when the storage file does not exist or is empty."
  (let ((file (elbkm-storage-file-path)))
    (if (and (file-exists-p file)
             (> (file-attribute-size (file-attributes file)) 0))
        (condition-case nil
            (let* ((json-object-type 'alist)
                   (json-array-type 'list)
                   (json-null nil)
                   (json-false nil)
                   (raw (json-read-file file)))
              (mapcar #'elbkm-storage--from-alist raw))
          (json-error nil))
      nil)))

(defun elbkm-storage-add (bm)
  "Append bookmark plist BM to storage and return BM."
  (let ((bookmarks (elbkm-storage-list)))
    (elbkm-storage--write (append bookmarks (list bm)))
    bm))

(defun elbkm-storage-delete (id)
  "Delete the bookmark whose ID equals ID from storage.  Return t."
  (let* ((bookmarks (elbkm-storage-list))
         (rest (cl-remove-if
                (lambda (bm) (equal (elbkm-bookmark-id bm) id))
                bookmarks)))
    (elbkm-storage--write rest)
    t))

(defun elbkm-storage-update (bm)
  "Replace the bookmark in storage whose ID equals BM's ID with BM.
Preserve the original position in the list.  Return BM, or signal an
error if no bookmark with the same ID exists."
  (let* ((id (elbkm-bookmark-id bm))
         (bookmarks (elbkm-storage-list)))
    (unless (cl-find-if
             (lambda (b) (equal (elbkm-bookmark-id b) id))
             bookmarks)
      (error "no bookmark with id %s" id))
    (let ((replaced
           (cl-mapcar
            (lambda (b)
              (if (equal (elbkm-bookmark-id b) id) bm b))
            bookmarks)))
      (elbkm-storage--write replaced)
      bm)))

(provide 'elbkm-storage)
;;; elbkm-storage.el ends here
