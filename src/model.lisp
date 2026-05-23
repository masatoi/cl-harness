;;;; src/model.lisp
;;;;
;;;; PRD §8.2, §10.2, §10.3 — OpenAI-compatible chat completion client.
;;;; MVP scope: blocking POST /v1/chat/completions, no streaming, capture
;;;; token usage. The TRANSPORT slot is a function so tests can inject a
;;;; recording stub without hitting the network.

(defpackage #:cl-harness/src/model
  (:use #:cl)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:dexador
                #:http-request-failed
                #:response-status
                #:response-body)
  (:import-from #:usocket
                #:timeout-error
                #:connection-refused-error
                #:socket-error)
  (:export #:model-provider
           #:openai-compatible-provider
           #:make-openai-provider
           #:provider-base-url
           #:provider-api-key
           #:provider-model
           #:provider-default-temperature
           #:provider-default-max-tokens
           #:provider-default-reasoning-effort
           #:provider-default-extra-body
           #:provider-transport
           #:provider-retry-p
           #:make-chat-message
           #:chat-response
           #:chat-response-content
           #:chat-response-role
           #:chat-response-finish-reason
           #:chat-response-prompt-tokens
           #:chat-response-completion-tokens
           #:chat-response-total-tokens
           #:chat-response-raw
           #:model-error
           #:model-error-message
           #:model-error-type
           #:chat-build-request-body
           #:chat-parse-response
           #:complete-chat
           #:%classify-llm-failure))

(in-package #:cl-harness/src/model)

;; ----- Stubs (replaced piecewise by lisp-edit-form) ---------------------

(define-condition model-error (error)
  ((message :initarg :message :reader model-error-message)
   (kind :initarg :kind :initform nil :reader model-error-type)
   (raw :initarg :raw :initform nil :reader model-error-raw))
  (:documentation "OpenAI-style error envelope returned by a chat provider.")
  (:report (lambda (c stream)
             (format stream "model-error~@[ (~A)~]: ~A"
                     (model-error-type c) (model-error-message c)))))

(defclass model-provider ()
  ()
  (:documentation "Abstract base for chat-completion providers (PRD §10.2)."))

(defclass openai-compatible-provider (model-provider)
  ((base-url :initarg :base-url :reader provider-base-url)
   (api-key :initarg :api-key :reader provider-api-key)
   (model :initarg :model :reader provider-model)
   (default-temperature :initarg :default-temperature :initform nil
                        :reader provider-default-temperature)
   (default-max-tokens :initarg :default-max-tokens :initform nil
                       :reader provider-default-max-tokens)
   (default-reasoning-effort
     :initarg :default-reasoning-effort :initform nil
     :reader provider-default-reasoning-effort
     :documentation "Default reasoning_effort for reasoning models
(typically \"low\"/\"medium\"/\"high\"). Sent only when non-NIL.")
   (default-extra-body
     :initarg :default-extra-body :initform nil
     :reader provider-default-extra-body
     :documentation "Default top-level extra fields merged into every
request body (hash-table or alist of (string . value)). Useful for
endpoint-specific quirks like \"tool_choice\":\"none\" on Groq gpt-oss.")
   (transport :initarg :transport :reader provider-transport)
   (retry-p :initarg :retry-p :initform t :reader provider-retry-p
            :documentation "When non-NIL (default), COMPLETE-CHAT
retries once on transient MODEL-ERRORs (those whose :KIND is in
+RETRIABLE-REASONS+). NIL disables retry entirely — used by
chaos-probe runs and tests that intentionally trigger failures
to keep the run time bounded."))
  (:documentation
   "Blocking OpenAI-compatible chat client (PRD §8.2 REQ-LLM-001).
TRANSPORT is a function of (URL HEADERS BODY) returning
(values RESPONSE-BODY STATUS RESPONSE-HEADERS); tests inject a stub."))

(defclass chat-response ()
  ((content :initarg :content :reader chat-response-content)
   (role :initarg :role :reader chat-response-role)
   (finish-reason :initarg :finish-reason :reader chat-response-finish-reason)
   (prompt-tokens :initarg :prompt-tokens :initform nil
                  :reader chat-response-prompt-tokens)
   (completion-tokens :initarg :completion-tokens :initform nil
                      :reader chat-response-completion-tokens)
   (total-tokens :initarg :total-tokens :initform nil
                 :reader chat-response-total-tokens)
   (raw :initarg :raw :reader chat-response-raw))
  (:documentation "Parsed chat completion result with token usage."))

(defparameter +default-llm-read-timeout-seconds+ 180
  "Read timeout (seconds) for the dexador POST that DEFAULT-LLM-TRANSPORT
issues against the LLM endpoint. Dexador's own default is 10 seconds,
which is fine for sub-second chat models (Groq llama-3.3) but breaks
hard against reasoning models (Qwen3 series, gpt-oss, OpenAI o1) where
the first response can take a minute or more. 180 (3 min) is generous
for warm reasoning model responses (typically <60s) while letting
fail-fast logic detect pathological hangs (backlog #32, observed
2026-05-24 in 103-fizz-buzz bench where requests sat for 10+ min).
Override per-provider via MAKE-OPENAI-PROVIDER's :READ-TIMEOUT kwarg.")

(defun default-llm-transport (url headers body
                              &key (read-timeout +default-llm-read-timeout-seconds+))
  "POST BODY to URL with HEADERS hash-table using dexador.

Returns (values RESPONSE-BODY STATUS RESPONSE-HEADERS). HTTP-level errors
surface as their captured body so the caller can extract a model-error
via CHAT-PARSE-RESPONSE.

Connection reuse is disabled so repeated calls against an LLM endpoint
that closes idle sockets do not surface stale streams.

READ-TIMEOUT controls how long to wait for the response body before
raising USOCKET:TIMEOUT-ERROR. Defaults to
+DEFAULT-LLM-READ-TIMEOUT-SECONDS+ (180s as of 2026-05-24, backlog #32);
override per call when a slower reasoning model is in use. The
COMPLETE-CHAT layer maps the timeout into :TRANSPORT-TIMEOUT
model-error :KIND which the retry layer can recover from."
  (let ((header-list (let ((acc '()))
                       (maphash (lambda (k v) (push (cons k v) acc)) headers)
                       (nreverse acc))))
    (handler-case
        (multiple-value-bind (resp-body status resp-headers)
            (dexador:post url :headers header-list :content body
                              :keep-alive nil
                              :read-timeout read-timeout)
          (values resp-body status resp-headers))
      (http-request-failed (c)
        (values (response-body c)
                (response-status c)
                (make-hash-table :test 'equal))))))

(defparameter +classifiable-status-codes+
  '((401 . :auth-failed)
    (429 . :rate-limited))
  "Direct mapping from a few HTTP status codes to specific reason
keywords. Other statuses fall through to range checks
(:http-server-error / :http-client-error) in %CLASSIFY-LLM-FAILURE.")

(defparameter +retriable-reasons+
  '(:http-server-error :rate-limited :transport-timeout)
  "MODEL-ERROR :KIND values that COMPLETE-CHAT retries once when the
provider's RETRY-P slot is true. The other reasons are deliberately
NOT retried: :AUTH-FAILED and :HTTP-CLIENT-ERROR are caller-side
issues; :MALFORMED-RESPONSE and :TRANSPORT-UNAVAILABLE are
borderline-transient and excluded until production data shows
otherwise; :EMPTY-CONTENT is already mapped to :GIVE-UP upstream
and never surfaces from COMPLETE-CHAT directly.")

(defun %classify-llm-failure (status body)
  "Map (HTTP STATUS, response BODY) into a reason keyword for
MODEL-ERROR. Returns one of:

  :auth-failed         -- HTTP 401
  :rate-limited        -- HTTP 429
  :http-server-error   -- HTTP 500-599
  :http-client-error   -- other HTTP 4xx
  :malformed-response  -- body is not JSON, or shape is wrong
  NIL                  -- response is shaped like a successful chat
                          completion (caller proceeds to parse)

BODY is the raw response string. STATUS may be NIL when the
underlying transport raised before producing a status."
  (cond
    ((and (integerp status)
          (cdr (assoc status +classifiable-status-codes+))))
    ((and (integerp status) (<= 500 status 599))
     :http-server-error)
    ((and (integerp status) (<= 400 status 499))
     :http-client-error)
    ((not (stringp body))
     :malformed-response)
    (t
     (handler-case
         (let ((parsed (yason:parse body)))
           (cond
             ((not (hash-table-p parsed)) :malformed-response)
             ;; OpenAI envelope: defer to chat-parse-response so the
             ;; envelope's "type" field surfaces as model-error :kind.
             ((gethash "error" parsed) nil)
             ((let ((choices (gethash "choices" parsed)))
                (or (null choices)
                    (and (vectorp choices) (zerop (length choices)))))
              :malformed-response)
             (t nil)))
       (error () :malformed-response)))))

(defun make-openai-provider (&key base-url api-key model
                                  temperature (max-tokens 8192)
                                  reasoning-effort extra-body
                                  transport (retry-p t)
                                  read-timeout)
  "Construct an OPENAI-COMPATIBLE-PROVIDER (PRD §10.2).

REASONING-EFFORT and EXTRA-BODY become per-provider defaults that any
COMPLETE-CHAT call inherits unless the call-site overrides them.

MAX-TOKENS defaults to 8192, capping pathological generation while
leaving 2x headroom over typical chat-completion responses (backlog
#33, motivated by 2026-05-24 bench data showing legitimate responses
of up to ~4k tokens with hung requests apparently generating
unbounded prose). Pass NIL to defer to the server's own default.

READ-TIMEOUT (backlog #32), when supplied, makes the provider's
default transport pass that timeout to dexador. Defaults to
+DEFAULT-LLM-READ-TIMEOUT-SECONDS+ (180s). Ignored when TRANSPORT
is explicitly supplied — caller-owned transports are passed through
unchanged so tests can keep injecting recording stubs."
  (check-type base-url string)
  (check-type api-key string)
  (check-type model string)
  (let ((effective-transport
         (cond
           (transport transport)
           (read-timeout
            (lambda (url headers body)
              (default-llm-transport url headers body
                :read-timeout read-timeout)))
           (t #'default-llm-transport))))
    (make-instance 'openai-compatible-provider
                   :base-url base-url
                   :api-key api-key
                   :model model
                   :default-temperature temperature
                   :default-max-tokens max-tokens
                   :default-reasoning-effort reasoning-effort
                   :default-extra-body extra-body
                   :transport effective-transport
                   :retry-p retry-p)))

(defun make-chat-message (role content)
  "Construct an OpenAI-style chat message hash-table."
  (check-type role string)
  (check-type content string)
  (alist-hash-table `(("role" . ,role) ("content" . ,content))
                    :test 'equal))

(defun chat-build-request-body (model messages
                                &key temperature max-tokens
                                     reasoning-effort extra-body)
  "Build the JSON body for POST /v1/chat/completions.

MESSAGES is a sequence of hash-tables (see MAKE-CHAT-MESSAGE). TEMPERATURE
and MAX-TOKENS are omitted from the body when NIL so server defaults apply.

REASONING-EFFORT, when non-NIL, is sent as the OpenAI o1-style /
gpt-oss-style \"reasoning_effort\" field (typically \"low\"/\"medium\"/
\"high\"); needed for reasoning models that route hidden tokens through
that knob.

EXTRA-BODY merges arbitrary top-level keys into the request body, useful
for endpoint-specific quirks (e.g. Groq's gpt-oss-20b sometimes needs
explicit \"tool_choice\":\"none\" or empty \"tools\":[] to suppress its
native tool-call output). EXTRA-BODY accepts a hash-table (string keys)
or an alist of (string . value); its keys override any field set above
so callers can intentionally replace, not just augment, defaults."
  (check-type model string)
  (let ((tbl (alist-hash-table `(("model" . ,model)
                                 ("messages" . ,(coerce messages 'list)))
                               :test 'equal)))
    (when temperature
      (setf (gethash "temperature" tbl) temperature))
    (when max-tokens
      (setf (gethash "max_tokens" tbl) max-tokens))
    (when reasoning-effort
      (setf (gethash "reasoning_effort" tbl) reasoning-effort))
    (when extra-body
      (cond
        ((hash-table-p extra-body)
         (maphash (lambda (k v) (setf (gethash k tbl) v)) extra-body))
        ((listp extra-body)
         (dolist (cell extra-body)
           (setf (gethash (car cell) tbl) (cdr cell))))))
    (with-output-to-string (s) (yason:encode tbl s))))

(defun %first-choice-message (parsed)
  (let ((choices (gethash "choices" parsed)))
    (when (and choices (plusp (length choices)))
      (let ((choice (elt choices 0)))
        (values (gethash "message" choice)
                (gethash "finish_reason" choice))))))

(defun chat-parse-response (json-string)
  "Parse a JSON chat-completions response into a CHAT-RESPONSE.

Signals MODEL-ERROR on an OpenAI error envelope ({\"error\": {...}})."
  (check-type json-string string)
  (let ((parsed (yason:parse json-string)))
    (let ((err (gethash "error" parsed)))
      (when err
        (error 'model-error
               :message (or (gethash "message" err) "model error")
               :kind (gethash "type" err)
               :raw parsed)))
    (multiple-value-bind (msg finish)
        (%first-choice-message parsed)
      (let ((usage (gethash "usage" parsed)))
        (make-instance 'chat-response
                       :content (and msg (gethash "content" msg))
                       :role (and msg (gethash "role" msg))
                       :finish-reason finish
                       :prompt-tokens (and usage (gethash "prompt_tokens" usage))
                       :completion-tokens (and usage (gethash "completion_tokens" usage))
                       :total-tokens (and usage (gethash "total_tokens" usage))
                       :raw parsed)))))

(defun %join-url (base path)
  (let ((trim (string-right-trim "/" base))
        (suf (if (and (plusp (length path)) (char= (char path 0) #\/))
                 path
                 (concatenate 'string "/" path))))
    (concatenate 'string trim suf)))

(defgeneric complete-chat (provider messages &key temperature max-tokens)
  (:documentation "Send a chat completion request and return a CHAT-RESPONSE
(PRD §10.3). Provider defaults supply TEMPERATURE/MAX-TOKENS when the
call-site passes NIL."))

(defmethod complete-chat ((provider openai-compatible-provider) messages
                          &key (temperature nil temperature-supplied-p)
                               (max-tokens nil max-tokens-supplied-p)
                               (reasoning-effort nil reasoning-effort-supplied-p)
                               (extra-body nil extra-body-supplied-p))
  (let ((url (%join-url (provider-base-url provider) "/chat/completions"))
        (headers (alist-hash-table
                  `(("Content-Type" . "application/json")
                    ("Authorization"
                     . ,(concatenate 'string "Bearer "
                                     (provider-api-key provider))))
                  :test 'equal))
        (body (chat-build-request-body
               (provider-model provider) messages
               :temperature (if temperature-supplied-p
                                temperature
                                (provider-default-temperature provider))
               :max-tokens (if max-tokens-supplied-p
                               max-tokens
                               (provider-default-max-tokens provider))
               :reasoning-effort (if reasoning-effort-supplied-p
                                     reasoning-effort
                                     (provider-default-reasoning-effort provider))
               :extra-body (if extra-body-supplied-p
                               extra-body
                               (provider-default-extra-body provider)))))
    (let ((attempt 0)
          (max-attempts 2))
      (loop
        (handler-case
            (return
              (multiple-value-bind (resp-body status resp-headers)
                  (handler-case
                      (funcall (provider-transport provider) url headers body)
                    (timeout-error ()
                      (error 'model-error
                             :kind :transport-timeout
                             :message "LLM transport timed out reading the response"))
                    (connection-refused-error ()
                      (error 'model-error
                             :kind :transport-unavailable
                             :message "LLM endpoint refused connection"))
                    (socket-error ()
                      (error 'model-error
                             :kind :transport-unavailable
                             :message "LLM endpoint unreachable (socket-level error)")))
                (declare (ignore resp-headers))
                (let ((reason (%classify-llm-failure status resp-body)))
                  (when reason
                    (error 'model-error
                           :kind reason
                           :message (format nil
                                            "LLM transport failure: ~A (status=~A)"
                                            reason status)
                           :raw resp-body)))
                (chat-parse-response resp-body)))
          (model-error (c)
            (cond
              ((and (provider-retry-p provider)
                    (< attempt (1- max-attempts))
                    (member (model-error-type c) +retriable-reasons+))
               (incf attempt))
              (t (error c)))))))))
