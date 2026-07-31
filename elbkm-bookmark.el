;;; elbkm-bookmark.el --- Bookmark domain types and validation  -*- lexical-binding: t; -*-

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

;; This package implements the bookmark domain model for `elbkm', the Emacs
;; Lisp port of the `bkm' command-line bookmark manager.  A bookmark is
;; represented as a property list:
;;
;;     (:id ID :url URL :title TITLE :description DESC
;;          :tags (TAG...) :created-at TIME :updated-at TIME)
;;
;; where ID is a UUID string, URL/TITLE/DESC/TAG are strings and TIME is an
;; ISO 8601 string.  Constructor and validation functions mirror the value
;; objects of the original Go package.

;;; Code:

(require 'subr-x)
(require 'url-parse)

(defconst elbkm-bookmark-version "1.0.0"
  "Version of the `elbkm-bookmark' domain package.")

;;; UUID

(defun elbkm-bookmark-valid-id-p (id)
  "Return non-nil (t) if ID is a valid UUID string (canonical or no-dash form)."
  (and (stringp id)
       (let ((case-fold-search t))
         (or (string-match-p
              "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'"
              id)
             (string-match-p
              "\\`[0-9a-f]\\{32\\}\\'" id)))
       t))

(defun elbkm-bookmark-generate-id ()
  "Generate and return a random version 4 UUID string."
  (let* ((r16 (lambda () (format "%04x" (random 65536))))
         (r12 (lambda () (format "%03x" (random 4096))))
         (r8  (+ 8 (random 4))))
    (concat
     (funcall r16) (funcall r16)                 ; 8 hex
     "-"
     (funcall r16)                               ; 4 hex
     "-"
     (format "4%s" (funcall r12))                ; version 4
     "-"
     (format "%x%s" r8 (funcall r12))            ; variant (8,9,a,b)
     "-"
     (funcall r16) (funcall r16) (funcall r16)))) ; 12 hex

(defun elbkm-bookmark-validate-id (id)
  "Validate ID and return it, or signal an error if it is not a UUID."
  (unless (elbkm-bookmark-valid-id-p id)
    (error "invalid UUID format"))
  id)

;;; URL

(defun elbkm-bookmark-valid-url-p (url)
  "Return non-nil (t) if URL is a valid bookmark URL.
A valid URL is non-empty and has a scheme and a host."
  (and (stringp url)
       (not (string-empty-p url))
       (let* ((parsed (condition-case nil
                          (url-generic-parse-url url)
                        (error nil)))
              (type (and parsed (url-type parsed)))
              (host (and parsed (url-host parsed))))
         (and (stringp type) (not (string-empty-p type))
              (stringp host) (not (string-empty-p host))))
       t))

(defun elbkm-bookmark-validate-url (url)
  "Validate URL and return it, or signal an error if it is malformed."
  (unless (elbkm-bookmark-valid-url-p url)
    (error "invalid URL format"))
  url)

;;; Title

(defun elbkm-bookmark-validate-title (title)
  "Validate TITLE, returning the trimmed string or signaling an error."
  (let ((trimmed (string-trim (or title ""))))
    (when (string-empty-p trimmed)
      (error "title cannot be empty"))
    trimmed))

;;; Description

(defun elbkm-bookmark-validate-description (description)
  "Validate DESCRIPTION, returning the trimmed string (may be empty)."
  (string-trim (or description "")))

;;; Tags

(defun elbkm-bookmark-validate-tags (tags)
  "Validate TAGS (a list of strings), returning a list of trimmed strings.
Signal an error if any element is empty or whitespace only."
  (let ((result nil))
    (dolist (tag tags (nreverse result))
      (let ((trimmed (string-trim (or tag ""))))
        (when (string-empty-p trimmed)
          (error "tag cannot be empty"))
        (push trimmed result)))))

;;; Bookmark

(defun elbkm-bookmark-make (id url title description tags created-at updated-at)
  "Return a bookmark plist built from the given fields."
  (list :id id
        :url url
        :title title
        :description description
        :tags tags
        :created-at created-at
        :updated-at updated-at))

(defun elbkm-bookmark-reconstitute (id url title description tags
                                       created-at updated-at)
  "Reconstitute a bookmark from persisted fields, validating each one.
This mirrors the `fromDTO' conversion in the original Go storage layer."
  (elbkm-bookmark-make
   (elbkm-bookmark-validate-id id)
   (elbkm-bookmark-validate-url url)
   (elbkm-bookmark-validate-title title)
   (elbkm-bookmark-validate-description description)
   (elbkm-bookmark-validate-tags tags)
   created-at updated-at))

(defun elbkm-bookmark-create (url title description tags)
  "Create and return a new bookmark plist with a generated ID and timestamps.
Signal an error if URL or TITLE is invalid or any TAG is invalid."
  (let ((now (elbkm-bookmark--now-iso)))
    (elbkm-bookmark-make
     (elbkm-bookmark-generate-id)
     (elbkm-bookmark-validate-url url)
     (elbkm-bookmark-validate-title title)
     (elbkm-bookmark-validate-description description)
     (elbkm-bookmark-validate-tags tags)
     now now)))

(defun elbkm-bookmark-update (bm url title description tags)
  "Return a new bookmark plist derived from BM with the given fields.
The new plist keeps BM's :id and :created-at, and gets a fresh
`:updated-at'.  URL, TITLE, DESCRIPTION and TAGS are validated with the
same rules as `elbkm-bookmark-create'."
  (let ((updated-at (elbkm-bookmark--now-iso)))
    (elbkm-bookmark-make
     (elbkm-bookmark-id bm)
     (elbkm-bookmark-validate-url url)
     (elbkm-bookmark-validate-title title)
     (elbkm-bookmark-validate-description description)
     (elbkm-bookmark-validate-tags tags)
     (elbkm-bookmark-created-at bm)
     updated-at)))

(defun elbkm-bookmark--now-iso ()
  "Return the current time as an ISO 8601 string."
  (concat (format-time-string "%Y-%m-%dT%H:%M:%S" (current-time)) "Z"))

;;; Accessors

(defun elbkm-bookmark-id (bm)
  "Return the ID of bookmark BM."
  (plist-get bm :id))

(defun elbkm-bookmark-url (bm)
  "Return the URL of bookmark BM."
  (plist-get bm :url))

(defun elbkm-bookmark-title (bm)
  "Return the title of bookmark BM."
  (plist-get bm :title))

(defun elbkm-bookmark-description (bm)
  "Return the description of bookmark BM."
  (plist-get bm :description))

(defun elbkm-bookmark-tags (bm)
  "Return the tags (list of strings) of bookmark BM."
  (plist-get bm :tags))

(defun elbkm-bookmark-created-at (bm)
  "Return the creation timestamp of bookmark BM."
  (plist-get bm :created-at))

(defun elbkm-bookmark-updated-at (bm)
  "Return the last-update timestamp of bookmark BM."
  (plist-get bm :updated-at))

(provide 'elbkm-bookmark)
;;; elbkm-bookmark.el ends here
