;;; elbkm-commands-test.el --- Tests for elbkm commands  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 elbkm contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the `elbkm' interactive commands layer (the cmd/usecase
;; tier of the package).  Currently covers the
;; `elbkm-after-add-functions' and `elbkm-after-delete-functions' hooks;
;; future command-level tests belong here too.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'elbkm)
(require 'elbkm-bookmark)
(require 'elbkm-storage)

(defun elbkm-commands-test--fresh-file ()
  "Return a path for a fresh storage file in a temp directory."
  (expand-file-name "bookmarks.json" (make-temp-file "elbkm-commands-" "-dir")))

(defmacro elbkm-commands-test--with-fresh-storage (&rest body)
  "Evaluate BODY with `elbkm-storage-file-path' bound to a fresh file."
  (declare (indent 0) (debug body))
  `(let ((elbkm-storage-file-path (elbkm-commands-test--fresh-file)))
     ,@body))

(defmacro elbkm-commands-test--with-fake-input (selection answer &rest body)
  "Run BODY after stubbing interactive prompts used by `elbkm'.
SELECTION is the value `completing-read' returns; ANSWER is the value
`y-or-n-p' returns.  `read-string' is stubbed to return an empty string
so `elbkm--read-{url,title,description,tags}' never block on stdin."
  (declare (indent 1) (debug (form form body)))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) ,selection))
             ((symbol-function 'y-or-n-p)
              (lambda (&rest _) ,answer))
             ((symbol-function 'read-string)
              (lambda (&rest _) "")))
     ,@body))

(ert-deftest elbkm-commands-test/add-runs-after-add-hooks ()
  "`elbkm-add' invokes every function in `elbkm-after-add-functions'."
  (elbkm-commands-test--with-fake-input nil nil
    (elbkm-commands-test--with-fresh-storage
      (let ((hook-calls nil)
            (extra-calls nil))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-add-functions
                        (lambda (bm) (push bm hook-calls)))
              (add-hook 'elbkm-after-add-functions
                        (lambda (bm) (push (elbkm-bookmark-title bm) extra-calls))
                        :append)
              (elbkm-add "https://hook.example" "Hook Test" "" ""))
          (remove-hook 'elbkm-after-add-functions
                       (lambda (bm) (push bm hook-calls)))
          (remove-hook 'elbkm-after-add-functions
                       (lambda (bm) (push (elbkm-bookmark-title bm) extra-calls))))
        (should (= (length hook-calls) 1))
        (should (= (length extra-calls) 1))
        (should (equal (elbkm-bookmark-title (car hook-calls)) "Hook Test"))
        (should (equal (elbkm-bookmark-url (car hook-calls)) "https://hook.example"))
        (should (equal (car extra-calls) "Hook Test"))))))

(ert-deftest elbkm-commands-test/add-skips-delete-hooks ()
  "`elbkm-add' does not run `elbkm-after-delete-functions'."
  (elbkm-commands-test--with-fake-input nil nil
    (elbkm-commands-test--with-fresh-storage
      (let ((delete-calls 0))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-delete-functions
                        (lambda (_) (cl-incf delete-calls)))
              (elbkm-add "https://hook.example" "Hook Test" "" ""))
          (remove-hook 'elbkm-after-delete-functions
                       (lambda (_) (cl-incf delete-calls))))
        (should (= delete-calls 0))))))

(ert-deftest elbkm-commands-test/delete-runs-after-delete-hooks ()
  "`elbkm-delete' invokes every function in `elbkm-after-delete-functions'."
  (let ((bm (elbkm-bookmark-create "https://hook.example" "Hook Test" "" nil)))
    (elbkm-commands-test--with-fake-input nil nil
      (elbkm-commands-test--with-fresh-storage
        (elbkm-storage-add bm)
        (let ((hook-calls nil))
          (unwind-protect
              (progn
                (add-hook 'elbkm-after-delete-functions
                          (lambda (b) (push b hook-calls)))
                (elbkm-commands-test--with-fake-input
                    (elbkm--format-bookmark bm) t
                  (should (eq (elbkm-delete) t))))
            (remove-hook 'elbkm-after-delete-functions
                         (lambda (b) (push b hook-calls))))
          (should (= (length hook-calls) 1))
          (should (equal (elbkm-bookmark-id (car hook-calls))
                         (elbkm-bookmark-id bm)))
          (should (eq (elbkm-storage-list) nil)))))))

(ert-deftest elbkm-commands-test/delete-skips-add-hooks ()
  "`elbkm-delete' does not run `elbkm-after-add-functions'."
  (let ((bm (elbkm-bookmark-create "https://hook.example" "Hook Test" "" nil)))
    (elbkm-commands-test--with-fake-input nil nil
      (elbkm-commands-test--with-fresh-storage
        (elbkm-storage-add bm)
        (let ((add-calls 0))
          (unwind-protect
              (progn
                (add-hook 'elbkm-after-add-functions
                          (lambda (_) (cl-incf add-calls)))
                (elbkm-commands-test--with-fake-input
                    (elbkm--format-bookmark bm) t
                  (elbkm-delete)))
            (remove-hook 'elbkm-after-add-functions
                         (lambda (_) (cl-incf add-calls))))
          (should (= add-calls 0)))))))

(ert-deftest elbkm-commands-test/delete-cancelled-skips-hooks ()
  "Cancelling deletion does not run `elbkm-after-delete-functions'."
  (let ((bm (elbkm-bookmark-create "https://hook.example" "Hook Test" "" nil)))
    (elbkm-commands-test--with-fake-input nil nil
      (elbkm-commands-test--with-fresh-storage
        (elbkm-storage-add bm)
        (let ((hook-calls 0))
          (unwind-protect
              (progn
                (add-hook 'elbkm-after-delete-functions
                          (lambda (_) (cl-incf hook-calls)))
                (elbkm-commands-test--with-fake-input
                    (elbkm--format-bookmark bm) nil
                  (should (eq (elbkm-delete) nil))))
            (remove-hook 'elbkm-after-delete-functions
                         (lambda (_) (cl-incf hook-calls))))
          (should (= hook-calls 0))
          (should (= (length (elbkm-storage-list)) 1)))))))

(ert-deftest elbkm-commands-test/hook-errors-do-not-break-add ()
  "An error in one `elbkm-after-add-functions' entry does not stop later ones."
  (elbkm-commands-test--with-fake-input nil nil
    (elbkm-commands-test--with-fresh-storage
      (let ((later-call nil))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-add-functions
                        (lambda (_) (error "boom from hook")))
              (add-hook 'elbkm-after-add-functions
                        (lambda (bm) (setq later-call (elbkm-bookmark-url bm)))
                        :append)
              (should (elbkm-add "https://hook.example" "Hook Test" "" "")))
          (remove-hook 'elbkm-after-add-functions
                       (lambda (_) (error "boom from hook")))
          (remove-hook 'elbkm-after-add-functions
                       (lambda (bm)
                         (setq later-call (elbkm-bookmark-url bm)))
                       :append))
        (should (equal later-call "https://hook.example"))))))

(ert-deftest elbkm-commands-test/hook-errors-do-not-break-delete ()
  "An error in one `elbkm-after-delete-functions' entry does not stop later ones."
  (let ((bm (elbkm-bookmark-create "https://hook.example" "Hook Test" "" nil)))
    (elbkm-commands-test--with-fake-input nil nil
      (elbkm-commands-test--with-fresh-storage
        (elbkm-storage-add bm)
        (let ((later-call nil))
          (unwind-protect
              (progn
                (add-hook 'elbkm-after-delete-functions
                          (lambda (_) (error "boom from hook")))
                (add-hook 'elbkm-after-delete-functions
                          (lambda (b) (setq later-call (elbkm-bookmark-id b)))
                          :append)
                (elbkm-commands-test--with-fake-input
                    (elbkm--format-bookmark bm) t
                  (should (eq (elbkm-delete) t))))
            (remove-hook 'elbkm-after-delete-functions
                         (lambda (_) (error "boom from hook")))
            (remove-hook 'elbkm-after-delete-functions
                         (lambda (b) (setq later-call (elbkm-bookmark-id b)))
                         :append))
          (should (equal later-call (elbkm-bookmark-id bm))))))))

;;; `elbkm-edit' and `elbkm-after-edit-functions'

(ert-deftest elbkm-commands-test/edit-runs-after-edit-hooks ()
  "`elbkm-edit' invokes every function in `elbkm-after-edit-functions'."
  (let ((bm (elbkm-bookmark-create "https://old.example" "Old" "old" '("a"))))
    (elbkm-commands-test--with-fresh-storage
      (elbkm-storage-add bm)
      (let ((hook-calls nil)
            (calls-by-order nil)
            (input-sequence '("https://new.example" "New" "new" "x,y")))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-edit-functions
                        (lambda (b) (push b hook-calls)))
              (add-hook 'elbkm-after-edit-functions
                        (lambda (b) (push (elbkm-bookmark-title b) calls-by-order))
                        :append)
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _)
                           (or (pop input-sequence) ""))))
                (elbkm-edit bm)))
          (remove-hook 'elbkm-after-edit-functions
                       (lambda (b) (push b hook-calls)))
          (remove-hook 'elbkm-after-edit-functions
                       (lambda (b) (push (elbkm-bookmark-title b) calls-by-order))))
        (should (= (length hook-calls) 1))
        (should (equal (elbkm-bookmark-title (car hook-calls)) "New"))
        (should (equal (elbkm-bookmark-url (car hook-calls))
                       "https://new.example"))
        (should (equal (elbkm-bookmark-tags (car hook-calls)) (list "x" "y")))
        ;; Hooks fired after the update, so the new title is what they see.
        (should (equal (car calls-by-order) "New"))))))

(ert-deftest elbkm-commands-test/edit-skips-add-and-delete-hooks ()
  "`elbkm-edit' does not run `elbkm-after-add-functions' or `elbkm-after-delete-functions'."
  (let ((bm (elbkm-bookmark-create "https://old.example" "Old" "" nil)))
    (elbkm-commands-test--with-fresh-storage
      (elbkm-storage-add bm)
      (let ((add-calls 0)
            (delete-calls 0))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-add-functions
                        (lambda (_) (cl-incf add-calls)))
              (add-hook 'elbkm-after-delete-functions
                        (lambda (_) (cl-incf delete-calls)))
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _) "https://new.example")))
                (elbkm-edit bm)))
          (remove-hook 'elbkm-after-add-functions
                       (lambda (_) (cl-incf add-calls)))
          (remove-hook 'elbkm-after-delete-functions
                       (lambda (_) (cl-incf delete-calls))))
        (should (= add-calls 0))
        (should (= delete-calls 0))))))

(ert-deftest elbkm-commands-test/edit-cancelled-skips-hooks ()
  "Cancelling the bookmark selection does not run `elbkm-after-edit-functions'."
  (let ((bm (elbkm-bookmark-create "https://example.com" "T" "" nil)))
    (elbkm-commands-test--with-fresh-storage
      (elbkm-storage-add bm)
      (let ((hook-calls 0))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-edit-functions
                        (lambda (_) (cl-incf hook-calls)))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) nil)))
                (should (eq (elbkm-edit) nil))))
          (remove-hook 'elbkm-after-edit-functions
                       (lambda (_) (cl-incf hook-calls))))
        (should (= hook-calls 0))
        (should (= (length (elbkm-storage-list)) 1))))))

(ert-deftest elbkm-commands-test/hook-errors-do-not-break-edit ()
  "An error in one `elbkm-after-edit-functions' entry does not stop later ones."
  (let ((bm (elbkm-bookmark-create "https://example.com" "T" "" nil)))
    (elbkm-commands-test--with-fresh-storage
      (elbkm-storage-add bm)
      (let ((later-call nil))
        (unwind-protect
            (progn
              (add-hook 'elbkm-after-edit-functions
                        (lambda (_) (error "boom from edit hook")))
              (add-hook 'elbkm-after-edit-functions
                        (lambda (b) (setq later-call (elbkm-bookmark-title b)))
                        :append)
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _) "https://new.example")))
                (elbkm-edit bm)))
          (remove-hook 'elbkm-after-edit-functions
                       (lambda (_) (error "boom from edit hook")))
          (remove-hook 'elbkm-after-edit-functions
                       (lambda (b) (setq later-call (elbkm-bookmark-title b)))
                       :append))
        ;; read-string was stubbed to the same value for every field,
        ;; so the new title equals the new URL.
        (should (equal later-call "https://new.example"))))))

(ert-deftest elbkm-commands-test/edit-preserves-id-and-created-at ()
  "`elbkm-edit' keeps the bookmark's ID and created-at unchanged."
  (let ((bm (elbkm-bookmark-reconstitute
             "550e8400-e29b-41d4-a716-446655440000"
             "https://example.com" "T" "" nil
             "2026-01-01T00:00:00Z" "2026-01-01T00:00:00Z")))
    (elbkm-commands-test--with-fresh-storage
      (elbkm-storage-add bm)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "https://new.example")))
        (let ((updated (elbkm-edit bm)))
          (should (equal (elbkm-bookmark-id updated)
                         "550e8400-e29b-41d4-a716-446655440000"))
          (should (equal (elbkm-bookmark-created-at updated)
                         "2026-01-01T00:00:00Z"))
          (should (not (equal (elbkm-bookmark-updated-at updated)
                              "2026-01-01T00:00:00Z")))
          (let ((persisted (car (elbkm-storage-list))))
            (should (equal (elbkm-bookmark-id persisted)
                           "550e8400-e29b-41d4-a716-446655440000"))
            (should (equal (elbkm-bookmark-url persisted)
                           "https://new.example"))))))))

;;; `elbkm-use-list-buffer' (tabulated-list-mode based search UI)

(defmacro elbkm-commands-test--with-list-buffer-mock (&rest body)
  "Evaluate BODY with `pop-to-buffer' stubbed (no window side effects).
The stub returns the buffer object for the requested name so callers
can inspect it without altering the selected window."
  (declare (indent 0) (debug body))
  `(cl-letf (((symbol-function 'pop-to-buffer)
              (lambda (buf-or-name)
                (get-buffer buf-or-name))))
     ,@body))

(ert-deftest elbkm-commands-test/use-list-buffer-defaults-nil ()
  "`elbkm-use-list-buffer' is nil by default."
  (should (eq elbkm-use-list-buffer nil)))

(ert-deftest elbkm-commands-test/search-list-populates-buffer ()
  "With `elbkm-use-list-buffer' t, `elbkm-search' opens the list buffer
populated with every bookmark from storage."
  (let ((bm1 (elbkm-bookmark-create "https://a.example" "Alpha" "First" '("web")))
        (bm2 (elbkm-bookmark-create "https://b.example" "Bravo" "" nil)))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm1)
     (elbkm-storage-add bm2)
     (let ((elbkm-use-list-buffer t))
       (elbkm-commands-test--with-list-buffer-mock
         (elbkm-commands-test--with-fake-input nil nil
           (let ((result (elbkm-search)))
             (should (bufferp result))
             (should (equal (buffer-name result) "*elbkm-search*"))
             (with-current-buffer "*elbkm-search*"
               (should (derived-mode-p 'elbkm-search-list-mode))
               (should (= (length tabulated-list-entries) 2))
               (let ((urls (mapcar (lambda (e) (elt (cadr e) 1))
                                   tabulated-list-entries)))
                 (should (member "https://a.example" urls))
                 (should (member "https://b.example" urls)))))))))))

(ert-deftest elbkm-commands-test/search-list-filters-by-tags ()
  "`elbkm-search' with list buffer applies the tag filter to the entries."
  (let ((bm1 (elbkm-bookmark-create "https://a.example" "Alpha" "" '("foo")))
        (bm2 (elbkm-bookmark-create "https://b.example" "Bravo" "" '("bar"))))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm1)
     (elbkm-storage-add bm2)
     (let ((elbkm-use-list-buffer t))
       (elbkm-commands-test--with-list-buffer-mock
         (elbkm-commands-test--with-fake-input nil nil
           (elbkm-search "foo")
           (with-current-buffer "*elbkm-search*"
             (should (= (length tabulated-list-entries) 1))
             (should (equal (elt (cadr (car tabulated-list-entries)) 1)
                            "https://a.example"))
             (should (equal elbkm-search-list--tags '("foo"))))))))))

(ert-deftest elbkm-commands-test/search-list-empty-when-no-matches ()
  "The list buffer shows zero entries when no bookmarks match the filter."
  (let ((bm (elbkm-bookmark-create "https://a.example" "Alpha" "" '("foo"))))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm)
     (let ((elbkm-use-list-buffer t))
       (elbkm-commands-test--with-list-buffer-mock
         (elbkm-commands-test--with-fake-input nil nil
           (elbkm-search "nonexistent-tag")
           (with-current-buffer "*elbkm-search*"
             (should (derived-mode-p 'elbkm-search-list-mode))
             (should (= (length tabulated-list-entries) 0)))))))))

(ert-deftest elbkm-commands-test/search-list-open-calls-open-function ()
  "`elbkm-search-list--open' invokes `elbkm-open-function' with the URL
of the bookmark on the current entry line."
  (let* ((bm (elbkm-bookmark-create "https://a.example" "Alpha" "" nil))
         (opened-url nil))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm)
     (let ((elbkm-use-list-buffer t)
           (elbkm-open-function (lambda (url) (setq opened-url url))))
       (elbkm-commands-test--with-list-buffer-mock
         (elbkm-commands-test--with-fake-input nil nil
           (elbkm-search)
           (with-current-buffer "*elbkm-search*"
             (goto-char (point-min))
             (should (equal (tabulated-list-get-id)
                            (elbkm-bookmark-id bm)))
             (elbkm-search-list--open))))
       (should (equal opened-url "https://a.example"))))))

(ert-deftest elbkm-commands-test/search-list-revert-reloads-entries ()
  "`revert-buffer' on the list buffer reloads entries from storage while
preserving the active tag filter."
  (let* ((bm1 (elbkm-bookmark-create "https://a.example" "Alpha" "" '("keep")))
         (bm2 (elbkm-bookmark-create "https://b.example" "Bravo" "" '("drop"))))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm1)
     (elbkm-storage-add bm2)
     (let ((elbkm-use-list-buffer t))
       (elbkm-commands-test--with-list-buffer-mock
         (elbkm-commands-test--with-fake-input nil nil
           (elbkm-search "keep")
           (with-current-buffer "*elbkm-search*"
             (should (= (length tabulated-list-entries) 1))
             (elbkm-storage-add
              (elbkm-bookmark-create "https://c.example" "Charlie" "" '("keep")))
             (should (= (length tabulated-list-entries) 1))
             (revert-buffer)
             (should (= (length tabulated-list-entries) 2))
             (should (equal elbkm-search-list--tags '("keep"))))))))))

(ert-deftest elbkm-commands-test/search-list-falls-back-when-option-nil ()
  "When `elbkm-use-list-buffer' is nil, `elbkm-search' keeps its original
`completing-read' behavior and returns the selected bookmark plist."
  (let ((bm (elbkm-bookmark-create "https://a.example" "Alpha" "" nil))
        (opened-url nil))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm)
     (let ((elbkm-use-list-buffer nil)
           (elbkm-open-function (lambda (url) (setq opened-url url))))
       ;; Make sure no leftover list buffer is hanging around from a prior test.
       (when (get-buffer "*elbkm-search*")
         (kill-buffer "*elbkm-search*"))
       (elbkm-commands-test--with-fake-input
           (elbkm--format-bookmark bm) t
         (let ((result (elbkm-search)))
           (should (equal (elbkm-bookmark-id result)
                          (elbkm-bookmark-id bm)))))
       (should (equal opened-url "https://a.example"))
       (should (not (get-buffer "*elbkm-search*")))))))

(ert-deftest elbkm-commands-test/search-list-keymap-binds-add-and-delete ()
  "The search list binds `a' to add and `d' to delete."
  (should (eq (lookup-key elbkm-search-list-mode-map (kbd "a"))
             #'elbkm-search-list--add))
  (should (eq (lookup-key elbkm-search-list-mode-map (kbd "d"))
             #'elbkm-search-list--delete)))

(ert-deftest elbkm-commands-test/search-list-keymap-binds-edit ()
  "The search list binds `e' to edit."
  (should (eq (lookup-key elbkm-search-list-mode-map (kbd "e"))
             #'elbkm-search-list--edit)))

(ert-deftest elbkm-commands-test/search-list-add-refreshes-buffer ()
  "Adding from the search list refreshes its entries."
  (elbkm-commands-test--with-fresh-storage
   (let ((elbkm-search-list--tags nil)
         (elbkm-search-list--entries nil)
         (buffer (get-buffer-create "*elbkm-search*")))
     (unwind-protect
         (with-current-buffer buffer
           (elbkm-search-list-mode)
           (elbkm-search-list--populate nil)
           (cl-letf (((symbol-function 'elbkm-add)
                      (lambda ()
                        (elbkm-storage-add
                         (elbkm-bookmark-create
                          "https://a.example" "Alpha" "" nil)))))
             (elbkm-search-list--add))
           (should (= (length tabulated-list-entries) 1)))
       (kill-buffer buffer)))))

(ert-deftest elbkm-commands-test/search-list-delete-confirms-and-refreshes ()
  "Deleting from the search list confirms and refreshes its entries."
  (let ((bm (elbkm-bookmark-create "https://a.example" "Alpha" "" nil)))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm)
     (let ((buffer (get-buffer-create "*elbkm-search*"))
           (confirmation-calls 0))
       (unwind-protect
           (with-current-buffer buffer
             (elbkm-search-list-mode)
             (elbkm-search-list--populate nil)
             (goto-char (point-min))
             (cl-letf (((symbol-function 'y-or-n-p)
                        (lambda (&rest _)
                          (cl-incf confirmation-calls)
                          t)))
               (elbkm-search-list--delete))
             (should (= confirmation-calls 1))
             (should (= (length tabulated-list-entries) 0))
             (should-not (elbkm-storage-list)))
         (kill-buffer buffer))))))

(ert-deftest elbkm-commands-test/search-list-edit-refreshes-buffer ()
  "Editing from the search list updates the bookmark and refreshes entries."
  (let ((bm (elbkm-bookmark-create "https://a.example" "Alpha" "" nil)))
    (elbkm-commands-test--with-fresh-storage
     (elbkm-storage-add bm)
     (let ((buffer (get-buffer-create "*elbkm-search*")))
       (unwind-protect
           (with-current-buffer buffer
             (elbkm-search-list-mode)
             (elbkm-search-list--populate nil)
             (goto-char (point-min))
             (cl-letf (((symbol-function 'elbkm-edit)
                        (lambda (b)
                          (elbkm-storage-update
                           (elbkm-bookmark-update b
                                                   "https://a.example"
                                                   "Alpha edited"
                                                   ""
                                                   nil)))))
               (elbkm-search-list--edit))
             (should (= (length tabulated-list-entries) 1))
             (should (equal (elt (cadr (car tabulated-list-entries)) 0)
                            "Alpha edited")))
         (kill-buffer buffer))))))

(provide 'elbkm-commands-test)
;;; elbkm-commands-test.el ends here
