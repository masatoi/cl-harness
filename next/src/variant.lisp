;;;; next/src/variant.lisp
;;;;
;;;; Artifact variants for the L5 loop (spec §10.2 stage 3): an LLM
;;;; proposes ONE mutation of the policy pack (the §10.4 safety rule —
;;;; one artifact per cycle — is structural here: APPLY-VARIANT can
;;;; only change a single entry). Parsing fails closed; LLM-supplied
;;;; target names stay STRINGS matched against entry-id names — they
;;;; are never interned.

(defpackage #:cl-harness-next/src/variant
  (:use #:cl)
  (:import-from #:cl-harness-next/src/json
                #:parse-json)
  (:import-from #:cl-harness-next/src/policy-pack
                #:pack-name
                #:pack-version
                #:pack-prompts
                #:pack-budgets
                #:pack-oracle-profiles
                #:pack-dial-rules
                #:pack-tool-policies
                #:parse-semver)
  (:export #:variant
           #:variant-kind
           #:variant-target
           #:variant-value
           #:variant-hypothesis
           #:parse-variant
           #:pack-form
           #:apply-variant
           #:write-pack-form
           #:propose-variant))

(in-package #:cl-harness-next/src/variant)

(defstruct (variant (:conc-name variant-))
  kind        ; :prompt | :budget | :code
  target      ; entry-id NAME as a string (never interned)
  value       ; new :text (prompt) or :value (budget)
  hypothesis) ; predicted effect (recorded with the proposal)

(defun %kind-keyword (string)
  (cond ((equal string "prompt") :prompt)
        ((equal string "budget") :budget)
        ((equal string "code") :code)
        (t nil)))

(defun parse-variant (text)
  "Parse an LLM variant proposal. Returns a VARIANT or NIL — fail
closed: bad JSON, unknown kinds, or missing fields yield NIL.
:code variants need only a hypothesis (they become human dossiers);
:prompt/:budget need target, value, and hypothesis."
  (let ((parsed (handler-case (parse-json text)
                  (error () nil))))
    (when (hash-table-p parsed)
      (let ((kind (%kind-keyword (gethash "kind" parsed)))
            (target (gethash "target" parsed))
            (value (gethash "value" parsed))
            (hypothesis (gethash "hypothesis" parsed)))
        (cond
          ((null kind) nil)
          ((not (stringp hypothesis)) nil)
          ((eq kind :code)
           (make-variant :kind :code :hypothesis hypothesis
                         :target (and (stringp target) target)
                         :value value))
          ((and (stringp target) value)
           (make-variant :kind kind :target target :value value
                         :hypothesis hypothesis))
          (t nil))))))

(defun %bump-patch (version)
  (destructuring-bind (major minor patch) (parse-semver version)
    (format nil "~A.~A.~A" major minor (1+ patch))))

(defun pack-form (pack &key version)
  "Reconstruct PACK's sexp form from its slots, with VERSION
(default: the patch component bumped — every variant is a new
versioned, fingerprinted artifact, spec §10.1)."
  (append (list :name (pack-name pack)
                :version (or version (%bump-patch (pack-version pack))))
          (alexandria:when-let ((prompts (pack-prompts pack)))
            (list :prompts prompts))
          (alexandria:when-let ((budgets (pack-budgets pack)))
            (list :budgets budgets))
          (alexandria:when-let ((profiles (pack-oracle-profiles pack)))
            (list :oracle-profiles profiles))
          (alexandria:when-let ((rules (pack-dial-rules pack)))
            (list :dial-rules rules))
          (alexandria:when-let ((policies (pack-tool-policies pack)))
            (list :tool-policies policies))))

(defun %entry-named (entries target)
  "Find the entry whose :id NAME matches TARGET (string compare —
no interning of LLM-supplied names)."
  (find-if (lambda (entry)
             (let ((id (getf entry :id)))
               (and id (string-equal (symbol-name id) target))))
           entries))

(defun %replace-entry (entries target key value)
  (let ((entry (%entry-named entries target)))
    (unless entry
      (error "variant: no pack entry named ~S" target))
    (substitute (let ((copy (copy-list entry)))
                  (setf (getf copy key) value)
                  copy)
                entry entries :test #'eq)))

(defun apply-variant (pack variant)
  "New pack FORM with exactly ONE entry changed (§10.4: one artifact
mutation per cycle, enforced structurally). Only :prompt and :budget
variants are applicable; :code variants become human dossiers."
  (let ((form (pack-form pack)))
    (ecase (variant-kind variant)
      (:prompt
       (let ((updated (%replace-entry (getf form :prompts)
                                      (variant-target variant)
                                      :text (variant-value variant))))
         (setf (getf form :prompts) updated)
         form))
      (:budget
       (let ((updated (%replace-entry (getf form :budgets)
                                      (variant-target variant)
                                      :value (variant-value variant))))
         (setf (getf form :budgets) updated)
         form)))))

(defun write-pack-form (form path)
  "Write FORM as a pack file readable by LOAD-POLICY-PACK."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (with-standard-io-syntax
      ;; Keywords must keep their ':' prefix on disk (the default
      ;; *package* under standard io syntax guarantees it); pack forms
      ;; contain only keywords, strings, and numbers. *print-readably*
      ;; must be off: readably, SBCL prints base-strings as #A(...)
      ;; arrays, which LOAD-POLICY-PACK rejects.
      (let ((*print-pretty* t)
            (*print-case* :downcase)
            (*print-readably* nil))
        (prin1 form out))))
  path)

(defun %pack-summary (pack)
  (format nil "name ~A version ~A~%prompts:~{ ~A~}~%budgets:~{ ~A=~A~}"
          (pack-name pack) (pack-version pack)
          (mapcar (lambda (entry)
                    (string-downcase (symbol-name (getf entry :id))))
                  (pack-prompts pack))
          (loop for entry in (pack-budgets pack)
                append (list (string-downcase
                              (symbol-name (getf entry :id)))
                             (getf entry :value)))))

(defun propose-variant (pack failure-modes propose-fn &key evidence)
  "Ask PROPOSE-FN (prompt → response; build one from a provider with
MAKE-JUDGE-FN) for ONE pack mutation targeting FAILURE-MODES (the
miner's ranked alist). EVIDENCE, when supplied, is the miner's
SUMMARIZE-FAILURE-EVIDENCE block — concrete error texts and offending
arguments the ranked counts alone cannot convey. Returns a VARIANT or
NIL (fail closed)."
  (parse-variant
   (handler-case
       (funcall propose-fn
                (format nil
                        "You improve a coding-harness policy pack. ~
Current pack:~%~A~%~%Observed failure modes (count, descending):~%~
~{- ~A: ~A~%~}~
~@[~%Evidence from the transcripts:~%~A~]~
~%Respond with EXACTLY one JSON object proposing ~
exactly ONE change:~%~
{\"kind\":\"prompt\"|\"budget\",\"target\":\"<entry id>\",~
\"value\":...,\"hypothesis\":\"...\"}~%~
or {\"kind\":\"code\",\"hypothesis\":\"...\"} when only a harness ~
code change would help (it will be routed to a human)."
                        (%pack-summary pack)
                        (loop for (mode . count) in failure-modes
                              append (list (string-downcase
                                            (symbol-name mode))
                                           count))
                        evidence))
     (error () (return-from propose-variant nil)))))
