;;;; next/src/policy-pack.lisp
;;;;
;;;; Policy pack: the versioned artifact bundle of the redesign
;;;; (spec §10.1). Prompts, budgets, oracle profiles, and dial rules
;;;; live here as *data*, never code: packs are read with a hardened
;;;; reader (*READ-EVAL* nil, unqualified symbols read as keywords) and
;;;; identified by a SHA-256 fingerprint of their canonical form, so
;;;; every run can record exactly which pack produced its metrics.

(defpackage #:cl-harness-next/src/policy-pack
  (:use #:cl)
  (:export #:parse-semver
           #:semver<
           #:policy-pack
           #:load-policy-pack
           #:policy-pack-invalid
           #:policy-pack-invalid-message
           #:policy-pack-invalid-path
           #:pack-name
           #:pack-version
           #:pack-source-path
           #:pack-fingerprint
           #:pack-prompts
           #:pack-budgets
           #:pack-oracle-profiles
           #:pack-dial-rules
           #:pack-prompt
           #:pack-budget
           #:pack-oracle-profile
           #:pack-dial-rule
           #:pack-tool-policies
           #:pack-tool-policy))

(in-package #:cl-harness-next/src/policy-pack)

(defun parse-semver (string)
  "Parse a strict \"MAJOR.MINOR.PATCH\" STRING into a list of three
non-negative integers. Each part must be plain decimal digits — no
signs, whitespace, or leading-zero-with-more-digits quirks beyond
what digits allow. Signals an ERROR on anything else."
  (let ((parts (uiop:split-string string :separator ".")))
    (unless (= 3 (length parts))
      (error "Not a MAJOR.MINOR.PATCH semver string: ~S" string))
    (mapcar (lambda (part)
              (unless (and (plusp (length part))
                           (every #'digit-char-p part))
                (error "Not a MAJOR.MINOR.PATCH semver string: ~S" string))
              (parse-integer part))
            parts)))

(defun semver< (a b)
  "True when semver string A denotes a strictly older version than B."
  (loop for x in (parse-semver a)
        for y in (parse-semver b)
        when (< x y) return t
        when (> x y) return nil
        finally (return nil)))

(alexandria:define-constant +section-keys+
    '(:prompts :budgets :oracle-profiles :dial-rules :tool-policies)
  :test #'equal
  :documentation "Optional pack sections; each is a list of plists
carrying a keyword :id.")

(define-condition policy-pack-invalid (error)
  ((message :initarg :message :initform "(no message)"
            :reader policy-pack-invalid-message)
   (path :initarg :path :initform nil :reader policy-pack-invalid-path))
  (:report (lambda (condition stream)
             (format stream "Invalid policy pack~@[ at ~A~]: ~A"
                     (policy-pack-invalid-path condition)
                     (policy-pack-invalid-message condition))))
  (:documentation "Signaled by LOAD-POLICY-PACK on unreadable or
schema-violating pack files."))

(defclass policy-pack ()
  ((name :initarg :name :reader pack-name)
   (version :initarg :version :reader pack-version
            :documentation "Semver string.")
   (prompts :initarg :prompts :initform nil :reader pack-prompts)
   (budgets :initarg :budgets :initform nil :reader pack-budgets)
   (oracle-profiles :initarg :oracle-profiles :initform nil
                    :reader pack-oracle-profiles)
   (dial-rules :initarg :dial-rules :initform nil :reader pack-dial-rules)
   (tool-policies :initarg :tool-policies :initform nil
                  :reader pack-tool-policies)
   (source-path :initarg :source-path :initform nil
                :reader pack-source-path)
   (fingerprint :initarg :fingerprint :reader pack-fingerprint
                :documentation "SHA-256 hex of the canonical form."))
  (:documentation "An immutable, validated policy pack (spec §10.1)."))

(defun %read-pack-form (path)
  "Read exactly one top-level form from PATH with a hardened reader:
*READ-EVAL* is NIL (so #. signals at read time) and *PACKAGE* is the
KEYWORD package, so every unqualified symbol in the file reads as a
keyword. Package-qualified symbols can still intern into their named package; schema
validation constrains where non-keywords can appear. Wraps any reader
failure in POLICY-PACK-INVALID."
  (handler-case
      (with-standard-io-syntax
        (let ((*read-eval* nil)
              (*package* (find-package :keyword)))
          (with-open-file (in path :direction :input
                                   :external-format :utf-8)
            (let ((form (read in)))
              (when (read in nil nil)
                (error "pack file must contain exactly one top-level form"))
              form))))
    (error (e)
      (error 'policy-pack-invalid :path path
             :message (format nil "unreadable pack file: ~A" e)))))

(defun %validate-pack-form (form path)
  "Check FORM against the SP1 pack schema and return it. Required:
:name (string), :version (semver string). Optional: +SECTION-KEYS+,
each a list of plists with a keyword :id. Unknown top-level keys are
rejected to catch typos early."
  (flet ((invalid (control &rest arguments)
           (error 'policy-pack-invalid :path path
                  :message (apply #'format nil control arguments))))
    (unless (and (listp form) (evenp (length form)))
      (invalid "top-level form must be a plist"))
    (loop for (key nil) on form by #'cddr
          unless (member key (list* :name :version +section-keys+))
            do (invalid "unknown top-level key ~S" key))
    (let ((name (getf form :name))
          (version (getf form :version)))
      (unless (stringp name)
        (invalid ":name must be a string"))
      (unless (stringp version)
        (invalid ":version must be a string"))
      (handler-case (parse-semver version)
        (error () (invalid ":version ~S is not MAJOR.MINOR.PATCH" version))))
    (dolist (section +section-keys+)
      (dolist (entry (getf form section))
        (unless (and (listp entry) (keywordp (getf entry :id)))
          (invalid "every ~S entry needs a keyword :id, got ~S"
                   section entry))))
    form))

(defun %fingerprint (form)
  "SHA-256 hex digest of FORM's canonical printed representation.
Canonical means WITH-STANDARD-IO-SYNTAX, no pretty printing — the
same parsed content always prints, and therefore hashes, identically.
SBCL-only via SB-EXT:STRING-TO-OCTETS (project targets SBCL, PRD §9.4)."
  (let ((canonical (with-standard-io-syntax
                     (let ((*print-pretty* nil))
                       (prin1-to-string form)))))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence
      :sha256
      (sb-ext:string-to-octets canonical :external-format :utf-8)))))

(defun load-policy-pack (path)
  "Load, validate, and fingerprint the policy pack at PATH. Returns a
POLICY-PACK. Signals POLICY-PACK-INVALID on read or schema failure."
  (let ((form (%validate-pack-form (%read-pack-form path) path)))
    (make-instance 'policy-pack
                   :name (getf form :name)
                   :version (getf form :version)
                   :prompts (getf form :prompts)
                   :budgets (getf form :budgets)
                   :oracle-profiles (getf form :oracle-profiles)
                   :dial-rules (getf form :dial-rules)
                   :tool-policies (getf form :tool-policies)
                   :source-path (pathname path)
                   :fingerprint (%fingerprint form))))

(defun %section-entry (entries id)
  (find id entries :key (lambda (entry) (getf entry :id))))

(defun pack-prompt (pack id)
  "Return the :text of prompt ID in PACK, or NIL when absent."
  (getf (%section-entry (pack-prompts pack) id) :text))

(defun pack-budget (pack id)
  "Return the :value of budget ID in PACK, or NIL when absent."
  (getf (%section-entry (pack-budgets pack) id) :value))

(defun pack-oracle-profile (pack id)
  "Return the full plist of oracle profile ID in PACK, or NIL."
  (%section-entry (pack-oracle-profiles pack) id))

(defun pack-dial-rule (pack id)
  "Return the full plist of dial rule ID in PACK, or NIL."
  (%section-entry (pack-dial-rules pack) id))

(defun pack-tool-policy (pack id)
  "Return the full plist of tool policy ID in PACK, or NIL."
  (%section-entry (pack-tool-policies pack) id))
