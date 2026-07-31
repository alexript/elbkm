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

(provide 'elbkm-commands-test)
;;; elbkm-commands-test.el ends here
