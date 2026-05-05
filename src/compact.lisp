;;;; src/compact.lisp
;;;;
;;;; Tier 4 C-3 (design hardening) — chat history compaction helper.
;;;;
;;;; The agent loop accumulates one user/assistant message pair per
;;;; turn. With max-turns=20 and verbose tool results, the history can
;;;; bloat past tens of thousands of tokens — fine for 128k-context
;;;; models but tight for smaller ones (Qwen3.6-35B-A3B at 32k window,
;;;; gpt-oss-20b at 8k, etc.).
;;;;
;;;; This file ships the data-structure transformation only:
;;;;   COMPACT-HISTORY: returns a shortened message list, preserving
;;;;     the first N (system + initial user prompt) and the last M
;;;;     (recent context) messages, replacing older middle history
;;;;     with a single digest message.
;;;;   APPROXIMATE-HISTORY-TOKENS: chars/4 budget estimate so callers
;;;;     can decide WHEN to compact.
;;;;
;;;; Auto-triggering inside RUN-AGENT (decide threshold, when to fire,
;;;; whether to checkpoint into the JSONL transcript) is left to a
;;;; v0.4 follow-up. This commit ships the contract so callers and
;;;; tests can iterate against it.

(defpackage #:cl-harness/src/compact
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:export #:approximate-message-tokens
           #:approximate-history-tokens
           #:compact-history
           #:+default-keep-head+
           #:+default-keep-tail+))

(in-package #:cl-harness/src/compact)

(defparameter +default-keep-head+ 2
  "Head messages kept verbatim by COMPACT-HISTORY without explicit
:keep-head. Two covers the canonical agent setup: system prompt
followed by the user's initial issue. Tweak per-call when the loop
puts something else first.")

(defparameter +default-keep-tail+ 6
  "Tail messages kept verbatim by COMPACT-HISTORY without explicit
:keep-tail. Six is empirically the smallest tail that lets the LLM
see the last 2-3 tool round trips (each round being a user message
with the tool result + assistant reply).")

(defun approximate-message-tokens (message)
  "Coarse token estimate for a single MESSAGE hash-table. Uses
chars/4 as a rule-of-thumb tokenizer — good enough for relative-size
budgeting, never quote it as a billing figure. Returns 0 for
messages with empty or missing content."
  (let* ((content (and (hash-table-p message) (gethash "content" message)))
         (chars (and (stringp content) (length content))))
    (if (and chars (plusp chars))
        (max 1 (floor chars 4))
        0)))

(defun approximate-history-tokens (messages)
  "Sum of APPROXIMATE-MESSAGE-TOKENS across MESSAGES."
  (reduce #'+ messages :key #'approximate-message-tokens :initial-value 0))

(defun %digest-message (omitted-count omitted-tokens)
  "Build the single hash-table message that replaces an elided run
of OMITTED-COUNT messages worth ~OMITTED-TOKENS tokens. Goes in as
a `user' role so the LLM sees it as part of the running narrative,
not a system instruction."
  (alist-hash-table
   `(("role" . "user")
     ("content"
      . ,(format nil
                 "[history compacted: ~D earlier message~:P (~~~D tokens) elided to fit the context window. Recent context preserved below.]"
                 omitted-count omitted-tokens)))
   :test 'equal))

(defun compact-history (messages
                        &key (keep-head +default-keep-head+)
                             (keep-tail +default-keep-tail+))
  "Return a shortened MESSAGES list with the first KEEP-HEAD and last
KEEP-TAIL items preserved and the middle replaced by a single digest.

When (length MESSAGES) <= KEEP-HEAD + KEEP-TAIL, MESSAGES is returned
unchanged (the input is already at-or-below the keep budget). The
operation is otherwise:

  ┌─ keep-head verbatim ─┐ ┌── digest ──┐ ┌─── keep-tail verbatim ───┐
  m0 m1                    [N elided ...] m(N-tail) ... m(N-1)

Idempotent on already-compact inputs and total-message-count
preserving up to one digest message — so the result fits in
KEEP-HEAD + 1 + KEEP-TAIL slots regardless of how big the input was.

Does not call an LLM and does not summarise message contents
intelligently; the digest is purely a count + token estimate. A
richer summariser would call the LLM with the elided block as
input — left for v0.4."
  (check-type messages list)
  (check-type keep-head (integer 0))
  (check-type keep-tail (integer 0))
  (let ((n (length messages)))
    (cond
      ((<= n (+ keep-head keep-tail)) messages)
      (t
       (let* ((head (subseq messages 0 keep-head))
              (tail (subseq messages (- n keep-tail)))
              (middle (subseq messages keep-head (- n keep-tail)))
              (digest (%digest-message
                       (length middle)
                       (approximate-history-tokens middle))))
         (append head (list digest) tail))))))
