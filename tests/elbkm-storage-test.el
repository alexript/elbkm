;;; elbkm-storage-test.el --- Tests for elbkm-storage  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 elbkm contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the `elbkm-storage' JSON repository, mirroring the test
;; cases of the original Go `bkm' internal/storage package.

;;; Code:

(require 'ert)
(require 'elbkm-bookmark)
(require 'elbkm-storage)

(defun elbkm-storage-test--fresh-file ()
  "Return a path for a fresh storage file in a temp directory."
  (expand-file-name "bookmarks.json" (make-temp-file "elbkm-storage-" "-dir")))

(ert-deftest elbkm-storage-test/custom-path-creates-dir ()
  "Setting a custom path creates the parent directory."
  (let* ((dir (make-temp-file "elbkm-dir-" "-dir"))
         (nested (expand-file-name "a/b/bookmarks.json" dir))
         (elbkm-storage-file-path nested))
    (elbkm-storage--write nil)
    (should (file-exists-p nested))))

(ert-deftest elbkm-storage-test/list-empty-when-no-file ()
  "list returns nil when the storage file does not exist."
  (let ((elbkm-storage-file-path
         (expand-file-name "does-not-exist.json" temporary-file-directory)))
    (should (eq (elbkm-storage-list) nil))))

(ert-deftest elbkm-storage-test/add-and-list ()
  "Adding a bookmark then listing retrieves it back."
  (let ((elbkm-storage-file-path (elbkm-storage-test--fresh-file)))
    (let ((bm (elbkm-bookmark-create "https://example.com" "Example"
                                      "Test description" (list "go" "test"))))
      (should (elbkm-storage-add bm)))
    (let ((all (elbkm-storage-list)))
      (should (= (length all) 1))
      (should (equal (elbkm-bookmark-url (car all)) "https://example.com"))
      (should (equal (elbkm-bookmark-title (car all)) "Example"))
      (should (equal (elbkm-bookmark-tags (car all)) (list "go" "test"))))))

(ert-deftest elbkm-storage-test/multiple-bookmarks ()
  "Multiple bookmarks are persisted and listed in order."
  (let ((elbkm-storage-file-path (elbkm-storage-test--fresh-file)))
    (dotimes (i 3)
      (elbkm-storage-add
       (elbkm-bookmark-create
        (format "https://example%d.com" (1+ i))
        (format "Example %d" (1+ i)) "" nil)))
    (should (= (length (elbkm-storage-list)) 3))))

(ert-deftest elbkm-storage-test/delete-removes-bookmark ()
  "Deleting a bookmark by ID removes it from storage."
  (let ((elbkm-storage-file-path (elbkm-storage-test--fresh-file)))
    (let ((bm (elbkm-bookmark-create "https://example.com" "Example" "d" nil)))
      (should (elbkm-storage-add bm))
      (should (elbkm-storage-delete (elbkm-bookmark-id bm))))
    (should (eq (elbkm-storage-list) nil))))

(ert-deftest elbkm-storage-test/roundtrip-preserves-omitempty ()
  "Empty descriptions and nil tags are omitted on disk and survive roundtrip."
  (let ((elbkm-storage-file-path (elbkm-storage-test--fresh-file)))
    (let ((bm (elbkm-bookmark-create "https://e.com" "T" "" nil)))
      (should (elbkm-storage-add bm)))
    (let ((jstr (with-temp-buffer
                  (insert-file-contents elbkm-storage-file-path)
                  (buffer-string))))
      (should-not (string-match-p "\"description\"" jstr))
      (should-not (string-match-p "\"tags\"" jstr)))
    (let ((back (car (elbkm-storage-list))))
      (should (equal (elbkm-bookmark-description back) ""))
      (should (equal (elbkm-bookmark-tags back) nil)))))

(provide 'elbkm-storage-test)
;;; elbkm-storage-test.el ends here
