;;;; next/tests/context-compiler-test.lisp
;;;;
;;;; Unit tests for next/src/context-compiler.lisp (spec §8.3, doc
;;;; §4/§5/§6): hard token budget, empty-section elision, staleness
;;;; and promotion annotations, failure-analysis prioritisation.

(defpackage #:cl-harness-next/tests/context-compiler-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:update-world-model)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context
                #:estimate-tokens
                #:render-tool-schemas))

(in-package #:cl-harness-next/tests/context-compiler-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defvar *seq* 0)

(defun %feed (world-model type &rest plist)
  (update-world-model world-model
                      (make-harness-event
                       type (when plist (apply #'%hash plist))
                       :seq (incf *seq*))))

(defun %feed-interaction (world-model tool &key arguments result error)
  (%feed world-model :action "tool" tool "arguments" arguments)
  (if error
      (%feed world-model :observation "tool" tool "error" error)
      (%feed world-model :observation "tool" tool
             "result" (or result (%hash "ok" t)))))

(defun %sample-world-model ()
  "A world model with content in every section."
  (let ((*seq* 0)
        (world-model (make-standard-world-model)))
    (%feed world-model :run-start
           "goal" "Fix the cache eviction bug"
           "acceptance_criteria" (list "tests pass"))
    (%feed world-model :decision
           "kind" "decision" "text" "no macro" "rationale" "one call site")
    (%feed world-model :decision
           "kind" "finding" "hypothesis" "lru list ordering"
           "probe" "repl" "finding" "reversed" "decision" "fix compare")
    (%feed-interaction world-model "lisp-read-file"
                       :arguments (%hash "path" "src/cache.lisp"))
    (%feed-interaction world-model "repl-eval"
                       :arguments (%hash "code" "(evict)")
                       :result (%hash "content"
                                      (list (%hash "type" "text"
                                                   "text" "NIL"))))
    (%feed-interaction world-model "lisp-edit-form"
                       :arguments (%hash "file_path" "src/cache.lisp"
                                         "form_type" "defun"
                                         "form_name" "evict"
                                         "operation" "replace"
                                         "content" "lru list ordering fix"))
    (%feed-interaction world-model "run-tests"
                       :result (%hash "passed" 4 "failed" 1
                                      "failed_tests"
                                      (list (%hash "test_name" "evict-test"
                                                   "reason" "boom"))))
    world-model))

(defun %green-world-model ()
  "Sample world model driven to a clean green finish."
  (let ((world-model (%sample-world-model)))
    (let ((*seq* 20))
      (%feed-interaction world-model "pool-kill-worker")
      (%feed-interaction world-model "load-system")
      (%feed-interaction world-model "run-tests"
                         :result (%hash "passed" 5 "failed" 0)))
    world-model))

(deftest estimate-tokens-is-ceiling-of-quarter
  (ok (= 1 (estimate-tokens "abc")))
  (ok (= 1 (estimate-tokens "abcd")))
  (ok (= 2 (estimate-tokens "abcde")))
  (ok (= 0 (estimate-tokens ""))))

(deftest generous-budget-includes-all-sections
  (let ((view (compile-context (%sample-world-model))))
    (ok (search "Fix the cache eviction bug" view))
    (ok (search "## Verification" view))
    (ok (search "evict-test" view))
    (ok (search "no macro" view))
    (ok (search "## Recent patches" view))
    (ok (search "## Runtime probes" view))
    (ok (search "src/cache.lisp" view))))

(deftest empty-sections-are-elided
  (let ((view (compile-context (make-standard-world-model))))
    (ok (not (search "## Decisions" view)))
    (ok (not (search "## Recent patches" view)))
    (ok (not (search "## Findings" view)))))

(deftest tiny-budget-is-hard-bounded
  (let* ((budget 35)
         (view (compile-context (%sample-world-model)
                                :token-budget budget)))
    (ok (<= (estimate-tokens view) budget))
    (ok (search "Fix the cache eviction bug" view))
    (ok (search "omitted" view))))

(deftest annotations-are-rendered
  (let ((view (compile-context (%green-world-model))))
    ;; The probe predates the patch → [STALE]; the patch content
    ;; contains the finding hypothesis → [PROMOTED].
    (ok (search "[STALE]" view))
    (ok (search "[PROMOTED]" view))
    (ok (search "clean-verified: YES" view))
    (ok (search "regression watch" view))
    (ok (search "evict-test" view))))

(deftest failure-analysis-prioritises-failures
  (let ((view (compile-context (%sample-world-model)
                               :decision-point :failure-analysis)))
    (let ((failures-at (search "## Active failures" view))
          (patches-at (search "## Recent patches" view)))
      (ok failures-at)
      (ok patches-at)
      (ok (< failures-at patches-at)))
    (ok (search "## Next step" view))
    ;; Stale probes are filtered out of failure analysis (fresh only).
    (ok (not (search "[STALE]" view)))))

(deftest source-facts-render-content-and-dedupe-repeats
  ;; What the guided live run was missing: the read CONTENT must reach
  ;; the view, and identical repeated reads must not multiply it.
  (flet ((%count-substring (needle haystack)
           (loop with start = 0
                 for position = (search needle haystack :start2 start)
                 while position
                 count 1
                 do (setf start (1+ position)))))
    (let ((*seq* 0)
          (world-model (make-standard-world-model)))
      (%feed world-model :run-start
             "goal" "g" "acceptance_criteria" (list "a"))
      (dotimes (i 3)
        (%feed-interaction world-model "lisp-read-file"
                           :arguments (%hash "path" "src/main.lisp")
                           :result (%hash "content"
                                          (list (%hash "type" "text"
                                                       "text" "(defun add (a b)
  (- a b))")))))
      (let ((view (compile-context world-model)))
        (ok (search "(- a b)" view))
        (ok (= 1 (%count-substring "(- a b)" view)))))))

(deftest stale-source-facts-withhold-misleading-content
  ;; After a patch the old read content is actively misleading — the
  ;; guided rerun kept re-patching because the view still showed the
  ;; pre-patch source. Stale facts keep their entry (annotate, don't
  ;; filter, §9) but withhold the content with a re-read hint.
  (let ((*seq* 0)
        (world-model (make-standard-world-model)))
    (%feed world-model :run-start
           "goal" "g" "acceptance_criteria" (list "a"))
    (%feed-interaction world-model "lisp-read-file"
                       :arguments (%hash "path" "src/main.lisp")
                       :result (%hash "content"
                                      (list (%hash "type" "text"
                                                   "text" "(- a b)"))))
    (%feed-interaction world-model "lisp-edit-form"
                       :arguments (%hash "file_path" "src/main.lisp"
                                         "form_type" "defun"
                                         "form_name" "add"
                                         "operation" "replace"
                                         "content" "(+ a b)"))
    (let ((view (compile-context world-model)))
      (ok (search "[STALE]" view))
      (ok (not (search "(- a b)" view)))
      (ok (search "re-read" view)))))

(deftest superseded-stale-facts-drop-from-the-view
  ;; Run 5's loop: the agent re-read after the patch as hinted, but
  ;; the stale entry (and its standing \"re-read to refresh\" hint)
  ;; stayed in the view — so it re-read forever. Once a newer read of
  ;; the same file exists, the superseded stale fact must not render.
  (let ((*seq* 0)
        (world-model (make-standard-world-model)))
    (%feed world-model :run-start
           "goal" "g" "acceptance_criteria" (list "a"))
    (%feed-interaction world-model "lisp-read-file"
                       :arguments (%hash "path" "src/main.lisp")
                       :result (%hash "content"
                                      (list (%hash "type" "text"
                                                   "text" "(- a b)"))))
    (%feed-interaction world-model "lisp-edit-form"
                       :arguments (%hash "file_path" "src/main.lisp"
                                         "form_type" "defun"
                                         "form_name" "add"
                                         "operation" "replace"
                                         "content" "(+ a b)"))
    (%feed-interaction world-model "lisp-read-file"
                       :arguments (%hash "path" "src/main.lisp")
                       :result (%hash "content"
                                      (list (%hash "type" "text"
                                                   "text" "(+ a b)"))))
    (let ((view (compile-context world-model)))
      (ok (search "(+ a b)" view))
      (ok (not (search "re-read to refresh" view)))
      (ok (not (search "[STALE]" view))))))

(deftest pre-patch-verification-is-annotated
  ;; Run 3's loop: source fixed, but the failure record and the red
  ;; run-tests line predate the patch — the model read them as "still
  ;; broken" and kept double-checking the source. Verification info
  ;; older than the last successful patch must say so explicitly.
  (let ((*seq* 0)
        (world-model (make-standard-world-model)))
    (%feed world-model :run-start
           "goal" "g" "acceptance_criteria" (list "a"))
    (%feed-interaction world-model "run-tests"
                       :result (%hash "passed" 0 "failed" 1
                                      "failed_tests"
                                      (list (%hash "test_name" "ADD-ADDS"
                                                   "description" "boom"))))
    (%feed-interaction world-model "lisp-edit-form"
                       :arguments (%hash "file_path" "src/main.lisp"
                                         "form_type" "defun"
                                         "form_name" "add"
                                         "operation" "replace"
                                         "content" "(+ a b)"))
    (let ((view (compile-context world-model)))
      (ok (search "re-run tests" view))))
  ;; A test run after the patch clears the annotation.
  (let ((*seq* 0)
        (world-model (make-standard-world-model)))
    (%feed world-model :run-start
           "goal" "g" "acceptance_criteria" (list "a"))
    (%feed-interaction world-model "lisp-edit-form"
                       :arguments (%hash "file_path" "src/main.lisp"
                                         "form_type" "defun"
                                         "form_name" "add"
                                         "operation" "replace"
                                         "content" "(+ a b)"))
    (%feed-interaction world-model "run-tests"
                       :result (%hash "passed" 1 "failed" 0))
    (let ((view (compile-context world-model)))
      (ok (not (search "re-run tests" view))))))

(deftest render-tool-schemas-marks-required-params
  (let* ((desc (%hash "name" "lisp-read-file"
                      "inputSchema"
                      (%hash "properties"
                             (%hash "path" (%hash) "collapsed" (%hash))
                             "required" (vector "path"))))
         (out (render-tool-schemas (list desc))))
    (ok (search "lisp-read-file" out))
    (ok (search "path*" out))
    (ok (search "collapsed" out))
    (ok (not (search "collapsed*" out)))))

(deftest render-tool-schemas-handles-missing-schema
  (let ((out (render-tool-schemas (list (%hash "name" "run-tests")))))
    (ok (search "run-tests" out))))

(deftest render-tool-schemas-empty-is-nil
  (ok (null (render-tool-schemas '()))))

(deftest render-tool-schemas-drops-noise-optionals
  ;; G1: niche optional keys a weak model fills spuriously (esp. readtable) must
  ;; NOT be rendered — showing them tempts the model to pass e.g.
  ;; readtable=:common-lisp, which cl-mcp rejects ("Readtable :X not found"),
  ;; stalling the patch loop. Required + genuinely-useful optionals still render.
  (let* ((desc
          (%hash "name" "lisp-patch-form" "inputSchema"
           (%hash "properties"
                  (%hash "file_path" (%hash) "form_name" (%hash)
                         "old_text" (%hash) "new_text" (%hash)
                         "readtable" (%hash) "dry_run" (%hash))
                  "required" (vector "file_path" "form_name" "old_text" "new_text"))))
         (out (render-tool-schemas (list desc))))
    (ok (search "file_path*" out))
    (ok (search "old_text*" out))
    (ok (not (search "readtable" out)))
    (ok (not (search "dry_run" out)))))

(deftest failure-view-shows-current-patch-content
  ;; The agent must see the source it just wrote (the latest successful
  ;; patch's content), not only that a form was patched — otherwise it
  ;; patches blind and cannot tell whether its own edit was correct
  ;; (clh-histogram live run, 2026-06-13).
  (let ((view (compile-context (%sample-world-model)
                               :decision-point :failure-analysis)))
    (ok (search "lru list ordering fix" view))))
