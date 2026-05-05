;;;; src/mcp-resolve.lisp
;;;;
;;;; Phase C of the stdio-transport migration
;;;; (docs/notes/2026-05-06-stdio-transport.md). Pure resolver: given
;;;; user-supplied kwargs and the CL_HARNESS_MCP_* environment, decide
;;;; whether the next MCP client should talk HTTP or stdio, and with
;;;; what argument. The actual MCP-CLIENT construction (and the
;;;; subprocess spawn for stdio) is a separate concern, delegated to
;;;; BUILD-MCP-CLIENT-FROM-SPEC so the decision logic can be unit-tested
;;;; without touching the network or fork(2).

(defpackage #:cl-harness/src/mcp-resolve
  (:use #:cl)
  (:import-from #:cl-harness/src/mcp
                #:make-mcp-client
                #:initialize-mcp)
  (:import-from #:cl-harness/src/mcp-stdio
                #:make-stdio-mcp-transport)
  (:export #:resolve-mcp-spec
           #:build-mcp-client-from-spec
           #:resolve-and-build-mcp-client
           #:+default-http-url+))

(in-package #:cl-harness/src/mcp-resolve)

(defparameter +default-http-url+ "http://127.0.0.1:3001/mcp"
  "Built-in cl-mcp HTTP endpoint used when nothing else is configured.
Phase D will replace this fallback with a default stdio command so
callers no longer share a server with whatever cl-mcp instance happens
to be running on the host.")

(defun %nonempty-env (name)
  "Return the value of NAME from the process environment, or NIL when
the variable is unset or empty. Treats \"\" the same as unset because
unsetting an env var portably (across shells, ASDF make, etc.) is
fiddly and developers commonly clear via `export VAR='."
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun %split-command (command)
  "Coerce COMMAND into a list of argv strings.

COMMAND may already be a list (passed through verbatim) or a string
(split on whitespace). The shell CLI feeds a single string here and the
naive split is good enough for the obvious case
\"ros run -s cl-mcp -e ...\". Callers that need shell quoting should
build the list in Lisp and pass it directly via the programmatic API."
  (cond
    ((listp command) command)
    ((stringp command)
     (remove-if (lambda (s) (zerop (length s)))
                (uiop:split-string command
                                   :separator '(#\Space #\Tab #\Newline))))
    (t (error "mcp-resolve: :mcp-command must be a string or a list of strings, got ~A"
              command))))

(defun resolve-mcp-spec (&key mcp-url mcp-stdio mcp-command)
  "Decide which MCP transport configuration to use based on the inputs.

Returns (values KIND ARG) where:
  KIND is :HTTP or :STDIO.
  ARG is the URL string for :HTTP, or the argv list for :STDIO (or NIL
  meaning \"use the stdio default command\").

Priority (highest first):
  1. :mcp-url
  2. $CL_HARNESS_MCP_URL
  3. :mcp-command
  4. :mcp-stdio (flag)
  5. $CL_HARNESS_MCP_COMMAND
  6. built-in HTTP default (+DEFAULT-HTTP-URL+)"
  (let ((url-env (%nonempty-env "CL_HARNESS_MCP_URL"))
        (cmd-env (%nonempty-env "CL_HARNESS_MCP_COMMAND")))
    (cond
      (mcp-url     (values :http mcp-url))
      (url-env     (values :http url-env))
      (mcp-command (values :stdio (%split-command mcp-command)))
      (mcp-stdio   (values :stdio nil))
      (cmd-env     (values :stdio (%split-command cmd-env)))
      (t           (values :http +default-http-url+)))))

(defun build-mcp-client-from-spec (kind arg)
  "Construct an MCP-CLIENT for the (KIND, ARG) pair returned by
RESOLVE-MCP-SPEC. NOT yet INITIALIZE-MCP'd — that is the caller's job
so it can pass its own client-name/version."
  (ecase kind
    (:http (make-mcp-client arg))
    (:stdio
     (cl-harness/src/mcp:make-mcp-client
      nil
      :transport (make-stdio-mcp-transport :command arg)))))

(defun resolve-and-build-mcp-client (&key mcp-url mcp-stdio mcp-command
                                          (client-name "cl-harness")
                                          (client-version "0.0.1"))
  "One-shot helper: resolve the transport spec, build the client, run
the initialize handshake, and return the live client. Callers that
need to inspect the resolved spec separately can call
RESOLVE-MCP-SPEC + BUILD-MCP-CLIENT-FROM-SPEC + INITIALIZE-MCP
themselves."
  (multiple-value-bind (kind arg)
      (resolve-mcp-spec :mcp-url mcp-url
                        :mcp-stdio mcp-stdio
                        :mcp-command mcp-command)
    (let ((client (build-mcp-client-from-spec kind arg)))
      (initialize-mcp client
                      :client-name client-name
                      :client-version client-version)
      client)))
