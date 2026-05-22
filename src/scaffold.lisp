;;;; src/scaffold.lisp
;;;;
;;;; LLM-free, deterministic ASDF + rove scaffold generator.
;;;; Spec: docs/superpowers/specs/2026-05-22-scaffold-command-design.md

(defpackage #:cl-harness/src/scaffold
  (:use #:cl)
  (:export #:scaffold
           #:scaffold-result
           #:scaffold-result-status
           #:scaffold-result-paths-written
           #:scaffold-result-conflicts
           #:scaffold-error
           #:scaffold-error-message
           #:scaffold-bad-system-name
           #:scaffold-bad-system-name-name
           #:scaffold-partial-state
           #:scaffold-partial-state-existing
           #:scaffold-partial-state-missing))

(in-package #:cl-harness/src/scaffold)

(define-condition scaffold-error (error)
  ((message :initarg :message :reader scaffold-error-message))
  (:report (lambda (c s) (write-string (scaffold-error-message c) s))))

(define-condition scaffold-bad-system-name (scaffold-error)
  ((name :initarg :name :reader scaffold-bad-system-name-name)))

(define-condition scaffold-partial-state (scaffold-error)
  ((existing :initarg :existing :reader scaffold-partial-state-existing)
   (missing  :initarg :missing  :reader scaffold-partial-state-missing)))

(defun %valid-system-name-char-p (c first-p)
  (or (and first-p (char<= #\a c #\z))
      (and (not first-p)
           (or (char<= #\a c #\z)
               (char<= #\0 c #\9)
               (char= c #\-)))))

(defun %validate-system-name (name)
  "Return T if NAME matches ^[a-z][a-z0-9-]*$ and does not end with -.
Raise SCAFFOLD-BAD-SYSTEM-NAME otherwise."
  (let ((reject (lambda ()
                  (error 'scaffold-bad-system-name
                         :name name
                         :message
                         (format nil
                                 "invalid system name ~S — must match ~
^[a-z][a-z0-9-]*$ and not end with '-'"
                                 name)))))
    (unless (and (stringp name) (plusp (length name)))
      (funcall reject))
    (loop for i from 0 below (length name)
          for ch = (char name i)
          unless (%valid-system-name-char-p ch (zerop i))
          do (funcall reject))
    (when (char= (char name (1- (length name))) #\-)
      (funcall reject))
    t))
