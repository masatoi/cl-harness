;;;; src/abstraction.lisp
;;;;
;;;; v0.4 Phase 4 of the development harness extension. The
;;;; abstraction ledger: a structured record of which design
;;;; candidates the explore phase recommended adopting versus
;;;; rejecting, attached to each plan-step and aggregated on the
;;;; final develop-result. Implements requirements 4.6
;;;; (abstraction control) and the abstraction-related parts of
;;;; 4.11 (reporting).
;;;;
;;;; The orchestrator parses the explore agent's memo at the end of
;;;; each step. Memos that include lines of the form
;;;;
;;;;   ADOPTED:  <name> — <rationale>
;;;;   REJECTED: <name> — <rationale>
;;;;   DEFERRED: <name> — <rationale>
;;;;
;;;; produce one ABSTRACTION-DECISION per line. Lines that don't
;;;; match the marker shape are ignored; the explore prompt asks for
;;;; the markers but the parser is tolerant of shape drift.

(defpackage #:cl-harness/src/abstraction
  (:use #:cl)
  (:export #:abstraction-decision
           #:make-abstraction-decision
           #:abstraction-decision-kind
           #:abstraction-decision-name
           #:abstraction-decision-rationale
           #:abstraction-decision-step-index
           #:parse-abstraction-decisions
           #:format-abstraction-ledger-markdown
           #:+abstraction-marker-prefixes+))

(in-package #:cl-harness/src/abstraction)

(defparameter +abstraction-marker-prefixes+
  '(("ADOPTED:"  . :adopted)
    ("REJECTED:" . :rejected)
    ("DEFERRED:" . :deferred))
  "Mapping from line-prefix string to ABSTRACTION-DECISION-KIND
keyword. Order is the order PARSE-ABSTRACTION-DECISIONS scans for;
a longer prefix should not be a prefix of a shorter one.")

(defclass abstraction-decision ()
  ((kind :initarg :kind :reader abstraction-decision-kind)
   (name :initarg :name :reader abstraction-decision-name)
   (rationale :initarg :rationale :initform "" :reader abstraction-decision-rationale)
   (step-index :initarg :step-index :initform nil
               :reader abstraction-decision-step-index))
  (:documentation
   "One entry in the abstraction ledger. KIND is :ADOPTED, :REJECTED,
or :DEFERRED. NAME is the abstraction's identifier (e.g. \"defun
greet\", \"defmacro with-log-context\"). RATIONALE is a free-text
one-line justification. STEP-INDEX, when set, points at the
plan-step the decision came from."))

(defun make-abstraction-decision (kind name &key (rationale "") step-index)
  (check-type kind (member :adopted :rejected :deferred))
  (check-type name string)
  (check-type rationale string)
  (make-instance 'abstraction-decision
                 :kind kind :name name
                 :rationale rationale
                 :step-index step-index))

(defun %strip-prefix (line prefix)
  "If LINE (already trimmed) starts with PREFIX, return the rest of
the line trimmed; otherwise NIL."
  (when (and (>= (length line) (length prefix))
             (string-equal (subseq line 0 (length prefix)) prefix))
    (string-trim '(#\Space #\Tab) (subseq line (length prefix)))))

(defun %split-name-and-rationale (rest)
  "REST is the line after the marker prefix, e.g.
\"defun greet — returns Hello, NAME!\" or
\"defmacro with-log-context: only one caller\". Splits on the first
em-dash, en-dash, or colon and returns (values NAME RATIONALE).
When no separator is present the whole REST is the name."
  (let ((seps '("—" "–" ":" " - ")))
    (dolist (sep seps)
      (let ((pos (search sep rest)))
        (when pos
          (return-from %split-name-and-rationale
            (values (string-trim '(#\Space #\Tab) (subseq rest 0 pos))
                    (string-trim '(#\Space #\Tab)
                                 (subseq rest (+ pos (length sep))))))))))
  (values (string-trim '(#\Space #\Tab) rest) ""))

(defun %parse-decision-from-line (line step-index)
  "Return ABSTRACTION-DECISION for LINE if it matches one of the
+ABSTRACTION-MARKER-PREFIXES+; NIL otherwise."
  (let ((trimmed (string-trim '(#\Space #\Tab #\- #\* #\+) line)))
    (dolist (entry +abstraction-marker-prefixes+)
      (let* ((prefix (car entry))
             (kind (cdr entry))
             (rest (%strip-prefix trimmed prefix)))
        (when rest
          (multiple-value-bind (name rationale)
              (%split-name-and-rationale rest)
            (when (and (stringp name) (plusp (length name))
                       ;; "(none)" is a sentinel meaning "no
                       ;; decision under this kind"; don't yield a
                       ;; decision row for it.
                       (not (string-equal name "(none)")))
              (return-from %parse-decision-from-line
                (make-instance 'abstraction-decision
                               :kind kind
                               :name name
                               :rationale rationale
                               :step-index step-index)))))))
    nil))

(defun parse-abstraction-decisions (memo &key step-index)
  "Parse MEMO (the explore phase's free-text summary) for marker
lines and return a list of ABSTRACTION-DECISIONs in the order they
appeared. STEP-INDEX, when supplied, is stamped onto every
returned decision so the develop-level ledger can group by step."
  (when (and (stringp memo) (plusp (length memo)))
    (loop for line in (uiop:split-string memo :separator '(#\Newline))
          for d = (%parse-decision-from-line line step-index)
          when d collect d)))

(defun %decisions-of-kind (decisions kind)
  (remove-if-not (lambda (d) (eq kind (abstraction-decision-kind d)))
                 decisions))

(defun format-abstraction-ledger-markdown (decisions &key (header-level 2))
  "Render a list of ABSTRACTION-DECISIONs as markdown sections,
grouped by KIND. Empty groups are omitted. HEADER-LEVEL controls
the leading `#` count (default 2 → `## Adopted abstractions`)."
  (with-output-to-string (s)
    (let ((header (make-string header-level :initial-element #\#)))
      (loop for (kind . title) in '((:adopted . "Adopted abstractions")
                                    (:rejected . "Rejected abstractions")
                                    (:deferred . "Deferred abstractions"))
            for group = (%decisions-of-kind decisions kind)
            when group
            do (format s "~%~A ~A~%" header title)
               (dolist (d group)
                 (format s "- ~A~A~A~%"
                         (abstraction-decision-name d)
                         (if (plusp (length (abstraction-decision-rationale d)))
                             " — " "")
                         (abstraction-decision-rationale d)))))))
