;;;; next/tests/main-test.lisp
;;;;
;;;; Facade smoke tests + cross-module integration tests for
;;;; cl-harness-next (SP1: L0 substrate).

(defpackage #:cl-harness-next/tests/main-test
  (:use #:cl #:rove))

(in-package #:cl-harness-next/tests/main-test)

(deftest facade-package-exists
  (ok (find-package '#:cl-harness-next))
  (ok (equal "0.1.0" (cl-harness-next:substrate-version))))

(deftest run-start-records-pack-fingerprint
  ;; SP1 acceptance: a run can durably record which policy pack it
  ;; used (spec 原則3「すべての実行は実験である」).
  (uiop:with-temporary-file (:pathname pack-path :type "sexp")
    (with-open-file (out pack-path :direction :output
                                   :if-exists :supersede
                                   :external-format :utf-8)
      (write-string "(:name \"default\" :version \"0.1.0\")" out))
    (uiop:with-temporary-file (:pathname log-path :type "jsonl")
      (uiop:delete-file-if-exists log-path)
      (let ((pack (cl-harness-next:load-policy-pack pack-path))
            (log (cl-harness-next:open-event-log log-path)))
        (cl-harness-next:emit-event
         log :run-start
         (alexandria:plist-hash-table
          (list "pack_name" (cl-harness-next:pack-name pack)
                "pack_fingerprint" (cl-harness-next:pack-fingerprint pack))
          :test #'equal))
        (let ((event (first (cl-harness-next:read-events log-path))))
          (ok (eq :run-start (cl-harness-next:event-type event)))
          (ok (equal (cl-harness-next:pack-fingerprint pack)
                     (gethash "pack_fingerprint"
                              (cl-harness-next:event-payload event)))))))))
