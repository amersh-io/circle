;;;; The engine protocol.
;;;;
;;;; An engine runs the model's loop for one conversation. The image starts
;;;; it, sends it what the person says, and hears every message it emits;
;;;; the engine calls back into the image for the tools the image serves and
;;;; for permission to use the others.

(in-package #:circle/engine)

(defvar *engine* nil
  "The engine whose message a handler, a tool or a permission function is
answering, while it runs.")

(define-condition engine-error (error)
  ((engine :initarg :engine :reader engine-error-engine)
   (message :initarg :message :initform nil :reader engine-error-message))
  (:report (lambda (condition stream)
             (format stream "~A~@[: ~A~]" (engine-error-engine condition)
                     (engine-error-message condition))))
  (:documentation "Something went wrong with an engine; ENGINE-ERROR-ENGINE
is the engine."))

(define-condition engine-exited (engine-error) ()
  (:documentation "The engine's process ended while the image waited on it."))

(define-condition engine-timeout (engine-error) ()
  (:documentation "The engine did not answer in time."))

(define-condition turn-error (engine-error)
  ((result :initarg :result :reader turn-error-message))
  (:documentation "A turn ended in an error; TURN-ERROR-MESSAGE is the
engine's result message."))

(setf (documentation 'engine-error-engine 'function)
      "The engine an ENGINE-ERROR is about."
      (documentation 'turn-error-message 'function)
      "The result message, a JSON object, of the turn that failed.")

(defclass engine ()
  ((session-id :initarg :resume :initform nil :accessor engine-session-id
               :documentation "The conversation's id, known once the engine has said it.")
   (handlers :initform '() :accessor engine-handlers
             :documentation "Functions called with every message the engine emits.")
   (mcp-servers :initarg :mcp-servers :initform '() :accessor engine-mcp-servers
                :documentation "The tool servers this image offers the engine.")
   (permission-function :initarg :permission-function :initform 'allow-own-tools
                        :accessor engine-permission-function
                        :documentation "Decides whether the engine may use a tool."))
  (:documentation "The loop the model runs in, for one conversation.

:RESUME is the id of a conversation to continue. :MCP-SERVERS are tool
servers the engine is offered (see MCP-SERVER-NAME). :PERMISSION-FUNCTION is
called with a tool's name and its input, a JSON object, when the engine
asks whether it may use the tool; it returns :ALLOW, or :DENY and a
message as a second value. The default is ALLOW-OWN-TOOLS."))

(setf (documentation 'engine-session-id 'function)
      "The id of ENGINE's conversation, or NIL until the engine has said it.
Give it as :RESUME to a new engine to continue the conversation."
      (documentation 'engine-handlers 'function)
      "The functions ENGINE calls with every message it emits, newest first."
      (documentation 'engine-mcp-servers 'function)
      "The tool servers ENGINE is offered. Change them before the engine starts."
      (documentation 'engine-permission-function 'function)
      "The function that decides whether ENGINE may use a tool.")

(defgeneric start-engine (engine)
  (:documentation "Start ENGINE, resuming its conversation if it has a
session id, and return it once it is ready for a message."))

(defgeneric stop-engine (engine)
  (:documentation "Stop ENGINE and return it. Its session id stays, so
starting it again continues the same conversation."))

(defgeneric engine-running-p (engine)
  (:documentation "True while ENGINE is running."))

(defgeneric send-user-message (engine text)
  (:documentation "Send TEXT to ENGINE as the person's message and return at
once; the engine's answer comes to its handlers."))

(defgeneric ask (engine text &key timeout)
  (:documentation "Send TEXT to ENGINE as the person's message, wait for the
turn to end, and return the final text and the result message as a second
value. Signals TURN-ERROR if the turn failed, ENGINE-EXITED if the engine
ended, and ENGINE-TIMEOUT after TIMEOUT seconds (NIL waits for ever)."))

(defun add-engine-handler (engine function)
  "Call FUNCTION with each message, a JSON object, that ENGINE emits, on the
engine's own thread, with *ENGINE* bound. An error in it is reported and
the engine goes on. Return FUNCTION, to give to REMOVE-ENGINE-HANDLER."
  (push function (engine-handlers engine))
  function)

(defun remove-engine-handler (engine function)
  "Stop calling FUNCTION with ENGINE's messages."
  (setf (engine-handlers engine) (remove function (engine-handlers engine)))
  engine)

(defun call-handlers (engine message)
  (let ((*engine* engine))
    (dolist (handler (engine-handlers engine))
      (handler-case (funcall handler message)
        (error (condition)
          (format *error-output* "~&;; circle: an engine handler failed: ~A~%" condition))))))

;;; Tool servers

(defgeneric mcp-server-name (server)
  (:documentation "The name SERVER is offered to the engine under. Its tools
reach the model as mcp__NAME__TOOL."))

(defgeneric handle-mcp-request (server message)
  (:documentation "Answer MESSAGE, a JSON-RPC request or notification for
SERVER, with the JSON-RPC response, a JSON object, or NIL for a
notification."))

;;; Engines that run, to tell about changed tools

(defvar *running-engines* '())
(defvar *running-engines-lock* (sb-thread:make-mutex :name "circle running engines"))

(defun note-running (engine runningp)
  (sb-thread:with-mutex (*running-engines-lock*)
    (setf *running-engines* (if runningp
                                (adjoin engine *running-engines*)
                                (remove engine *running-engines*)))))

(defgeneric notify-tools-changed (engine server)
  (:documentation "Tell ENGINE that SERVER's tools changed, so it lists them
again before its next turn.")
  (:method (engine server)
    (declare (ignore engine server))
    nil))

(defun tools-changed (server)
  "Tell every running engine offered SERVER that its tools changed."
  (dolist (engine (sb-thread:with-mutex (*running-engines-lock*) (copy-list *running-engines*)))
    (when (member server (engine-mcp-servers engine))
      (notify-tools-changed engine server)))
  server)

;;; Permissions

(defun own-tool-p (engine tool-name)
  (some (lambda (server)
          (let ((prefix (format nil "mcp__~A__" (mcp-server-name server))))
            (and (> (length tool-name) (length prefix))
                 (string= prefix tool-name :end2 (length prefix)))))
        (engine-mcp-servers engine)))

(defun allow-own-tools (tool-name input)
  "The default permission function: allow the tools of the image's own
servers, and deny every other tool the engine asks about, saying why. The
engine asks only about tools its own permission settings do not already
allow; to let it use more, give the engine another function."
  (declare (ignore input))
  (if (and *engine* (own-tool-p *engine* tool-name))
      :allow
      (values :deny (format nil "circle allows only the image's own tools by default; ~
~A needs a permission function that allows it." tool-name))))

;;; Messages

(defun message-type (message)
  "The type of an engine MESSAGE, such as \"assistant\" or \"result\"."
  (json-get message "type"))

(defun message-text (message)
  "The text an engine MESSAGE carries: a result's text, or the text blocks
of an assistant message joined; NIL if it has none."
  (let ((type (message-type message)))
    (cond ((equal type "result") (json-get message "result"))
          ((equal type "assistant")
           (let ((texts (loop for block across (or (json-get message "message" "content") #())
                              when (equal "text" (json-get block "type"))
                                collect (json-get block "text"))))
             (and texts (format nil "~{~A~}" texts)))))))
