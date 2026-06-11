# SP2: L1 Environment (cl-mcp observation/action space) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L1 environment of the autonomous-harness redesign — cl-mcp wrapped as a policy-restricted observation/action space whose every action and observation is recorded into the SP1 event log — including a stdio-only MCP client adapt-copied from the legacy implementation.

**Architecture:** Four new modules in `cl-harness-next`: `mcp-client` (JSON-RPC 2.0 core, adapted from legacy `src/mcp.lisp` with HTTP removed), `mcp-stdio` (subprocess transport with reader thread, adapted near-verbatim from legacy `src/mcp-stdio.lisp`), `action-space` (the three tool-policy conditions as data-driven allow rules, adapted from legacy `src/policy.lisp`), and `environment` (the L1 CLOS protocol: `environment-action-space` / `perform-action` / `environment-close` over a cl-mcp client, emitting `:action`/`:observation` events). Plus a small `policy-pack` extension (`:tool-policies` section) so rules can live in packs (spec 原則4). Spec: `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md` §5 (L1), §12 (inherited lessons). Decision log: adapt-copy stdio-only was confirmed by the user (2026-06-12); HTTP transport is dropped (per-run stdio subprocess is the isolation model).

**Tech Stack:** SBCL, ASDF package-inferred-system, rove, yason, alexandria, bordeaux-threads (**new top-level dependency**), uiop (`launch-program`).

**Test strategy (carried from legacy):** no real subprocess in unit tests — stdio transport is driven through injected in-memory streams + direct `%route-response-line` calls; the environment is driven through a scripted `mcp-transport` subclass defined in the test file. One real-subprocess integration test is gated on `CL_HARNESS_INTEGRATION=1` and reports a skip message otherwise.

**Conventions that bind this plan** (same as SP1): 2-space indent, ≤100 columns, blank line between top-level forms, docstrings on public functions, no `:local-nicknames`, third-party libs via qualified names unless the file `:import-from`s them (mcp-stdio imports bordeaux-threads symbols — that also gives ASDF the dependency edge), conditions get `:initform` on every slot so they print when constructed bare (SP1 final-review hardening — apply to ALL new conditions). Lisp edits via cl-mcp tools (`Write` for brand-new files + `lisp-check-parens`; `lisp-edit-form`/`lisp-patch-form` for existing). Lint `mallet` before each commit. Tests via cl-mcp `run-tests` `{"system": "cl-harness-next/tests"}`; register with `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")` via repl-eval if the worker restarted.

---

## File Structure

```text
next/src/mcp-client.lisp      NEW  JSON-RPC 2.0 core (transport protocol, client,
                                   wire build/parse, handshake, list/call) — stdio-only
next/src/mcp-stdio.lisp       NEW  subprocess transport: reader thread, pending table,
                                   timeouts, stderr drain (near-verbatim adapt-copy)
next/src/action-space.lisp    NEW  3 conditions as allow rules + wildcard matcher +
                                   action-space class
next/src/environment.lisp     NEW  L1 protocol + cl-mcp-environment (policy filter +
                                   event emission)
next/src/policy-pack.lisp     MOD  +section-keys+ gains :tool-policies; new slot+accessor
next/src/main.lisp            MOD  facade re-exports
next/tests/mcp-client-test.lisp    NEW
next/tests/mcp-stdio-test.lisp     NEW
next/tests/action-space-test.lisp  NEW
next/tests/environment-test.lisp   NEW
next/tests/policy-pack-test.lisp   MOD  :tool-policies tests
next/tests/main-test.lisp          MOD  facade-level acceptance test
cl-harness-next.asd           MOD  + bordeaux-threads dep, + 4 test files
README.md                     MOD  one sentence in the next/ subsection
```

Dependency edges: `mcp-stdio` → `mcp-client`; `environment` → `mcp-client`, `mcp-stdio`, `action-space`, `event-log`; `action-space` and `policy-pack` stay independent of each other (wiring rules from a pack into `make-action-space` is the caller's one-liner via `:rules`).

---

### Task 1: MCP client core (JSON-RPC 2.0, stdio-only)

**Files:**
- Create: `next/tests/mcp-client-test.lisp`
- Create: `next/src/mcp-client.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/mcp-client-test.lisp`:

```lisp
;;;; next/tests/mcp-client-test.lisp
;;;;
;;;; Unit tests for next/src/mcp-client.lisp: JSON-RPC wire format,
;;;; error envelope decoding, client construction. Transport mechanics
;;;; are covered in mcp-stdio-test; the handshake/list/call flow is
;;;; covered end-to-end in environment-test via a scripted transport.

(defpackage #:cl-harness-next/tests/mcp-client-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-build-request
                #:mcp-build-notification
                #:mcp-parse-response
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message
                #:mcp-transport
                #:mcp-client
                #:make-mcp-client))

(in-package #:cl-harness-next/tests/mcp-client-test)

(deftest build-request-shape
  (let ((parsed (yason:parse
                 (mcp-build-request 7 "tools/call"
                                    :params (alexandria:plist-hash-table
                                             (list "name" "run-tests")
                                             :test #'equal)))))
    (ok (equal "2.0" (gethash "jsonrpc" parsed)))
    (ok (= 7 (gethash "id" parsed)))
    (ok (equal "tools/call" (gethash "method" parsed)))
    (ok (equal "run-tests" (gethash "name" (gethash "params" parsed))))))

(deftest build-notification-has-no-id
  (let ((parsed (yason:parse
                 (mcp-build-notification "notifications/initialized"))))
    (ok (equal "2.0" (gethash "jsonrpc" parsed)))
    (ok (null (gethash "id" parsed)))
    (ok (equal "notifications/initialized" (gethash "method" parsed)))))

(deftest parse-response-returns-result
  (let ((result (mcp-parse-response
                 "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":42}}")))
    (ok (= 42 (gethash "value" result)))))

(deftest parse-response-signals-mcp-error
  (ok (handler-case
          (progn (mcp-parse-response
                  (concatenate 'string
                               "{\"jsonrpc\":\"2.0\",\"id\":1,"
                               "\"error\":{\"code\":-32000,\"message\":\"boom\"}}"))
                 nil)
        (mcp-error (e)
          (and (= -32000 (mcp-error-code e))
               (equal "boom" (mcp-error-message e)))))))

(deftest mcp-error-prints-without-initargs
  (ok (stringp (princ-to-string (make-condition 'mcp-error)))))

(deftest make-mcp-client-requires-transport
  (ok (handler-case (progn (make-mcp-client 42) nil)
        (error () t)))
  (ok (typep (make-mcp-client (make-instance 'mcp-transport)) 'mcp-client)))
```

Create `next/src/mcp-client.lisp` with the package definition only (so the
red state is undefined-function, not a missing package):

```lisp
;;;; next/src/mcp-client.lisp
;;;;
;;;; JSON-RPC 2.0 client core for cl-mcp, adapted from legacy
;;;; src/mcp.lisp with the HTTP transport removed (SP2 decision:
;;;; stdio-only — the redesign's isolation model is one cl-mcp
;;;; subprocess per run, spec §5). The transport is an abstract CLOS
;;;; object; the stdio implementation lives in next/src/mcp-stdio.lisp.

(defpackage #:cl-harness-next/src/mcp-client
  (:use #:cl)
  (:export #:+mcp-protocol-version+
           #:mcp-error
           #:mcp-error-code
           #:mcp-error-message
           #:mcp-error-data
           #:mcp-transport
           #:transport-send-request
           #:transport-close
           #:mcp-client
           #:make-mcp-client
           #:mcp-client-transport
           #:mcp-client-protocol-version
           #:mcp-build-request
           #:mcp-build-notification
           #:mcp-parse-response
           #:initialize-mcp
           #:list-tools
           #:call-tool
           #:close-mcp-client))

(in-package #:cl-harness-next/src/mcp-client)
```

Add `"cl-harness-next/tests/mcp-client-test"` to the tests system's
`:depends-on` in `cl-harness-next.asd` (after the policy-pack-test entry).

- [ ] **Step 2: Run tests to verify they fail**

cl-mcp `run-tests` `{"system": "cl-harness-next/tests"}`.
Expected: FAIL — `mcp-build-request` undefined; the 34 existing tests
still pass.

- [ ] **Step 3: Implement the client core**

Append to `next/src/mcp-client.lisp`:

```lisp
(defparameter +mcp-protocol-version+ "2025-06-18"
  "MCP protocol version this client negotiates with the server.")

(define-condition mcp-error (error)
  ((code :initarg :code :initform nil :reader mcp-error-code)
   (message :initarg :message :initform "(no message)"
            :reader mcp-error-message)
   (data :initarg :data :initform nil :reader mcp-error-data))
  (:report (lambda (condition stream)
             (format stream "MCP error ~A: ~A"
                     (mcp-error-code condition)
                     (mcp-error-message condition))))
  (:documentation "JSON-RPC error envelope returned by an MCP server."))

(defclass mcp-transport ()
  ()
  (:documentation
   "Abstract base for an MCP wire transport. Concrete subclasses
implement TRANSPORT-SEND-REQUEST and (optionally) TRANSPORT-CLOSE."))

(defgeneric transport-send-request (transport body)
  (:documentation
   "Send BODY (a JSON-RPC request or notification string) over TRANSPORT
and return the response body as a string. For notifications the returned
string is empty; the caller discards it."))

(defgeneric transport-close (transport)
  (:documentation
   "Release any resources held by TRANSPORT. Default is a no-op.")
  (:method ((transport mcp-transport)) nil))

(defclass mcp-client ()
  ((transport :initarg :transport :reader mcp-client-transport)
   (protocol-version :initarg :protocol-version
                     :initform +mcp-protocol-version+
                     :reader mcp-client-protocol-version)
   (next-id :initform 0 :accessor %mcp-next-id))
  (:documentation
   "JSON-RPC 2.0 client for cl-mcp. The wire-level details live in
TRANSPORT; the client owns only the request-id counter and the
protocol-version handshake state."))

(defun make-mcp-client (transport &key (protocol-version +mcp-protocol-version+))
  "Construct an MCP-CLIENT over TRANSPORT (an MCP-TRANSPORT instance)."
  (check-type transport mcp-transport)
  (check-type protocol-version string)
  (make-instance 'mcp-client
                 :transport transport
                 :protocol-version protocol-version))

(defun close-mcp-client (client)
  "Release the transport's resources. Safe to call multiple times."
  (transport-close (mcp-client-transport client)))

(defun mcp-build-request (id method &key params)
  "Build a JSON-RPC 2.0 request string with ID, METHOD, and optional
PARAMS. PARAMS, when supplied, must already be a hash-table that yason
can encode."
  (check-type id integer)
  (check-type method string)
  (let ((table (alexandria:alist-hash-table
                `(("jsonrpc" . "2.0")
                  ("id" . ,id)
                  ("method" . ,method))
                :test #'equal)))
    (when params
      (setf (gethash "params" table) params))
    (with-output-to-string (out) (yason:encode table out))))

(defun mcp-build-notification (method &key params)
  "Build a JSON-RPC 2.0 notification (no id) for METHOD."
  (check-type method string)
  (let ((table (alexandria:alist-hash-table
                `(("jsonrpc" . "2.0")
                  ("method" . ,method))
                :test #'equal)))
    (when params
      (setf (gethash "params" table) params))
    (with-output-to-string (out) (yason:encode table out))))

(defun mcp-parse-response (json-string)
  "Parse a JSON-RPC 2.0 response string and return its RESULT object.
Signals MCP-ERROR if the response carries an error envelope."
  (check-type json-string string)
  (let ((parsed (yason:parse json-string)))
    (let ((err (gethash "error" parsed)))
      (when err
        (error 'mcp-error
               :code (gethash "code" err)
               :message (gethash "message" err)
               :data (gethash "data" err))))
    (gethash "result" parsed)))

(defun %send (client body)
  "Forward BODY to CLIENT's transport and return the response body string."
  (transport-send-request (mcp-client-transport client) body))

(defun initialize-mcp (client &key (client-name "cl-harness-next")
                                   (client-version "0.1.0"))
  "Run the MCP initialize handshake and send notifications/initialized.
Returns the server's INITIALIZE result hash-table."
  (let* ((id (incf (%mcp-next-id client)))
         (params (alexandria:alist-hash-table
                  `(("protocolVersion" . ,(mcp-client-protocol-version client))
                    ("capabilities" . ,(make-hash-table :test #'equal))
                    ("clientInfo" . ,(alexandria:alist-hash-table
                                      `(("name" . ,client-name)
                                        ("version" . ,client-version))
                                      :test #'equal)))
                  :test #'equal))
         (request (mcp-build-request id "initialize" :params params))
         (response (%send client request))
         (result (mcp-parse-response response)))
    (%send client (mcp-build-notification "notifications/initialized"))
    result))

(defgeneric list-tools (client)
  (:documentation
   "Return the tool descriptors from CLIENT's tools/list (a list or
vector of hash-tables, per yason's array decoding)."))

(defmethod list-tools ((client mcp-client))
  (let* ((id (incf (%mcp-next-id client)))
         (request (mcp-build-request id "tools/list"))
         (response (%send client request))
         (result (mcp-parse-response response)))
    (gethash "tools" result)))

(defgeneric call-tool (client tool-name arguments)
  (:documentation
   "Invoke TOOL-NAME with ARGUMENTS hash-table on CLIENT. Returns the
tools/call RESULT hash-table."))

(defmethod call-tool ((client mcp-client) tool-name (arguments hash-table))
  (check-type tool-name string)
  (let* ((id (incf (%mcp-next-id client)))
         (params (alexandria:alist-hash-table
                  `(("name" . ,tool-name)
                    ("arguments" . ,arguments))
                  :test #'equal))
         (request (mcp-build-request id "tools/call" :params params))
         (response (%send client request)))
    (mcp-parse-response response)))
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — 40 tests total (34 + 6 new).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/mcp-client.lisp next/tests/mcp-client-test.lisp
git add next/src/mcp-client.lisp next/tests/mcp-client-test.lisp cl-harness-next.asd
git commit -m "feat(next): JSON-RPC MCP client core, stdio-only adapt of legacy mcp.lisp"
```

---

### Task 2: Stdio transport (subprocess, reader thread, timeouts)

**Files:**
- Create: `next/tests/mcp-stdio-test.lisp`
- Create: `next/src/mcp-stdio.lisp`
- Modify: `cl-harness-next.asd` (add `"bordeaux-threads"` to the PRIMARY system's `:depends-on` after `"ironclad"`, and add the test file to the tests system)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/mcp-stdio-test.lisp`:

```lisp
;;;; next/tests/mcp-stdio-test.lisp
;;;;
;;;; Tests for next/src/mcp-stdio.lisp. Spawning a real cl-mcp
;;;; subprocess is gated on CL_HARNESS_INTEGRATION=1; everything else
;;;; drives the transport through injected in-memory streams plus
;;;; %ROUTE-RESPONSE-LINE so routing/lifecycle logic is exercised
;;;; without needing ros/cl-mcp at test time (legacy-proven pattern).

(defpackage #:cl-harness-next/tests/mcp-stdio-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:transport-send-request
                #:transport-close
                #:initialize-mcp
                #:list-tools
                #:close-mcp-client)
  (:import-from #:cl-harness-next/src/mcp-stdio
                #:stdio-mcp-transport
                #:make-stdio-mcp-client
                #:stdio-mcp-error
                #:stdio-request-stream
                #:%route-response-line))

(in-package #:cl-harness-next/tests/mcp-stdio-test)

(defun %make-test-transport (&key (timeout 2))
  "STDIO-MCP-TRANSPORT bound to harmless in-memory streams. The reader
thread is NOT started; tests deliver responses via %ROUTE-RESPONSE-LINE
directly, so delivery runs under controlled timing without a live
subprocess."
  (make-instance 'stdio-mcp-transport
                 :request-stream (make-string-output-stream)
                 :response-stream (make-string-input-stream "")
                 :request-timeout timeout))

(deftest routes-response-by-id
  (let* ((transport (%make-test-transport))
         (out (cons nil nil))
         (sender (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (setf (car out)
                              (transport-send-request
                               transport
                               "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"foo\",\"params\":{}}"))
                      (error (c) (setf (cdr out) c))))
                  :name "stdio-test-sender")))
    (sleep 0.1)
    (%route-response-line
     transport "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"value\":42}}")
    (bordeaux-threads:join-thread sender)
    (ok (null (cdr out)))
    (ok (search "\"value\":42" (car out)))))

(deftest request-times-out
  (let ((transport (%make-test-transport :timeout 1))
        (outcome nil))
    (let ((sender (bordeaux-threads:make-thread
                   (lambda ()
                     (handler-case
                         (progn (transport-send-request
                                 transport
                                 "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}")
                                (setf outcome :returned))
                       (stdio-mcp-error () (setf outcome :timeout)))))))
      (bordeaux-threads:join-thread sender)
      (ok (eq :timeout outcome)))))

(deftest notification-writes-and-returns-empty
  (let ((transport (%make-test-transport)))
    (ok (equal "" (transport-send-request
                   transport
                   "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))
    (ok (search "notifications/initialized"
                (get-output-stream-string
                 (stdio-request-stream transport))))))

(deftest closed-transport-rejects-send
  (let ((transport (%make-test-transport)))
    (transport-close transport)
    (ok (handler-case
            (progn (transport-send-request
                    transport "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"x\"}")
                   nil)
          (stdio-mcp-error () t)))))

(deftest close-wakes-blocked-sender
  (let* ((transport (%make-test-transport :timeout 30))
         (outcome nil)
         (sender (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (progn (transport-send-request
                                transport
                                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"x\"}")
                               (setf outcome :returned))
                      (stdio-mcp-error () (setf outcome :error)))))))
    (sleep 0.1)
    (transport-close transport)
    (bordeaux-threads:join-thread sender)
    (ok (eq :error outcome))))

(deftest stdio-error-prints-without-initargs
  (ok (stringp (princ-to-string (make-condition 'stdio-mcp-error)))))

(deftest stdio-integration-against-real-cl-mcp
  (if (equal "1" (uiop:getenv "CL_HARNESS_INTEGRATION"))
      (let ((client (make-stdio-mcp-client :request-timeout 120)))
        (unwind-protect
             (progn
               (initialize-mcp client)
               (ok (plusp (length (coerce (list-tools client) 'list)))))
          (close-mcp-client client)))
      (ok t "skipped real-subprocess test (set CL_HARNESS_INTEGRATION=1)")))
```

Add `"cl-harness-next/tests/mcp-stdio-test"` to the tests system's
`:depends-on`, and `"bordeaux-threads"` to the primary system's
`:depends-on` (after `"ironclad"`).

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL at load — package `cl-harness-next/src/mcp-stdio` does
not exist. That is the expected red state for a new module.

- [ ] **Step 3: Implement the stdio transport**

Create `next/src/mcp-stdio.lisp` (adapt-copy of legacy
`src/mcp-stdio.lisp`; deltas: package rename, import from
`cl-harness-next/src/mcp-client`, `:initform` on the condition slot,
`make-stdio-mcp-client` updated to the new `make-mcp-client` signature,
`stdio-request-stream` added to exports for tests):

```lisp
;;;; next/src/mcp-stdio.lisp
;;;;
;;;; Stdio MCP transport, adapted from legacy src/mcp-stdio.lisp.
;;;; Spawns a cl-mcp subprocess, talks JSON-RPC 2.0 over its
;;;; stdin/stdout, drains its stderr to *ERROR-OUTPUT*, and exposes
;;;; the result as an MCP-TRANSPORT so MCP-CLIENT never branches on
;;;; transport. One subprocess per environment is the redesign's
;;;; isolation model (spec §5).

(defpackage #:cl-harness-next/src/mcp-stdio
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:transport-close
                #:make-mcp-client
                #:+mcp-protocol-version+)
  (:export #:stdio-mcp-transport
           #:make-stdio-mcp-transport
           #:make-stdio-mcp-client
           #:stdio-mcp-error
           #:stdio-mcp-error-message
           #:*default-stdio-command*
           ;; Internal but public for tests:
           #:stdio-request-stream
           #:%route-response-line))

(in-package #:cl-harness-next/src/mcp-stdio)

(defparameter *default-stdio-command*
  '("ros" "run" "-s" "cl-mcp"
    "-e" "(cl-mcp:run :transport :stdio)")
  "Default argv list for spawning cl-mcp in stdio mode via Roswell.
Override with :COMMAND on MAKE-STDIO-MCP-TRANSPORT when cl-mcp is
installed differently or a prebuilt binary is on $PATH.")

(define-condition stdio-mcp-error (error)
  ((message :initarg :message :initform "(no message)"
            :reader stdio-mcp-error-message))
  (:report (lambda (condition stream)
             (format stream "stdio-mcp error: ~A"
                     (stdio-mcp-error-message condition))))
  (:documentation "Wire-level failure of the stdio MCP transport."))

(defstruct (%pending-entry (:conc-name %pending-))
  (cv (make-condition-variable))
  (result nil)
  (done-p nil))

(defclass stdio-mcp-transport (mcp-transport)
  ((process-info :initarg :process-info :initform nil
                 :reader stdio-process-info)
   (request-stream :initarg :request-stream :reader stdio-request-stream)
   (response-stream :initarg :response-stream :reader stdio-response-stream)
   (lock :initform (make-lock "stdio-mcp-lock") :reader stdio-lock)
   (pending :initform (make-hash-table :test 'eql) :reader stdio-pending)
   (reader-thread :initform nil :accessor stdio-reader-thread)
   (stderr-stream :initarg :stderr-stream :initform nil
                  :reader stdio-stderr-stream)
   (stderr-thread :initform nil :accessor stdio-stderr-thread)
   (closed-p :initform nil :accessor stdio-closed-p)
   (request-timeout :initarg :request-timeout :initform 60
                    :reader stdio-request-timeout))
  (:documentation
   "MCP transport over a subprocess's stdin/stdout (newline-delimited
JSON-RPC). PROCESS-INFO is the UIOP launch handle (NIL when a stream
pair was injected directly, e.g. by tests). PENDING maps a JSON-RPC
request id to a %PENDING-ENTRY whose CV is signalled when the matching
response line arrives."))

(defun %parse-id-from-body (body)
  "Return the JSON-RPC \"id\" field from a request BODY string, or NIL
when BODY is a notification."
  (let ((parsed (yason:parse body)))
    (and (hash-table-p parsed) (gethash "id" parsed))))

(defun %route-response-line (transport line)
  "Parse LINE as a JSON-RPC response and deliver it to the pending entry
matching its id. Lines without an id and unmatched ids are dropped.
Parse errors are logged on *ERROR-OUTPUT* and tolerated, so one
malformed line does not break the reader thread."
  (handler-case
      (let* ((parsed (yason:parse line))
             (id (and (hash-table-p parsed) (gethash "id" parsed))))
        (when id
          (with-lock-held ((stdio-lock transport))
            (let ((entry (gethash id (stdio-pending transport))))
              (when entry
                (setf (%pending-result entry) line
                      (%pending-done-p entry) t)
                (condition-notify (%pending-cv entry)))))))
    (error (c)
      (format *error-output* "[stdio-mcp parse error] ~A line=~S~%" c line))))

(defun %wake-all-pending (transport reason)
  "Mark every outstanding pending entry done with REASON in the result
slot and signal its CV so any waiter unblocks. Used on EOF/close."
  (with-lock-held ((stdio-lock transport))
    (maphash (lambda (id entry)
               (declare (ignore id))
               (unless (%pending-done-p entry)
                 (setf (%pending-result entry) reason
                       (%pending-done-p entry) :stream-closed)
                 (condition-notify (%pending-cv entry))))
             (stdio-pending transport))))

(defun %read-loop (transport)
  "Reader-thread body: read newline-delimited JSON from the transport's
RESPONSE-STREAM and route each line into the pending table."
  (let ((stream (stdio-response-stream transport)))
    (handler-case
        (loop
          (let ((line (read-line stream nil nil)))
            (when (null line) (return))
            (unless (zerop (length line))
              (%route-response-line transport line))))
      (error (c)
        (format *error-output* "[stdio-mcp reader] ~A~%" c)))
    (%wake-all-pending transport "stdio response stream closed")))

(defun %drain-stderr (stream)
  "Drain the cl-mcp subprocess's stderr to *ERROR-OUTPUT*, prefixed.
Runs on its own thread so the subprocess's pipe never fills up."
  (handler-case
      (loop for line = (read-line stream nil nil)
            while line
            do (format *error-output* "[cl-mcp stderr] ~A~%" line)
               (force-output *error-output*))
    (error () nil)))

(defgeneric start-reader-threads (transport)
  (:documentation
   "Spawn the reader (and stderr drain, if applicable) threads bound to
TRANSPORT. Idempotent: a second call does nothing.")
  (:method ((transport stdio-mcp-transport))
    (unless (stdio-reader-thread transport)
      (setf (stdio-reader-thread transport)
            (make-thread (lambda () (%read-loop transport))
                         :name "stdio-mcp-reader")))
    (when (and (stdio-stderr-stream transport)
               (not (stdio-stderr-thread transport)))
      (setf (stdio-stderr-thread transport)
            (make-thread (lambda ()
                           (%drain-stderr (stdio-stderr-stream transport)))
                         :name "stdio-mcp-stderr")))))

(defun make-stdio-mcp-transport (&key command (request-timeout 60))
  "Spawn a cl-mcp subprocess (COMMAND, default *DEFAULT-STDIO-COMMAND*)
and return a STDIO-MCP-TRANSPORT bound to its pipes. Reader and stderr
drain threads start immediately. Caller is responsible for invoking
TRANSPORT-CLOSE (or CLOSE-MCP-CLIENT) to terminate the subprocess."
  (let* ((cmd (or command *default-stdio-command*))
         (process-info (uiop:launch-program
                        cmd
                        :input :stream
                        :output :stream
                        :error-output :stream
                        :element-type 'character))
         (transport (make-instance
                     'stdio-mcp-transport
                     :process-info process-info
                     :request-stream (uiop:process-info-input process-info)
                     :response-stream (uiop:process-info-output process-info)
                     :stderr-stream (uiop:process-info-error-output process-info)
                     :request-timeout request-timeout)))
    (start-reader-threads transport)
    transport))

(defmethod transport-send-request ((tr stdio-mcp-transport) body)
  (when (stdio-closed-p tr)
    (error 'stdio-mcp-error
           :message "stdio-mcp-transport is closed"))
  (let ((id (%parse-id-from-body body))
        (out (stdio-request-stream tr)))
    (cond
      ((null id)
       ;; Notification: write & forget.
       (write-line body out)
       (force-output out)
       "")
      (t
       (let ((entry (make-%pending-entry)))
         (with-lock-held ((stdio-lock tr))
           (setf (gethash id (stdio-pending tr)) entry))
         (write-line body out)
         (force-output out)
         (with-lock-held ((stdio-lock tr))
           (unless (%pending-done-p entry)
             (condition-wait (%pending-cv entry) (stdio-lock tr)
                             :timeout (stdio-request-timeout tr)))
           (let ((done (%pending-done-p entry))
                 (result (%pending-result entry)))
             (remhash id (stdio-pending tr))
             (cond
               ((eq done :stream-closed)
                (error 'stdio-mcp-error
                       :message (or result "stdio response stream closed")))
               ((null done)
                (error 'stdio-mcp-error
                       :message
                       (format nil
                               "stdio-mcp request id=~A timed out after ~A s"
                               id (stdio-request-timeout tr))))
               (t result)))))))))

(defmethod transport-close ((tr stdio-mcp-transport))
  (unless (stdio-closed-p tr)
    (setf (stdio-closed-p tr) t)
    (let ((proc (stdio-process-info tr)))
      (when proc
        (handler-case (uiop:terminate-process proc :urgent t) (error () nil))
        (handler-case (uiop:wait-process proc) (error () nil))))
    ;; Closing the subprocess lets the reader thread see EOF and exit;
    ;; with injected test streams the caller owns the streams.
    (let ((reader (stdio-reader-thread tr)))
      (when reader
        (handler-case (join-thread reader) (error () nil))))
    (let ((stderr (stdio-stderr-thread tr)))
      (when stderr
        (handler-case (join-thread stderr) (error () nil))))
    ;; Anyone still waiting (possible with injected streams) must be
    ;; woken explicitly so they do not block forever.
    (%wake-all-pending tr "stdio-mcp-transport closed")))

(defun make-stdio-mcp-client (&key command (request-timeout 60)
                                   protocol-version)
  "Convenience: build an MCP-CLIENT against a fresh STDIO-MCP-TRANSPORT."
  (make-mcp-client (make-stdio-mcp-transport
                    :command command
                    :request-timeout request-timeout)
                   :protocol-version (or protocol-version
                                         +mcp-protocol-version+)))
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — 47 tests (40 + 7; the integration test passes as a
skip unless `CL_HARNESS_INTEGRATION=1`).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/mcp-stdio.lisp next/tests/mcp-stdio-test.lisp
git add next/src/mcp-stdio.lisp next/tests/mcp-stdio-test.lisp cl-harness-next.asd
git commit -m "feat(next): stdio MCP transport adapt-copied from legacy"
```

---

### Task 3: Action space (tool-policy conditions as data)

**Files:**
- Create: `next/tests/action-space-test.lisp`
- Create: `next/src/action-space.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/action-space-test.lisp`:

```lisp
;;;; next/tests/action-space-test.lisp
;;;;
;;;; Unit tests for next/src/action-space.lisp: rule matching (exact +
;;;; trailing-* glob), the three spec conditions, live-catalog
;;;; filtering, custom rule override (spec §5 / PRD §8.5).

(defpackage #:cl-harness-next/tests/action-space-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/action-space
                #:make-action-space
                #:allowed-tools
                #:action-allowed-p))

(in-package #:cl-harness-next/tests/action-space-test)

(deftest rule-matching
  (let ((exact (make-action-space nil :rules '("run-tests")))
        (glob (make-action-space nil :rules '("fs-*"))))
    (ok (action-allowed-p exact "run-tests"))
    (ok (not (action-allowed-p exact "run-tests-fast")))
    (ok (action-allowed-p glob "fs-read-file"))
    (ok (not (action-allowed-p glob "lisp-read-file")))
    (ok (handler-case
            (progn (action-allowed-p
                    (make-action-space nil :rules '("f*s")) "fs")
                   nil)
          (error () t)))))

(deftest file-only-condition
  (let ((space (make-action-space :file-only)))
    (ok (action-allowed-p space "fs-read-file"))
    (ok (action-allowed-p space "run-tests"))
    (ok (not (action-allowed-p space "repl-eval")))
    (ok (not (action-allowed-p space "lisp-edit-form")))
    (ok (not (action-allowed-p space "code-find")))))

(deftest generic-mcp-condition
  (let ((space (make-action-space :generic-mcp)))
    (ok (action-allowed-p space "lisp-edit-form"))
    (ok (action-allowed-p space "clgrep-search"))
    (ok (not (action-allowed-p space "repl-eval")))
    (ok (not (action-allowed-p space "code-find")))))

(deftest runtime-native-condition
  (let ((space (make-action-space :runtime-native)))
    (ok (action-allowed-p space "repl-eval"))
    (ok (action-allowed-p space "inspect-object"))
    (ok (action-allowed-p space "pool-kill-worker"))
    (ok (action-allowed-p space "lisp-patch-form"))))

(deftest unknown-mode-errors
  (ok (handler-case (progn (make-action-space :bogus) nil)
        (error () t))))

(deftest allowed-tools-uses-known-snapshot
  (ok (equal '("fs-list-directory" "fs-read-file" "fs-write-file"
               "load-system" "run-tests")
             (allowed-tools (make-action-space :file-only)))))

(deftest allowed-tools-filters-live-catalog
  (let ((space (make-action-space
                :runtime-native
                :available-tools '("repl-eval" "new-tool" "run-tests"))))
    (ok (equal '("repl-eval" "run-tests") (allowed-tools space)))))

(deftest custom-rules-override-mode
  (let ((space (make-action-space :runtime-native :rules '("run-tests"))))
    (ok (action-allowed-p space "run-tests"))
    (ok (not (action-allowed-p space "repl-eval")))))
```

Create `next/src/action-space.lisp` with the package definition only:

```lisp
;;;; next/src/action-space.lisp
;;;;
;;;; Action-space restriction for the L1 environment (spec §5): the
;;;; tool-policy conditions (file-only / generic-mcp / runtime-native)
;;;; defined as data-driven allow rules over cl-mcp tool names.
;;;; Adapted from legacy src/policy.lisp; rule semantics unchanged
;;;; (exact string, or trailing-* prefix glob). Rules may also come
;;;; from a policy pack's :tool-policies section (原則4).

(defpackage #:cl-harness-next/src/action-space
  (:use #:cl)
  (:export #:+known-tool-names+
           #:+condition-allow-rules+
           #:condition-rules
           #:action-space
           #:make-action-space
           #:action-space-mode
           #:action-space-rules
           #:action-space-available-tools
           #:allowed-tools
           #:action-allowed-p))

(in-package #:cl-harness-next/src/action-space)
```

Add `"cl-harness-next/tests/action-space-test"` to the tests system's
`:depends-on`.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `make-action-space` undefined; 47 existing tests pass.

- [ ] **Step 3: Implement the action space**

Append to `next/src/action-space.lisp`:

```lisp
(alexandria:define-constant +known-tool-names+
    '("fs-list-directory" "fs-read-file" "fs-write-file"
      "fs-set-project-root" "fs-get-project-info"
      "load-system" "run-tests"
      "lisp-read-file" "lisp-edit-form" "lisp-patch-form" "lisp-check-parens"
      "clgrep-search" "clhs-lookup"
      "repl-eval" "inspect-object"
      "code-find" "code-describe" "code-find-references"
      "pool-status" "pool-kill-worker" "project-scaffold")
  :test #'equal
  :documentation
  "Snapshot of the cl-mcp tools the harness was developed against.
Fallback enumeration source for ALLOWED-TOOLS when no live tool list is
supplied; ACTION-ALLOWED-P matches against rules, not this list.")

(alexandria:define-constant +condition-allow-rules+
    '((:file-only      ("fs-list-directory" "fs-read-file" "fs-write-file"
                        "load-system" "run-tests"))
      (:generic-mcp    ("fs-*" "load-system" "run-tests"
                        "lisp-*" "clgrep-*" "clhs-*"))
      (:runtime-native ("fs-*" "load-system" "run-tests"
                        "lisp-*" "clgrep-*" "clhs-*"
                        "code-*" "repl-*" "inspect-*" "pool-*")))
  :test #'equal
  :documentation
  "Built-in allow rules for the three spec conditions (PRD §8.5,
spec §5). A rule is a literal tool name (exact match) or a trailing-*
prefix glob. A policy pack's :tool-policies section can supply
alternative rules per run via MAKE-ACTION-SPACE's :RULES.")

(defun condition-rules (mode)
  "Return the built-in allow rules for MODE, or signal an ERROR."
  (or (cadr (assoc mode +condition-allow-rules+))
      (error "action-space: no allow rules registered for mode ~S" mode)))

(defun %match-rule (tool-name rule)
  "True when TOOL-NAME satisfies RULE — a literal name (exact match) or
a `prefix*' glob. Only a trailing * is supported; anything else errors."
  (let ((star (position #\* rule)))
    (cond
      ((null star) (string= tool-name rule))
      ((= star (1- (length rule)))
       (let ((prefix (subseq rule 0 star)))
         (and (>= (length tool-name) (length prefix))
              (string= tool-name prefix :end1 (length prefix)))))
      (t (error "action-space: only trailing-* globs are supported, got ~S"
                rule)))))

(defun %matches-any-rule-p (tool-name rules)
  (some (lambda (rule) (%match-rule tool-name rule)) rules))

(defclass action-space ()
  ((mode :initarg :mode :initform nil :reader action-space-mode
         :documentation "Reporting label (:file-only etc.), or NIL.")
   (rules :initarg :rules :reader action-space-rules)
   (available-tools :initarg :available-tools :initform nil
                    :reader action-space-available-tools))
  (:documentation
   "Allow-list restriction of the L1 action space (spec §5).
AVAILABLE-TOOLS, when set, is the live tools/list catalog;
ALLOWED-TOOLS filters it through RULES. ACTION-ALLOWED-P consults
RULES directly, so new cl-mcp tools matching a glob still pass."))

(defun make-action-space (mode &key rules available-tools)
  "Build an ACTION-SPACE for MODE (one of the three conditions).
Explicit RULES (e.g. a policy pack's :tool-policies entry) override the
built-in rules for MODE; MODE may be NIL when RULES are supplied."
  (when available-tools
    (assert (listp available-tools) (available-tools)
            "action-space: :available-tools must be a list of tool names"))
  (let ((effective (or rules (condition-rules mode))))
    (make-instance 'action-space :mode mode :rules effective
                                 :available-tools available-tools)))

(defun allowed-tools (space)
  "Tool names SPACE permits: the live catalog (or +KNOWN-TOOL-NAMES+)
filtered by the allow rules, in source order."
  (let ((source (or (action-space-available-tools space)
                    +known-tool-names+)))
    (remove-if-not (lambda (name)
                     (%matches-any-rule-p name (action-space-rules space)))
                   source)))

(defun action-allowed-p (space tool-name)
  "True when SPACE's rules permit TOOL-NAME."
  (check-type tool-name string)
  (and (%matches-any-rule-p tool-name (action-space-rules space)) t))
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — 55 tests (47 + 8).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/action-space.lisp next/tests/action-space-test.lisp
git add next/src/action-space.lisp next/tests/action-space-test.lisp cl-harness-next.asd
git commit -m "feat(next): action-space with condition allow rules"
```

---

### Task 4: Policy pack `:tool-policies` section

**Files:**
- Modify: `next/src/policy-pack.lisp`
- Modify: `next/tests/policy-pack-test.lisp`

- [ ] **Step 1: Write the failing tests**

Extend the test package's `:import-from #:cl-harness-next/src/policy-pack`
clause with `#:pack-tool-policy`. Append to
`next/tests/policy-pack-test.lisp`:

```lisp
(deftest tool-policies-section-loads
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\"
                          :tool-policies ((:id :runtime-native
                                           :rules (\"fs-*\" \"run-tests\"))))")
    (let ((pack (load-policy-pack path)))
      (ok (equal '("fs-*" "run-tests")
                 (getf (pack-tool-policy pack :runtime-native) :rules)))
      (ok (null (pack-tool-policy pack :no-such-policy))))))

(deftest tool-policies-entry-needs-id
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\"
                          :tool-policies ((:rules (\"fs-*\"))))")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `:tool-policies` is rejected as an unknown top-level
key (the first test signals `policy-pack-invalid` where it expects a
pack), and `pack-tool-policy` is undefined.

- [ ] **Step 3: Implement the section**

In `next/src/policy-pack.lisp`, four edits (use `lisp-patch-form` /
`lisp-edit-form`):

1. `+section-keys+` constant — add `:tool-policies`:

```lisp
(alexandria:define-constant +section-keys+
    '(:prompts :budgets :oracle-profiles :dial-rules :tool-policies)
  :test #'equal
  :documentation "Optional pack sections; each is a list of plists
carrying a keyword :id.")
```

**WARNING — constant redefinition:** `alexandria:define-constant`
signals an error when the constant is already bound to a NON-equal
value, which is exactly what happens here in a live worker that loaded
the old 4-element list. After making the edits, call cl-mcp
`pool-kill-worker` with `{"reset": true}` and re-register the system
(`(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`
via repl-eval) BEFORE running tests — the fresh worker loads the new
value with no old binding to clash with.

2. `policy-pack` class — add a slot after `dial-rules`:

```lisp
   (tool-policies :initarg :tool-policies :initform nil
                  :reader pack-tool-policies)
```

3. `load-policy-pack` — add the initarg after `:dial-rules ...`:

```lisp
                   :tool-policies (getf form :tool-policies)
```

4. Append accessor after `pack-dial-rule`, and add `#:pack-tool-policies`
and `#:pack-tool-policy` to the defpackage `:export` list:

```lisp
(defun pack-tool-policy (pack id)
  "Return the full plist of tool policy ID in PACK, or NIL."
  (%section-entry (pack-tool-policies pack) id))
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — 57 tests (55 + 2). The pre-existing fingerprint tests
must still pass (packs without the new section are unaffected).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git add next/src/policy-pack.lisp next/tests/policy-pack-test.lisp
git commit -m "feat(next): policy-pack :tool-policies section"
```

---

### Task 5: Environment (L1 protocol over cl-mcp)

**Files:**
- Create: `next/tests/environment-test.lisp`
- Create: `next/src/environment.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/environment-test.lisp`:

```lisp
;;;; next/tests/environment-test.lisp
;;;;
;;;; Tests for next/src/environment.lisp using a scripted transport
;;;; (no subprocess): policy-filtered action space, action/observation
;;;; event recording, denial signaling, error-observation recording,
;;;; close propagation (spec §5 + 原則3).

(defpackage #:cl-harness-next/tests/environment-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:transport-close
                #:make-mcp-client
                #:mcp-error)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment
                #:environment-action-space
                #:perform-action
                #:environment-close
                #:action-not-allowed))

(in-package #:cl-harness-next/tests/environment-test)

(defmacro with-log-path ((path) &body body)
  "Fresh temporary .jsonl path that does not exist yet."
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     ,@body))

(defclass scripted-transport (mcp-transport)
  ((script :initarg :script :reader scripted-script
           :documentation "Alist of (METHOD . RESULT-OR-ERROR-JSON-FRAGMENT).")
   (closed-p :initform nil :accessor scripted-closed-p))
  (:documentation "Canned-response transport: echoes the request id and
splices the scripted fragment for the request's method."))

(defmethod transport-send-request ((transport scripted-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (if (null id)
        ""
        (let ((entry (assoc method (scripted-script transport)
                            :test #'string=)))
          (unless entry
            (error "scripted-transport: no canned response for ~S" method))
          (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id (cdr entry))))))

(defmethod transport-close ((transport scripted-transport))
  (setf (scripted-closed-p transport) t))

(defparameter *base-script*
  (list (cons "initialize" "\"result\":{\"protocolVersion\":\"2025-06-18\"}")
        (cons "tools/list"
              (concatenate 'string
                           "\"result\":{\"tools\":["
                           "{\"name\":\"repl-eval\"},"
                           "{\"name\":\"fs-read-file\"},"
                           "{\"name\":\"lisp-edit-form\"},"
                           "{\"name\":\"run-tests\"}]}"))
        (cons "tools/call"
              (concatenate 'string
                           "\"result\":{\"content\":"
                           "[{\"type\":\"text\",\"text\":\"3\"}]}"))))

(defun %make-scripted-env (&key (condition :runtime-native) event-log
                                (script *base-script*))
  (make-cl-mcp-environment
   :client (make-mcp-client (make-instance 'scripted-transport
                                           :script script))
   :condition condition
   :event-log event-log))

(deftest action-space-is-policy-filtered
  (let ((env (%make-scripted-env :condition :file-only)))
    (ok (equal '("fs-read-file" "run-tests")
               (mapcar (lambda (descriptor) (gethash "name" descriptor))
                       (environment-action-space env))))))

(deftest perform-action-records-action-and-observation
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (env (%make-scripted-env :event-log log))
           (result (perform-action env "repl-eval"
                                   (alexandria:plist-hash-table
                                    (list "code" "(+ 1 2)")
                                    :test #'equal))))
      (ok (hash-table-p result))
      (let ((events (read-events path)))
        (ok (equal '(:action :observation) (mapcar #'event-type events)))
        (ok (equal "repl-eval"
                   (gethash "tool" (event-payload (first events)))))
        (ok (equal "(+ 1 2)"
                   (gethash "code"
                            (gethash "arguments"
                                     (event-payload (first events))))))
        (ok (gethash "result" (event-payload (second events))))))))

(deftest denied-action-signals-without-events
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (env (%make-scripted-env :condition :file-only :event-log log)))
      (ok (handler-case
              (progn (perform-action env "repl-eval"
                                     (make-hash-table :test #'equal))
                     nil)
            (action-not-allowed () t)))
      (ok (null (probe-file path))))))

(deftest mcp-error-is-recorded-then-resignaled
  (with-log-path (path)
    (let* ((log (open-event-log path))
           (script (list* (cons "tools/call"
                                "\"error\":{\"code\":-32000,\"message\":\"boom\"}")
                          (remove "tools/call" *base-script*
                                  :key #'car :test #'string=)))
           (env (%make-scripted-env :event-log log :script script)))
      (ok (handler-case
              (progn (perform-action env "run-tests"
                                     (make-hash-table :test #'equal))
                     nil)
            (mcp-error () t)))
      (let ((events (read-events path)))
        (ok (= 2 (length events)))
        (ok (equal "boom"
                   (gethash "error" (event-payload (second events)))))))))

(deftest environment-close-closes-transport
  (let* ((transport (make-instance 'scripted-transport
                                   :script *base-script*))
         (env (make-cl-mcp-environment
               :client (make-mcp-client transport))))
    (environment-close env)
    (ok (scripted-closed-p transport))))

(deftest action-not-allowed-prints-without-initargs
  (ok (stringp (princ-to-string (make-condition 'action-not-allowed)))))
```

Create `next/src/environment.lisp` with the package definition only:

```lisp
;;;; next/src/environment.lisp
;;;;
;;;; L1 environment (spec §5): wraps a cl-mcp client as an
;;;; observation/action space. The action space is restricted by an
;;;; ACTION-SPACE allow-list, and every action and its observation are
;;;; recorded into the attached L0 event log (原則3「すべての実行は
;;;; 実験である」).

(defpackage #:cl-harness-next/src/environment
  (:use #:cl)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-error
                #:mcp-error-message
                #:initialize-mcp
                #:list-tools
                #:call-tool
                #:close-mcp-client)
  (:import-from #:cl-harness-next/src/mcp-stdio
                #:make-stdio-mcp-client)
  (:import-from #:cl-harness-next/src/action-space
                #:make-action-space
                #:action-allowed-p
                #:action-space-mode)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:export #:action-not-allowed
           #:action-not-allowed-tool
           #:action-not-allowed-mode
           #:environment
           #:environment-action-space
           #:perform-action
           #:environment-close
           #:cl-mcp-environment
           #:make-cl-mcp-environment
           #:environment-event-log))

(in-package #:cl-harness-next/src/environment)
```

Add `"cl-harness-next/tests/environment-test"` to the tests system's
`:depends-on`.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `make-cl-mcp-environment` undefined; 57 existing pass.

- [ ] **Step 3: Implement the environment**

Append to `next/src/environment.lisp`:

```lisp
(define-condition action-not-allowed (error)
  ((tool :initarg :tool :initform nil :reader action-not-allowed-tool)
   (mode :initarg :mode :initform nil :reader action-not-allowed-mode))
  (:report (lambda (condition stream)
             (format stream "Action ~A is outside the ~A action space."
                     (action-not-allowed-tool condition)
                     (action-not-allowed-mode condition))))
  (:documentation "Signaled by PERFORM-ACTION for a policy-denied tool."))

(defclass environment ()
  ()
  (:documentation "Abstract L1 environment protocol (spec §5)."))

(defgeneric environment-action-space (env)
  (:documentation
   "Return the tool descriptors (hash-tables from tools/list) the agent
may invoke — the policy-filtered action space."))

(defgeneric perform-action (env tool-name arguments)
  (:documentation
   "Invoke TOOL-NAME with ARGUMENTS (a hash-table) in ENV and return
the tools/call result hash-table. Signals ACTION-NOT-ALLOWED when the
action space denies TOOL-NAME. Records :action and :observation events
when ENV carries an event log."))

(defgeneric environment-close (env)
  (:documentation "Release ENV's resources (subprocess, streams)."))

(defclass cl-mcp-environment (environment)
  ((client :initarg :client :reader environment-client)
   (space :initarg :space :reader environment-space)
   (tools :initarg :tools :initform nil :reader environment-tools
          :documentation "Cached tools/list descriptors (list).")
   (event-log :initarg :event-log :initform nil
              :reader environment-event-log))
  (:documentation "L1 environment over a live cl-mcp client."))

(defun %tool-descriptor-name (descriptor)
  (gethash "name" descriptor))

(defun make-cl-mcp-environment (&key client command
                                     (condition :runtime-native)
                                     rules event-log
                                     (request-timeout 60))
  "Build a CL-MCP-ENVIRONMENT.

CLIENT, when supplied, is an already-constructed MCP-CLIENT (tests
inject a scripted transport this way); otherwise a cl-mcp subprocess is
spawned over stdio with COMMAND / REQUEST-TIMEOUT. Runs the MCP
initialize handshake and tools/list, then restricts the action space to
CONDITION's built-in rules — or explicit RULES, e.g. a policy pack's
:tool-policies entry. EVENT-LOG, when supplied, receives
:action/:observation events for every PERFORM-ACTION."
  (let ((client (or client (make-stdio-mcp-client
                            :command command
                            :request-timeout request-timeout))))
    (initialize-mcp client)
    (let* ((tools (coerce (list-tools client) 'list))
           (space (make-action-space
                   condition
                   :rules rules
                   :available-tools (mapcar #'%tool-descriptor-name tools))))
      (make-instance 'cl-mcp-environment
                     :client client
                     :space space
                     :tools tools
                     :event-log event-log))))

(defmethod environment-action-space ((env cl-mcp-environment))
  (remove-if-not (lambda (descriptor)
                   (action-allowed-p (environment-space env)
                                     (%tool-descriptor-name descriptor)))
                 (environment-tools env)))

(defun %emit (env type payload)
  (let ((log (environment-event-log env)))
    (when log (emit-event log type payload))))

(defmethod perform-action ((env cl-mcp-environment) tool-name arguments)
  (check-type tool-name string)
  (check-type arguments hash-table)
  (let ((space (environment-space env)))
    (unless (action-allowed-p space tool-name)
      (error 'action-not-allowed
             :tool tool-name
             :mode (action-space-mode space))))
  (%emit env :action (alexandria:plist-hash-table
                      (list "tool" tool-name "arguments" arguments)
                      :test #'equal))
  (handler-case
      (let ((result (call-tool (environment-client env)
                               tool-name arguments)))
        (%emit env :observation (alexandria:plist-hash-table
                                 (list "tool" tool-name "result" result)
                                 :test #'equal))
        result)
    (mcp-error (e)
      (%emit env :observation (alexandria:plist-hash-table
                               (list "tool" tool-name
                                     "error" (mcp-error-message e))
                               :test #'equal))
      (error e))))

(defmethod environment-close ((env cl-mcp-environment))
  (close-mcp-client (environment-client env)))
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — 63 tests (57 + 6).

- [ ] **Step 5: Lint and commit**

```bash
mallet next/src/environment.lisp next/tests/environment-test.lisp
git add next/src/environment.lisp next/tests/environment-test.lisp cl-harness-next.asd
git commit -m "feat(next): L1 environment — policy-filtered action space over cl-mcp"
```

---

### Task 6: Facade, acceptance test, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`

- [ ] **Step 1: Write the failing acceptance test**

Append to `next/tests/main-test.lisp` (facade symbols only — this test
proves a consumer can do the whole L0+L1 roundtrip through the public
API; yason/uiop stay package-qualified, no new test-package imports):

```lisp
(defclass %facade-scripted-transport (cl-harness-next:mcp-transport)
  ()
  (:documentation "Minimal canned transport for the facade acceptance
test; lives here because the test must only use facade symbols."))

(defmethod cl-harness-next:transport-send-request
    ((transport %facade-scripted-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}"
               id
               "\"result\":{\"tools\":[{\"name\":\"run-tests\"}]}"))
      ((equal method "tools/call")
       (format nil
               "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{\"content\":[]}}"
               id))
      (t (error "unexpected method ~S" method)))))

(deftest facade-environment-records-events
  ;; SP2 acceptance: through the facade alone, wrap an MCP client as a
  ;; policy-restricted environment and observe the action/observation
  ;; events land in the L0 log (spec §5 + 原則3).
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (cl-harness-next:open-event-log log-path))
           (env (cl-harness-next:make-cl-mcp-environment
                 :client (cl-harness-next:make-mcp-client
                          (make-instance '%facade-scripted-transport))
                 :condition :file-only
                 :event-log log)))
      (cl-harness-next:perform-action env "run-tests"
                                      (make-hash-table :test #'equal))
      (cl-harness-next:environment-close env)
      (ok (equal '(:action :observation)
                 (mapcar #'cl-harness-next:event-type
                         (cl-harness-next:read-events log-path)))))))
```

- [ ] **Step 2: Run tests to verify it fails**

Expected: FAIL at load — `cl-harness-next:mcp-transport` (and the other
new symbols) are not exported from the facade yet.

- [ ] **Step 3: Extend the facade**

In `next/src/main.lisp`'s `defpackage` (via `lisp-edit-form` `replace`
on the whole defpackage, preserving all existing clauses):

Add these `:import-from` clauses after the policy-pack one:

```lisp
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:transport-close
                #:mcp-client
                #:make-mcp-client
                #:mcp-error
                #:mcp-error-code
                #:mcp-error-message
                #:mcp-error-data
                #:initialize-mcp
                #:list-tools
                #:call-tool
                #:close-mcp-client)
  (:import-from #:cl-harness-next/src/mcp-stdio
                #:make-stdio-mcp-client
                #:stdio-mcp-error
                #:stdio-mcp-error-message
                #:*default-stdio-command*)
  (:import-from #:cl-harness-next/src/action-space
                #:action-space
                #:make-action-space
                #:action-space-mode
                #:allowed-tools
                #:action-allowed-p)
  (:import-from #:cl-harness-next/src/environment
                #:action-not-allowed
                #:action-not-allowed-tool
                #:action-not-allowed-mode
                #:environment
                #:environment-action-space
                #:perform-action
                #:environment-close
                #:cl-mcp-environment
                #:make-cl-mcp-environment
                #:environment-event-log)
```

Extend the existing policy-pack `:import-from` clause with
`#:pack-tool-policies` and `#:pack-tool-policy`.

Add to the `:export` list (grouped with section comments like the
existing ones):

```lisp
           ;; mcp
           #:mcp-transport
           #:transport-send-request
           #:transport-close
           #:mcp-client
           #:make-mcp-client
           #:mcp-error
           #:mcp-error-code
           #:mcp-error-message
           #:mcp-error-data
           #:initialize-mcp
           #:list-tools
           #:call-tool
           #:close-mcp-client
           #:make-stdio-mcp-client
           #:stdio-mcp-error
           #:stdio-mcp-error-message
           #:*default-stdio-command*
           ;; action-space
           #:action-space
           #:make-action-space
           #:action-space-mode
           #:allowed-tools
           #:action-allowed-p
           ;; environment
           #:action-not-allowed
           #:action-not-allowed-tool
           #:action-not-allowed-mode
           #:environment
           #:environment-action-space
           #:perform-action
           #:environment-close
           #:cl-mcp-environment
           #:make-cl-mcp-environment
           #:environment-event-log
           ;; policy-pack (SP2 additions)
           #:pack-tool-policies
           #:pack-tool-policy
```

- [ ] **Step 4: Run tests — expect everything green**

Expected: PASS — 64 tests / 0 failures.

- [ ] **Step 5: Full force-compile**

Via repl-eval: `(asdf:compile-system :cl-harness-next :force t)`.
Expected: no warnings from `next/` sources (ASDF/UIOP infrastructure
redefinition notes are acceptable noise).

- [ ] **Step 6: Document**

In `README.md`'s `### next/ — autonomous-harness redesign (experimental)`
subsection, change the sentence beginning "SP1 ships..." to:

```markdown
SP1 ships the L0 event log (JSONL event sourcing) and policy pack
(versioned, fingerprinted prompt/config bundles); SP2 adds the L1
environment — cl-mcp wrapped as a policy-restricted observation/action
space (stdio subprocess per run) whose actions and observations are
recorded into the event log. It does not affect the `cl-harness` CLI.
```

(The original ends with the same final sentence; keep it once.)

- [ ] **Step 7: Lint everything and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + L0+L1 acceptance test for SP2"
```

---

## Verification checklist (whole sub-project)

- Clean image: `pool-kill-worker` → `(asdf:load-asd .../cl-harness-next.asd)`
  → `load-system cl-harness-next` (no warnings from next/ sources) →
  `run-tests cl-harness-next/tests` 64/0.
- Optional but recommended once: `CL_HARNESS_INTEGRATION=1` run of the
  stdio integration test against a real cl-mcp subprocess (requires
  `ros` + cl-mcp installed; run via shell:
  `CL_HARNESS_INTEGRATION=1 ros run --non-interactive -e '(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")' -e '(ql:quickload :cl-harness-next/tests :silent t)' -e '(rove:run :cl-harness-next/tests/mcp-stdio-test)'`).
- Legacy untouched: `git status --short src/ tests/` empty;
  `run-tests cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (later sub-projects — do NOT build now)

- HTTP MCP transport (re-add when remote runs matter).
- `:explore` mode rules (legacy develop-loop detail; returns with the
  control policies, SP5/SP6).
- Git worktree isolation per run (SP7 mission layer — parallel runs).
- NAME-CONFLICT auto-worker-reset self-heal (SP4 verification oracle —
  it needs verify-failure classification to trigger correctly).
- Recording denied actions as events (decide when the world model
  consumes denials, SP3).
- Tool descriptor schema exposure / observation summarization in the
  action space (SP3 context compiler decides what views need).
