;;;; tests/compact-test.lisp
;;;;
;;;; Tier 4 C-3 unit tests for src/compact.lisp.

(defpackage #:cl-harness/tests/compact-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/model
                #:make-chat-message)
  (:import-from #:cl-harness/src/compact
                #:approximate-message-tokens
                #:approximate-history-tokens
                #:compact-history))

(in-package #:cl-harness/tests/compact-test)

(defun %msg (role text)
  (make-chat-message role text))

(deftest approximate-message-tokens-uses-chars-by-four
  (let ((m (%msg "user" "abcdefghijkl")))   ; 12 chars / 4 = 3 tokens
    (ok (= 3 (approximate-message-tokens m)))))

(deftest approximate-message-tokens-handles-empty-and-missing-content
  (ok (zerop (approximate-message-tokens (%msg "user" ""))))
  (ok (zerop (approximate-message-tokens
              (alexandria:alist-hash-table '() :test 'equal)))))

(deftest approximate-history-tokens-sums-across-messages
  (let ((h (list (%msg "system" "1234")          ; 1
                 (%msg "user" "12345678")        ; 2
                 (%msg "assistant" "1234"))))    ; 1
    (ok (= 4 (approximate-history-tokens h)))))

;; --- compact-history -----------------------------------------------------

(deftest compact-history-noop-when-already-short
  (let ((h (list (%msg "system" "S")
                 (%msg "user" "U1")
                 (%msg "assistant" "A1")
                 (%msg "user" "U2")
                 (%msg "assistant" "A2"))))
    (ok (eq h (compact-history h :keep-head 2 :keep-tail 6))
        "input is below keep-head + keep-tail, so it's returned as-is")))

(deftest compact-history-preserves-head-and-tail
  ;; 12 messages, keep-head 2, keep-tail 4 → result length = 2 + 1 + 4 = 7
  (let* ((h (loop for i from 0 below 12
                  collect (%msg "user" (format nil "msg-~D" i))))
         (out (compact-history h :keep-head 2 :keep-tail 4)))
    (ok (= 7 (length out)))
    (ok (equal "msg-0" (gethash "content" (nth 0 out))))
    (ok (equal "msg-1" (gethash "content" (nth 1 out))))
    (let ((digest-content (gethash "content" (nth 2 out))))
      (ok (search "history compacted" digest-content))
      (ok (search "6 earlier" digest-content)
          "middle elided 12 - 2 - 4 = 6 messages"))
    (ok (equal "msg-8" (gethash "content" (nth 3 out))))
    (ok (equal "msg-9" (gethash "content" (nth 4 out))))
    (ok (equal "msg-10" (gethash "content" (nth 5 out))))
    (ok (equal "msg-11" (gethash "content" (nth 6 out))))))

(deftest compact-history-defaults-cover-typical-agent-loop
  ;; A 30-message run with the defaults (head 2 + tail 6) should
  ;; reduce to 2 + 1 digest + 6 = 9.
  (let* ((h (loop for i from 0 below 30
                  collect (%msg "user" (format nil "msg-~D" i))))
         (out (compact-history h)))
    (ok (= 9 (length out)))
    (ok (equal "msg-0" (gethash "content" (first out))))
    (ok (equal "msg-29" (gethash "content" (car (last out)))))))

(deftest compact-history-digest-mentions-token-estimate
  (let* ((h (list (%msg "system" "S")
                  (%msg "user" "U")
                  ;; 8 middle messages, each 8 chars = 2 tokens; total 16
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "12345678")
                  (%msg "user" "T1")
                  (%msg "user" "T2")))
         (out (compact-history h :keep-head 2 :keep-tail 2))
         (digest-content (gethash "content" (nth 2 out))))
    (ok (search "8 earlier" digest-content))
    (ok (search "16 tokens" digest-content)
        "digest reports the approximate token cost of the elided run")))
