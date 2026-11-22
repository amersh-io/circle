;;;; Tool servers: tools as Lisp functions, offered to the engine over MCP.
;;;;
;;;; The engine reaches a server through MCP's JSON-RPC: initialize,
;;;; tools/list and tools/call. A tool added or removed while engines run is
;;;; announced to them, and they list the tools again before the next turn.

(in-package #:circle/tools)

(defvar *mcp-protocol-version* "2025-06-18"
  "The MCP protocol version a tool server answers with when the engine does
not name one.")

(define-condition tool-error (error)
  ((message :initarg :message :reader tool-error-message))
  (:report (lambda (condition stream) (write-string (tool-error-message condition) stream)))
  (:documentation "Signal it in a tool to fail the call with its message,
which the model reads."))

(defclass tool ()
  ((name :initarg :name :reader tool-name)
   (description :initarg :description :initform "" :reader tool-description)
   (parameters :initarg :parameters :initform '() :reader tool-parameters
               :documentation "A list of (NAME TYPE DESCRIPTION REQUIRED-P).")
   (function :initarg :function :reader tool-function))
  (:documentation "A tool: a function the model may call with arguments by
name."))

(setf (documentation 'tool-name 'function) "The name a TOOL is listed under."
      (documentation 'tool-description 'function) "What a TOOL does, as the model reads it."
      (documentation 'tool-parameters 'function)
      "A TOOL's parameters, each a list (NAME TYPE DESCRIPTION REQUIRED-P): the
JSON name, a type keyword (:STRING :INTEGER :NUMBER :BOOLEAN :OBJECT :ARRAY),
the text the model reads, and whether it must be given."
      (documentation 'tool-function 'function)
      "The function a TOOL calls, with one argument per parameter in order,
NIL for one not given.")

(defmethod print-object ((tool tool) stream)
  (print-unreadable-object (tool stream :type t)
    (format stream "~A~{ ~A~}" (tool-name tool) (mapcar #'first (tool-parameters tool)))))

(defclass tool-server ()
  ((name :initarg :name :reader mcp-server-name)
   (tools :initform (make-hash-table :test 'equal) :reader tool-server-table)
   (lock :initform (sb-thread:make-mutex :name "circle tool server") :reader tool-server-lock))
  (:documentation "A named set of tools the engine reaches over MCP."))

(defun make-tool-server (name)
  "A tool server named NAME, a string; its tools reach the model as
mcp__NAME__TOOL."
  (make-instance 'tool-server :name name))

(defmethod print-object ((server tool-server) stream)
  (print-unreadable-object (server stream :type t)
    (format stream "~A (~D tool~:P)" (mcp-server-name server)
            (hash-table-count (tool-server-table server)))))

(defvar *tool-server* (make-tool-server "lisp")
  "The image's own tool server, named \"lisp\", where DEFINE-TOOL puts tools
by default.")

(defun tool-server-tools (&optional (server *tool-server*))
  "SERVER's tools, sorted by name."
  (sb-thread:with-mutex ((tool-server-lock server))
    (sort (loop for tool being the hash-values of (tool-server-table server) collect tool)
          #'string< :key #'tool-name)))

(defun find-tool (name &optional (server *tool-server*))
  "The tool named NAME in SERVER, or NIL."
  (sb-thread:with-mutex ((tool-server-lock server))
    (values (gethash (string name) (tool-server-table server)))))

(defun add-tool (tool &optional (server *tool-server*))
  "Add TOOL to SERVER, replacing one of the same name, and tell running
engines. Return TOOL."
  (sb-thread:with-mutex ((tool-server-lock server))
    (setf (gethash (tool-name tool) (tool-server-table server)) tool))
  (tools-changed server)
  tool)

(defun remove-tool (name &optional (server *tool-server*))
  "Remove the tool named NAME from SERVER and tell running engines."
  (sb-thread:with-mutex ((tool-server-lock server))
    (remhash (string name) (tool-server-table server)))
  (tools-changed server)
  server)

;;; Defining tools

(defun json-name (symbol)
  (substitute #\_ #\- (string-downcase (symbol-name symbol))))

(defun parse-parameters (specs)
  "Each parameter spec is (VAR TYPE DESCRIPTION); those after &OPTIONAL
need not be given."
  (let ((required t))
    (loop for spec in specs
          if (eq spec '&optional) do (setf required nil)
          else collect (destructuring-bind (var type &optional (description "")) spec
                         (unless (member type '(:string :integer :number :boolean :object :array))
                           (error "~S is not a tool parameter type." type))
                         (list var type description required)))))

(defmacro define-tool (name (&rest parameters) &body body)
  "Define the tool NAME, a symbol or string, in *TOOL-SERVER*, or in the
server given as (NAME :SERVER SERVER). Each parameter is (VAR TYPE
DESCRIPTION), TYPE one of :STRING :INTEGER :NUMBER :BOOLEAN :OBJECT :ARRAY;
those after &OPTIONAL may be left out and are then NIL. A docstring first in
BODY is the description the model reads. BODY's value is the tool's answer:
a string as it is, anything else printed with PRINC. Signal TOOL-ERROR to
fail the call. Defining it again replaces it, in running engines too."
  (destructuring-bind (name &key (server '*tool-server*)) (if (consp name) name (list name))
    (let* ((parameters (parse-parameters parameters))
           (description (if (and (stringp (first body)) (rest body)) (first body) ""))
           (body (if (and (stringp (first body)) (rest body)) (rest body) body)))
      `(add-tool (make-instance 'tool
                                :name ,(if (stringp name) name (json-name name))
                                :description ,description
                                :parameters ',(loop for (var type text required) in parameters
                                                    collect (list (json-name var) type text required))
                                :function (lambda ,(mapcar #'first parameters)
                                            (declare (ignorable ,@(mapcar #'first parameters)))
                                            ,@body))
                 ,server))))

;;; Calling tools

(defun json-type-p (value type)
  (ecase type
    (:string (stringp value))
    (:integer (integerp value))
    (:number (realp value))
    (:boolean (member value '(t nil)))
    (:object (hash-table-p value))
    (:array (and (vectorp value) (not (stringp value))))))

(defun call-tool (name arguments &optional (server *tool-server*))
  "Call the tool NAME of SERVER with ARGUMENTS, a JSON object, and return
its answer as a string. Signal TOOL-ERROR for an unknown tool or a missing
or mistyped argument."
  (let ((tool (or (find-tool name server)
                  (error 'tool-error :message (format nil "No tool named ~A." name))))
        (arguments (or arguments (json-object))))
    (let ((values (loop for (key type nil required) in (tool-parameters tool)
                        collect (multiple-value-bind (value present) (gethash key arguments)
                                  (cond ((not present)
                                         (when required
                                           (error 'tool-error
                                                  :message (format nil "~A needs the argument ~A."
                                                                   (tool-name tool) key)))
                                         nil)
                                        ((json-type-p value type) value)
                                        (t (error 'tool-error
                                                  :message (format nil "~A: ~A must be ~(~A~)."
                                                                   (tool-name tool) key type))))))))
      (let ((answer (apply (tool-function tool) values)))
        (if (stringp answer) answer (princ-to-string answer))))))

;;; MCP

(defun tool-schema (tool)
  (json-object "name" (tool-name tool)
               "description" (tool-description tool)
               "inputSchema"
               (json-object "type" "object"
                            "properties"
                            (let ((properties (json-object)))
                              (loop for (key type text) in (tool-parameters tool)
                                    do (setf (gethash key properties)
                                             (json-object "type" (string-downcase type)
                                                          "description" text)))
                              properties)
                            "required"
                            (coerce (loop for (key nil nil required) in (tool-parameters tool)
                                          when required collect key)
                                    'vector))))

(defun rpc-result (id result)
  (json-object "jsonrpc" "2.0" "id" id "result" result))

(defmethod handle-mcp-request ((server tool-server) message)
  (let ((id (json-get message "id"))
        (method (json-get message "method"))
        (params (or (json-get message "params") (json-object))))
    (cond ((null id) nil)                ; a notification
          ((equal method "initialize")
           (rpc-result id (json-object
                           "protocolVersion" (or (json-get params "protocolVersion")
                                                 *mcp-protocol-version*)
                           "capabilities" (json-object "tools" (json-object "listChanged" t))
                           "serverInfo" (json-object "name" (mcp-server-name server)
                                                     "version" "0.0.1"))))
          ((equal method "ping") (rpc-result id (json-object)))
          ((equal method "tools/list")
           (rpc-result id (json-object "tools" (map 'vector #'tool-schema
                                                    (tool-server-tools server)))))
          ((equal method "tools/call")
           (rpc-result id (multiple-value-bind (text error-p)
                              (handler-case (call-tool (json-get params "name")
                                                       (json-get params "arguments")
                                                       server)
                                (error (condition) (values (princ-to-string condition) t)))
                            (json-object "content" (vector (json-object "type" "text" "text" text))
                                         "isError" error-p))))
          (t (json-object "jsonrpc" "2.0" "id" id
                          "error" (json-object "code" -32601
                                               "message" (format nil "No method ~A." method)))))))
