;;; elbkm-bookmark-test.el --- Tests for elbkm-bookmark  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 elbkm contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the `elbkm-bookmark' domain package, mirroring the test
;; cases of the original Go `bkm' internal/bookmark package.

;;; Code:

(require 'ert)
(require 'elbkm-bookmark)

(ert-deftest elbkm-bookmark-test/valid-uuid-succeeds ()
  "A canonical UUID string should validate."
  (should (elbkm-bookmark-valid-id-p "550e8400-e29b-41d4-a716-446655440000")))

(ert-deftest elbkm-bookmark-test/invalid-uuid-fails ()
  "A non-UUID string should not validate."
  (should-not (elbkm-bookmark-valid-id-p "not-a-uuid"))
  (should-not (elbkm-bookmark-valid-id-p ""))
  (should-not (elbkm-bookmark-valid-id-p "550e8400-e29b-41d4-a716")))

(ert-deftest elbkm-bookmark-test/generate-id-is-valid ()
  "A generated ID should validate as a UUID."
  (let ((id (elbkm-bookmark-generate-id)))
    (should (elbkm-bookmark-valid-id-p id))))

(ert-deftest elbkm-bookmark-test/validate-id-signals-on-invalid ()
  "validate-id should signal an error for a bad UUID."
  (should-error (elbkm-bookmark-validate-id "nope")))

(ert-deftest elbkm-bookmark-test/valid-url-succeeds ()
  "URLs with scheme and host should validate."
  (dolist (url '("http://example.com" "https://example.com/path"
                 "ftp://example.com:21/a/b"))
    (should (elbkm-bookmark-valid-url-p url))))

(ert-deftest elbkm-bookmark-test/empty-url-fails ()
  "An empty URL should not validate."
  (should-not (elbkm-bookmark-valid-url-p "")))

(ert-deftest elbkm-bookmark-test/url-without-scheme-fails ()
  "A URL without a scheme should not validate."
  (should-not (elbkm-bookmark-valid-url-p "example.com/path")))

(ert-deftest elbkm-bookmark-test/url-without-host-fails ()
  "A URL without a host should not validate."
  (should-not (elbkm-bookmark-valid-url-p "https:///path"))
  (should-not (elbkm-bookmark-valid-url-p "https://")))

(ert-deftest elbkm-bookmark-test/validate-url-signals-on-invalid ()
  "validate-url should signal an error for a malformed URL."
  (should-error (elbkm-bookmark-validate-url ""))
  (should-error (elbkm-bookmark-validate-url "example.com")))

(ert-deftest elbkm-bookmark-test/valid-title-succeeds-and-trims ()
  "A non-empty title validates and is trimmed."
  (should (equal (elbkm-bookmark-validate-title "  Example  ") "Example"))
  (should (equal (elbkm-bookmark-validate-title "Example") "Example")))

(ert-deftest elbkm-bookmark-test/empty-title-fails ()
  "An empty or whitespace-only title should signal an error."
  (should-error (elbkm-bookmark-validate-title ""))
  (should-error (elbkm-bookmark-validate-title "   ")))

(ert-deftest elbkm-bookmark-test/description-trims-any-string ()
  "validate-description trims whitespace and may return an empty string."
  (should (equal (elbkm-bookmark-validate-description "  hi  ") "hi"))
  (should (equal (elbkm-bookmark-validate-description "") ""))
  (should (equal (elbkm-bookmark-validate-description "   ") "")))

(ert-deftest elbkm-bookmark-test/valid-tag-succeeds-and-trims ()
  "A non-empty tag validates and is trimmed."
  (should (equal (elbkm-bookmark-validate-tags (list "  go  " "cli"))
                 (list "go" "cli"))))

(ert-deftest elbkm-bookmark-test/empty-tag-fails ()
  "An empty tag inside the list should signal an error."
  (should-error (elbkm-bookmark-validate-tags (list "ok" "")))
  (should-error (elbkm-bookmark-validate-tags (list "ok" "   "))))

(ert-deftest elbkm-bookmark-test/validate-tags-nil-is-nil ()
  "Validating nil tags yields nil."
  (should (equal (elbkm-bookmark-validate-tags nil) nil)))

(ert-deftest elbkm-bookmark-test/create-bookmark-populates-fields ()
  "create produces a bookmark with an ID and timestamps."
  (let ((bm (elbkm-bookmark-create "https://example.com" "Ex" "desc"
                                    (list "a" "b"))))
    (should (elbkm-bookmark-valid-id-p (elbkm-bookmark-id bm)))
    (should (equal (elbkm-bookmark-url bm) "https://example.com"))
    (should (equal (elbkm-bookmark-title bm) "Ex"))
    (should (equal (elbkm-bookmark-description bm) "desc"))
    (should (equal (elbkm-bookmark-tags bm) (list "a" "b")))
    (should (equal (elbkm-bookmark-created-at bm)
                   (elbkm-bookmark-updated-at bm)))))

(ert-deftest elbkm-bookmark-test/create-bookmark-signals-on-bad-url ()
  "create should signal when given an invalid URL."
  (should-error (elbkm-bookmark-create "" "Ex" "" nil)))

(ert-deftest elbkm-bookmark-test/reconstitute-validates-fields ()
  "reconstitute validates every persisted field."
  (let ((bm (elbkm-bookmark-reconstitute
             "550e8400-e29b-41d4-a716-446655440000"
             "https://example.com" "Ex" "desc" (list "a")
             "2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z")))
    (should (equal (elbkm-bookmark-id bm) "550e8400-e29b-41d4-a716-446655440000")))
  (should-error (elbkm-bookmark-reconstitute
                 "bad" "https://example.com" "Ex" "" nil nil nil)))

(ert-deftest elbkm-bookmark-test/update-bookmark-preserves-id-and-created-at ()
  "update keeps the original `:id' and `:created-at' and refreshes `:updated-at'."
  (let* ((bm (elbkm-bookmark-reconstitute
              "550e8400-e29b-41d4-a716-446655440000"
              "https://old.example" "Old" "old desc" (list "x")
              "2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z"))
         (updated (elbkm-bookmark-update bm
                                         "https://new.example"
                                         "New"
                                         "new desc"
                                         (list "y" "z"))))
    (should (equal (elbkm-bookmark-id updated)
                   "550e8400-e29b-41d4-a716-446655440000"))
    (should (equal (elbkm-bookmark-url updated) "https://new.example"))
    (should (equal (elbkm-bookmark-title updated) "New"))
    (should (equal (elbkm-bookmark-description updated) "new desc"))
    (should (equal (elbkm-bookmark-tags updated) (list "y" "z")))
    (should (equal (elbkm-bookmark-created-at updated) "2026-01-01T00:00:00Z"))
    (should (not (equal (elbkm-bookmark-updated-at updated)
                        "2026-01-02T00:00:00Z")))))

(ert-deftest elbkm-bookmark-test/update-bookmark-validates-fields ()
  "update validates URL, title and tags with the same rules as create."
  (let ((bm (elbkm-bookmark-create "https://example.com" "T" "" nil)))
    (should-error (elbkm-bookmark-update bm "" "T" "" nil))
    (should-error (elbkm-bookmark-update bm "https://example.com" " " "" nil))
    (should-error (elbkm-bookmark-update bm "https://example.com" "T" "" (list "")))))

(provide 'elbkm-bookmark-test)
;;; elbkm-bookmark-test.el ends here
