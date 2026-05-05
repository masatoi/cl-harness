;;;; tests/mcp-resolve-test.lisp
;;;;
;;;; Phase C resolver tests
;;;; (docs/notes/2026-05-06-stdio-transport.md). Pure data-flow checks
;;;; against RESOLVE-MCP-SPEC: given a combination of kwargs and
;;;; environment variables, what (KIND, ARG) pair does the resolver
;;;; pick? No subprocesses spawned.
;;;;
;;;; Resolution priority:
;;;;   1. :mcp-url
;;;;   2. $CL_HARNESS_MCP_URL
;;;;   3. :mcp-command
;;;;   4. :mcp-stdio (flag)
;;;;   5. $CL_HARNESS_MCP_COMMAND
;;;;   6. built-in HTTP default (Phase D will flip this to stdio)

(defpackage #:cl-harness/tests/mcp-resolve-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/mcp-resolve
                #:resolve-mcp-spec))

(in-package #:cl-harness/tests/mcp-resolve-test)

(defmacro %with-clean-env (&body body)
  "Save and restore CL_HARNESS_MCP_URL / CL_HARNESS_MCP_COMMAND across
BODY so a stray env var on the developer's shell does not pollute the
resolver tests."
  `(let ((url-saved (uiop:getenv "CL_HARNESS_MCP_URL"))
         (cmd-saved (uiop:getenv "CL_HARNESS_MCP_COMMAND")))
     (unwind-protect
          (progn
            (setf (uiop:getenv "CL_HARNESS_MCP_URL") "")
            (setf (uiop:getenv "CL_HARNESS_MCP_COMMAND") "")
            ,@body)
       (setf (uiop:getenv "CL_HARNESS_MCP_URL") (or url-saved ""))
       (setf (uiop:getenv "CL_HARNESS_MCP_COMMAND") (or cmd-saved "")))))

(deftest resolve-mcp-spec-defaults-to-builtin-http
  (%with-clean-env
   (multiple-value-bind (kind arg) (resolve-mcp-spec)
     (ok (eq :http kind))
     (ok (search "127.0.0.1" arg)))))

(deftest resolve-mcp-spec-mcp-url-wins
  (%with-clean-env
   (multiple-value-bind (kind arg)
       (resolve-mcp-spec :mcp-url "http://example.com/mcp")
     (ok (eq :http kind))
     (ok (equal "http://example.com/mcp" arg)))))

(deftest resolve-mcp-spec-env-url-when-no-kwarg
  (%with-clean-env
   (setf (uiop:getenv "CL_HARNESS_MCP_URL") "http://from-env/mcp")
   (multiple-value-bind (kind arg) (resolve-mcp-spec)
     (ok (eq :http kind))
     (ok (equal "http://from-env/mcp" arg)))))

(deftest resolve-mcp-spec-mcp-url-beats-env
  (%with-clean-env
   (setf (uiop:getenv "CL_HARNESS_MCP_URL") "http://from-env/mcp")
   (multiple-value-bind (kind arg)
       (resolve-mcp-spec :mcp-url "http://kwarg/mcp")
     (ok (eq :http kind))
     (ok (equal "http://kwarg/mcp" arg)))))

(deftest resolve-mcp-spec-mcp-command-string-splits-on-whitespace
  (%with-clean-env
   (multiple-value-bind (kind arg)
       (resolve-mcp-spec :mcp-command "ros run -s cl-mcp")
     (ok (eq :stdio kind))
     (ok (equal '("ros" "run" "-s" "cl-mcp") arg)))))

(deftest resolve-mcp-spec-mcp-command-list-passthrough
  (%with-clean-env
   (multiple-value-bind (kind arg)
       (resolve-mcp-spec :mcp-command '("cl-mcp" "--stdio"))
     (ok (eq :stdio kind))
     (ok (equal '("cl-mcp" "--stdio") arg)))))

(deftest resolve-mcp-spec-mcp-stdio-flag-uses-default-command
  (%with-clean-env
   (multiple-value-bind (kind arg) (resolve-mcp-spec :mcp-stdio t)
     (ok (eq :stdio kind))
     (ok (null arg) "ARG is NIL — caller falls through to *DEFAULT-STDIO-COMMAND*"))))

(deftest resolve-mcp-spec-env-command-when-no-kwarg
  (%with-clean-env
   (setf (uiop:getenv "CL_HARNESS_MCP_COMMAND") "cl-mcp --stdio")
   (multiple-value-bind (kind arg) (resolve-mcp-spec)
     (ok (eq :stdio kind))
     (ok (equal '("cl-mcp" "--stdio") arg)))))

(deftest resolve-mcp-spec-mcp-url-beats-mcp-command
  (%with-clean-env
   (multiple-value-bind (kind arg)
       (resolve-mcp-spec :mcp-url "http://kwarg/mcp"
                         :mcp-command "ros run -s cl-mcp")
     (ok (eq :http kind))
     (ok (equal "http://kwarg/mcp" arg)))))

(deftest resolve-mcp-spec-mcp-command-beats-mcp-stdio-flag
  (%with-clean-env
   (multiple-value-bind (kind arg)
       (resolve-mcp-spec :mcp-stdio t
                         :mcp-command "explicit-cmd --foo")
     (ok (eq :stdio kind))
     (ok (equal '("explicit-cmd" "--foo") arg)))))

(deftest resolve-mcp-spec-mcp-stdio-flag-beats-env-command
  (%with-clean-env
   (setf (uiop:getenv "CL_HARNESS_MCP_COMMAND") "from-env --stdio")
   (multiple-value-bind (kind arg) (resolve-mcp-spec :mcp-stdio t)
     (ok (eq :stdio kind))
     (ok (null arg) "explicit --mcp-stdio flag overrides env"))))
