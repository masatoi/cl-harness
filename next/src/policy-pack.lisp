;;;; next/src/policy-pack.lisp
;;;;
;;;; Policy pack: the versioned artifact bundle of the redesign
;;;; (spec §10.1). Prompts, budgets, oracle profiles, and dial rules
;;;; live here as *data*, never code: packs are read with a hardened
;;;; reader (*READ-EVAL* nil, symbols confined to keywords) and
;;;; identified by a SHA-256 fingerprint of their canonical form, so
;;;; every run can record exactly which pack produced its metrics.

(defpackage #:cl-harness-next/src/policy-pack
  (:use #:cl)
  (:export #:parse-semver
           #:semver<
           #:policy-pack
           #:load-policy-pack
           #:policy-pack-invalid
           #:policy-pack-invalid-message
           #:policy-pack-invalid-path
           #:pack-name
           #:pack-version
           #:pack-source-path
           #:pack-fingerprint
           #:pack-prompts
           #:pack-budgets
           #:pack-oracle-profiles
           #:pack-dial-rules
           #:pack-prompt
           #:pack-budget
           #:pack-oracle-profile
           #:pack-dial-rule))

(in-package #:cl-harness-next/src/policy-pack)

(defun parse-semver (string)
  "Parse a strict \"MAJOR.MINOR.PATCH\" STRING into a list of three
non-negative integers. Signals an ERROR on anything else."
  (let ((parts (uiop:split-string string :separator ".")))
    (unless (= 3 (length parts))
      (error "Not a MAJOR.MINOR.PATCH semver string: ~S" string))
    (mapcar (lambda (part) (parse-integer part)) parts)))

(defun semver< (a b)
  "True when semver string A denotes a strictly older version than B."
  (loop for x in (parse-semver a)
        for y in (parse-semver b)
        when (< x y) return t
        when (> x y) return nil
        finally (return nil)))
