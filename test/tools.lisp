;;;; Tools, MCP and JSON, without an engine.

(in-package #:circle/test)

(defvar *test-server* (make-tool-server "test"))

(define-tool (add-numbers :server *test-server*)
    ((a :number "The first number.")
     (b :number "The second number.")
     &optional
     (label :string "Said before the sum."))
  "Add two numbers."
  (format nil "~@[~A ~]~A" label (+ a b)))

(define-tool (complain :server *test-server*) ()
  "Always fails."
  (error 'tool-error :message "no, thank you"))

(defun rpc (method &optional params (server *test-server*))
  (handle-mcp-request server (json-object "jsonrpc" "2.0" "id" 7 "method" method
                                          "params" (or params :absent))))

(defun undocumented-symbols (package)
  "External symbols of PACKAGE that name a function, macro, variable or class
without documentation."
  (let ((missing '()))
    (do-external-symbols (symbol package)
      (when (or (and (fboundp symbol) (not (documentation symbol 'function)))
                (and (boundp symbol) (not (documentation symbol 'variable)))
                (and (find-class symbol nil) (not (documentation symbol 'type))))
        (push symbol missing)))
    (sort missing #'string< :key #'symbol-name)))

(defun tool-checks ()
  (check "json-object leaves out :absent values and json-get follows a path"
         (let ((object (json-object "a" (vector 1 (json-object "b" "x")) "c" :absent)))
           (and (equal "x" (json-get object "a" 1 "b"))
                (null (json-get object "a" 5))
                (null (nth-value 1 (gethash "c" object))))))
  (check "JSON reads and writes objects, arrays, true, false and null"
         (let ((value (parse-json "{\"a\":[1,true,false,null]}")))
           (and (equalp #(1 t nil null) (json-get value "a"))
                (equal "{\"a\":[1,true,false,null]}" (to-json value)))))
  (check "a tool is called with its arguments by name"
         (equal "sum 5" (call-tool "add_numbers" (json-object "a" 2 "b" 3 "label" "sum")
                                   *test-server*)))
  (check "an optional argument left out is NIL"
         (equal "5" (call-tool "add_numbers" (json-object "a" 2 "b" 3) *test-server*)))
  (check "a missing argument is a tool error naming it"
         (handler-case (progn (call-tool "add_numbers" (json-object "a" 2) *test-server*) nil)
           (tool-error (e) (says (princ-to-string e) "argument b"))))
  (check "an argument of the wrong type is a tool error"
         (handler-case (progn (call-tool "add_numbers" (json-object "a" "2" "b" 3) *test-server*)
                              nil)
           (tool-error (e) (says (princ-to-string e) "a must be number"))))
  (check "an unknown tool is a tool error"
         (handler-case (progn (call-tool "nope" nil *test-server*) nil)
           (tool-error () t)))
  (check "a tool prints with its name and parameters"
         (says (prin1-to-string (find-tool "add_numbers" *test-server*)) "add_numbers a b label"))
  (check "MCP initialize answers with the engine's protocol version and tools"
         (let ((result (json-get (rpc "initialize" (json-object "protocolVersion" "2025-11-25"))
                                 "result")))
           (and (equal "2025-11-25" (json-get result "protocolVersion"))
                (json-get result "capabilities" "tools" "listChanged")
                (equal "test" (json-get result "serverInfo" "name")))))
  (check "MCP tools/list describes each tool with a JSON schema"
         (let* ((tools (json-get (rpc "tools/list") "result" "tools"))
                (add (find "add_numbers" tools :key (lambda (tool) (json-get tool "name"))
                                               :test #'equal)))
           (and (equal "Add two numbers." (json-get add "description"))
                (equal "number" (json-get add "inputSchema" "properties" "a" "type"))
                (equalp #("a" "b") (json-get add "inputSchema" "required")))))
  (check "MCP tools/call answers a tool's text"
         (let ((result (json-get (rpc "tools/call" (json-object "name" "add_numbers"
                                                                "arguments" (json-object "a" 1 "b" 1)))
                                 "result")))
           (and (equal "2" (json-get result "content" 0 "text"))
                (null (json-get result "isError")))))
  (check "MCP tools/call of a failing tool is an error result, not a JSON-RPC error"
         (let ((result (json-get (rpc "tools/call" (json-object "name" "complain")) "result")))
           (and (json-get result "isError")
                (equal "no, thank you" (json-get result "content" 0 "text")))))
  (check "an MCP notification has no response and an unknown method is a JSON-RPC error"
         (and (null (handle-mcp-request *test-server*
                                        (json-object "jsonrpc" "2.0"
                                                     "method" "notifications/initialized")))
              (eql -32601 (json-get (rpc "resources/list") "error" "code"))))
  (check "define-tool again replaces the tool"
         (progn (define-tool (temporary :server *test-server*) () "1")
                (define-tool (temporary :server *test-server*) () "2")
                (prog1 (equal "2" (call-tool "temporary" nil *test-server*))
                  (remove-tool "temporary" *test-server*))))
  (check "remove-tool takes a tool out of the list"
         (progn (define-tool (temporary :server *test-server*) () "1")
                (remove-tool "temporary" *test-server*)
                (null (find-tool "temporary" *test-server*))))
  (check "the image's own server offers eval"
         (and (equal "lisp" (mcp-server-name *tool-server*))
              (find-tool "eval")))
  (check "eval answers printed output and the values of the last form"
         (says (eval-forms "(princ \"hi\") (values 1 \"two\")") (format nil "hi~%=> 1~%=> \"two\"")))
  (check "eval keeps definitions in the image"
         (progn (eval-forms "(defun circle-test-twice (x) (* 2 x))")
                (says (eval-forms "(circle-test-twice 21)") "=> 42")))
  (check "eval of forms with no values says so"
         (says (eval-forms "(values)") "; no values"))
  (check "eval reads in the package it is given"
         (says (eval-forms "(symbol-name 'json-object)" :package "CIRCLE") "=> \"JSON-OBJECT\""))
  (check "eval refuses #. while reading"
         (handler-case (progn (eval-forms "#.(+ 1 2)") nil)
           (tool-error (e) (says (princ-to-string e) "READER-ERROR"))))
  (check "an error in eval answers the error and a backtrace, keeping earlier output"
         (handler-case (progn (eval-forms "(princ \"before\") (car 1)") nil)
           (tool-error (e)
             (let ((text (princ-to-string e)))
               (and (says text "before") (says text "TYPE-ERROR") (says text "Backtrace"))))))
  (check "eval in a package that does not exist is a tool error"
         (handler-case (progn (eval-forms "1" :package "NO-SUCH-PACKAGE-HERE") nil)
           (tool-error () t)))
  (check "allow-own-tools allows the image's tools and denies the others with a reason"
         (let ((*engine* (make-engine)))
           (and (eq :allow (allow-own-tools "mcp__lisp__eval" (json-object)))
                (multiple-value-bind (decision reason) (allow-own-tools "Bash" (json-object))
                  (and (eq :deny decision) (says reason "permission function"))))))
  (check "the command line resumes a conversation and offers the image's server in process"
         (let ((line (engine-command-line (make-engine :resume "abc" :model "claude-opus-5-5" :effort "high"))))
           (and (equal "abc" (second (member "--resume" line :test #'equal)))
                (equal "claude-opus-5-5" (second (member "--model" line :test #'equal)))
                (equal "high" (second (member "--effort" line :test #'equal)))
                (says (second (member "--mcp-config" line :test #'equal))
                      "{\"mcpServers\":{\"lisp\":{\"type\":\"sdk\",\"name\":\"lisp\"}}}"))))
  (dolist (package '(:circle/engine :circle/tools :circle/supervisor :circle/generation :circle))
    (let ((missing (undocumented-symbols package)))
      (check (format nil "every external symbol of ~(~A~) is documented" package)
             (or (null missing)
                 (progn (format t "~&;; undocumented: ~{~S~^ ~}~%" missing) nil))))))
