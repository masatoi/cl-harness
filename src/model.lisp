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
  (:export #:model-provider
           #:openai-compatible-provider
           #:make-openai-provider
           #:provider-base-url
           #:provider-api-key
           #:provider-model
           #:provider-default-temperature
           #:provider-default-max-tokens
           #:provider-transport
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
           #:complete-chat))

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
   (transport :initarg :transport :reader provider-transport))
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

(defun default-llm-transport (url headers body)
  "POST BODY to URL with HEADERS hash-table using dexador.

Returns (values RESPONSE-BODY STATUS RESPONSE-HEADERS). HTTP-level errors
surface as their captured body so the caller can extract a model-error
via CHAT-PARSE-RESPONSE.

Connection reuse is disabled so repeated calls against an LLM endpoint
that closes idle sockets do not surface stale streams."
  (let ((header-list (let ((acc '()))
                       (maphash (lambda (k v) (push (cons k v) acc)) headers)
                       (nreverse acc))))
    (handler-case
        (multiple-value-bind (resp-body status resp-headers)
            (dexador:post url :headers header-list :content body
                              :keep-alive nil)
          (values resp-body status resp-headers))
      (http-request-failed (c)
        (values (response-body c)
                (response-status c)
                (make-hash-table :test 'equal))))))

(defun make-openai-provider (&key base-url api-key model
                                  temperature max-tokens transport)
  "Construct an OPENAI-COMPATIBLE-PROVIDER (PRD §10.2)."
  (check-type base-url string)
  (check-type api-key string)
  (check-type model string)
  (make-instance 'openai-compatible-provider
                 :base-url base-url
                 :api-key api-key
                 :model model
                 :default-temperature temperature
                 :default-max-tokens max-tokens
                 :transport (or transport #'default-llm-transport)))

(defun make-chat-message (role content)
  "Construct an OpenAI-style chat message hash-table."
  (check-type role string)
  (check-type content string)
  (alist-hash-table `(("role" . ,role) ("content" . ,content))
                    :test 'equal))

(defun chat-build-request-body (model messages &key temperature max-tokens)
  "Build the JSON body for POST /v1/chat/completions.

MESSAGES is a sequence of hash-tables (see MAKE-CHAT-MESSAGE). TEMPERATURE
and MAX-TOKENS are omitted from the body when NIL so server defaults apply."
  (check-type model string)
  (let ((tbl (alist-hash-table `(("model" . ,model)
                                 ("messages" . ,(coerce messages 'list)))
                               :test 'equal)))
    (when temperature
      (setf (gethash "temperature" tbl) temperature))
    (when max-tokens
      (setf (gethash "max_tokens" tbl) max-tokens))
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
                               (max-tokens nil max-tokens-supplied-p))
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
                               (provider-default-max-tokens provider)))))
    (multiple-value-bind (resp-body status resp-headers)
        (funcall (provider-transport provider) url headers body)
      (declare (ignore status resp-headers))
      (chat-parse-response resp-body))))
