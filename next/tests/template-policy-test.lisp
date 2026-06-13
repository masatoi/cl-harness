;;;; next/tests/template-policy-test.lisp
;;;;
;;;; Tests for next/src/template-policy.lisp. Increment A: the
;;;; reader-based body extractor (extract-method-body).

(defpackage #:cl-harness-next/tests/template-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/template-policy
                #:extract-method-body))

(in-package #:cl-harness-next/tests/template-policy-test)

(deftest body-extraction-bare-body-wraps
  ;; A bare body s-expression is wrapped under the FSM-owned head.
  (multiple-value-bind (form reason)
      (extract-method-body "(incf (gethash key (histogram-table h) 0))"
                           :head "observe ((h histogram) key)"
                           :form-type "defmethod")
    (ok (null reason))
    (ok (stringp form))
    (ok (and form (search "(defmethod observe ((h histogram) key)" form)))
    (ok (and form (search "(incf (gethash key (histogram-table h) 0))" form)))))

(deftest body-extraction-strips-fence-and-prose
  (multiple-value-bind (form reason)
      (extract-method-body (format nil "```lisp~%(gethash key (histogram-table h) 0)~%```")
                           :head "count-of ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(gethash key (histogram-table h) 0)" form))))
  (multiple-value-bind (form reason)
      (extract-method-body "The body is: (gethash key (histogram-table h) 0)"
                           :head "count-of ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(gethash key (histogram-table h) 0)" form)))))

(deftest body-extraction-rewraps-whole-defmethod
  ;; A whole-defmethod reply has its header discarded and the body re-wrapped
  ;; under the FSM-owned canonical head.
  (multiple-value-bind (form reason)
      (extract-method-body
       "(defmethod observe ((h histogram) key) (incf (gethash key (histogram-table h) 0)))"
       :head "observe ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(defmethod observe ((h histogram) key)" form)))
    (ok (and form (search "(incf (gethash key (histogram-table h) 0))" form)))))

(deftest body-extraction-accepts-multiple-body-forms
  ;; A body may legitimately be several forms (reader-based, not a
  ;; reject-multiple-forms char scanner).
  (multiple-value-bind (form reason)
      (extract-method-body
       "(setf (gethash key (histogram-table h)) (1+ (gethash key (histogram-table h) 0))) (gethash key (histogram-table h))"
       :head "observe ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(setf (gethash key (histogram-table h))" form)))
    (ok (and form (search "(gethash key (histogram-table h))" form)))))

(deftest body-extraction-rejects-nested-definition
  (multiple-value-bind (form reason)
      (extract-method-body "(defun helper () 1) (helper)"
                           :head "observe ((h histogram) key)")
    (ok (null form))
    (ok (eq :nested-definition reason))))

(deftest body-extraction-rejects-degenerate-and-malformed
  (ok (eq :empty (nth-value 1 (extract-method-body "" :head "observe ((h histogram) key)"))))
  (ok (eq :empty (nth-value 1 (extract-method-body (format nil "```lisp~%```")
                                                   :head "observe ((h histogram) key)"))))
  (ok (eq :degenerate (nth-value 1 (extract-method-body "nil" :head "observe ((h histogram) key)"))))
  (ok (eq :degenerate (nth-value 1 (extract-method-body "0" :head "observe ((h histogram) key)"))))
  (ok (eq :malformed (nth-value 1 (extract-method-body "(incf (gethash key"
                                                       :head "observe ((h histogram) key)")))))
