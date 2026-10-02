;;; elbkm-tests.el --- Test runner for elbkm  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 elbkm contributors
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Convenience entry point for running the elbkm ERT test suite from the
;; command line.  Invoke it from the repository root:
;;
;;   emacs --batch -l tests/elbkm-tests.el

;;; Code:

(let ((load-path (append (list "." "tests") load-path)))
  (require 'elbkm-bookmark-test)
  (require 'elbkm-storage-test)
  (require 'elbkm-commands-test)
  (ert-run-tests-batch-and-exit t))

;;; elbkm-tests.el ends here
