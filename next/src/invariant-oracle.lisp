;;;; next/src/invariant-oracle.lisp
;;;;
;;;; Deterministic AST-level invariant oracle (spec §7), generalizing
;;;; the legacy validate-test-source L1 defense (spec §12): exactly one
;;;; deftest, no (skip ...), valid Lisp. Source is read with a hardened
;;;; reader — *READ-EVAL* nil, symbols interned into a throwaway
;;;; scratch package (package-qualified symbols still resolve against
;;;; their named package; an unknown package is a read error and the
;;;; verdict is "unreadable").

(defpackage #:cl-harness-next/src/invariant-oracle
  (:use #:cl)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict)
  (:export #:invariant-oracle
           #:oracle-invariants))

(in-package #:cl-harness-next/src/invariant-oracle)

(defclass invariant-oracle (oracle)
  ((invariants :initarg :invariants
               :initform '(:valid-lisp :no-skip :single-deftest)
               :reader oracle-invariants
               :documentation "Subset of (:valid-lisp :no-skip
:single-deftest) to enforce."))
  (:documentation "Configurable deterministic source-invariant gate."))

(defmethod oracle-name ((oracle invariant-oracle)) :invariant)

(defun %read-forms-safely (source)
  "Read all top-level forms of SOURCE with *READ-EVAL* disabled and a
throwaway scratch package. Returns (values forms error-message)."
  (let ((scratch (make-package (string (gensym "INVARIANT-SCRATCH"))
                               :use '())))
    (unwind-protect
         (handler-case
             (with-standard-io-syntax
               (let ((*read-eval* nil)
                     (*package* scratch)
                     (eof (list nil)))
                 (with-input-from-string (in source)
                   (values (loop for form = (read in nil eof)
                                 until (eq form eof)
                                 collect form)
                           nil))))
           (error (condition)
             (values nil (format nil "~A" condition))))
      (delete-package scratch))))

(defun %symbol-named-p (object name)
  (and (symbolp object) (string= (symbol-name object) name)))

(defun %deftest-form-p (form)
  (and (consp form) (%symbol-named-p (first form) "DEFTEST")))

(defun %contains-skip-p (form)
  "Tree walk: any sub-form whose operator is a symbol named SKIP.
Safe on dotted lists."
  (cond ((not (consp form)) nil)
        ((%symbol-named-p (car form) "SKIP") t)
        (t (loop for rest = form then (cdr rest)
                 while (consp rest)
                 thereis (%contains-skip-p (car rest))))))

(defmethod evaluate ((oracle invariant-oracle) (source string))
  (multiple-value-bind (forms read-error) (%read-forms-safely source)
    (if read-error
        (make-verdict :oracle :invariant :pass-p nil
                      :reason (format nil "unreadable source: ~A"
                                      read-error))
        (let ((violations '()))
          (dolist (invariant (oracle-invariants oracle))
            (ecase invariant
              (:valid-lisp nil)   ; established by the successful read
              (:no-skip
               (when (some #'%contains-skip-p forms)
                 (push "contains (skip ...)" violations)))
              (:single-deftest
               (let ((count (count-if #'%deftest-form-p forms)))
                 (unless (= 1 count)
                   (push (format nil
                                 "expected exactly one deftest, found ~D"
                                 count)
                         violations))))))
          (if violations
              (make-verdict :oracle :invariant :pass-p nil
                            :reason (format nil "~{~A~^; ~}"
                                            (nreverse violations)))
              (make-verdict :oracle :invariant :pass-p t :reason nil))))))
