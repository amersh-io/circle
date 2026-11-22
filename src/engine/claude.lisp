;;;; An engine that runs the Claude Code CLI as a child process.
;;;;
;;;; The CLI runs with -p and stream-json input and output: one JSON message
;;;; per line each way. Besides the conversation, the same lines carry
;;;; control requests both ways. The image sends `initialize` first; the CLI
;;;; asks `can_use_tool` before a tool its permission settings do not allow,
;;;; and sends `mcp_message` for each JSON-RPC message to a tool server of
;;;; type "sdk", which lives here in the image rather than in a process of
;;;; its own.

(in-package #:circle/engine)

(defvar *claude-command* '("claude")
  "The program a CLAUDE-ENGINE runs when given no :COMMAND, and its first
arguments.")

(defclass claude-engine (engine)
  ((command :initarg :command :initform *claude-command* :accessor engine-command
            :documentation "The program and its first arguments.")
   (model :initarg :model :initform nil :accessor engine-model
          :documentation "The model to ask for, or NIL for the CLI's default.")
   (arguments :initarg :arguments :initform '() :accessor engine-arguments
              :documentation "More arguments for the CLI.")
   (directory :initarg :directory :initform nil :accessor engine-directory
              :documentation "The directory the CLI runs in, or NIL for the image's.")
   (start-timeout :initarg :start-timeout :initform 60 :accessor engine-start-timeout)
   (process :initform nil :accessor engine-process
            :documentation "The CLI's process, a UIOP process-info, while it runs.")
   (input :initform nil :accessor engine-input)
   (threads :initform '() :accessor engine-threads)
   (lock :initform (sb-thread:make-mutex :name "circle engine") :reader engine-lock)
   (changed :initform (sb-thread:make-waitqueue :name "circle engine") :reader engine-changed)
   (turn :initform (sb-thread:make-mutex :name "circle turn") :reader engine-turn)
   (responses :initform (make-hash-table :test 'equal) :reader engine-responses)
   (result :initform nil :accessor engine-result)
   (exited :initform t :accessor engine-exited-p)
   (stderr :initform '() :accessor engine-stderr)
   (counter :initform 0 :accessor engine-counter))
  (:documentation "An engine that runs the Claude Code CLI as a child
process and speaks to it over stdio.

Besides the initargs of ENGINE: :COMMAND, the program and its first
arguments, *CLAUDE-COMMAND* by default; :MODEL, a model name or alias such as
\"haiku\"; :ARGUMENTS, more arguments for the CLI, such as
(\"--tools\" \"\"); :DIRECTORY, the directory it runs in."))

(setf (documentation 'engine-command 'function)
      "The program a CLAUDE-ENGINE runs, and its first arguments, as a list."
      (documentation 'engine-model 'function)
      "The model a CLAUDE-ENGINE asks for, or NIL for the CLI's default."
      (documentation 'engine-arguments 'function)
      "More arguments a CLAUDE-ENGINE gives the CLI."
      (documentation 'engine-directory 'function)
      "The directory a CLAUDE-ENGINE runs the CLI in, or NIL for the image's."
      (documentation 'engine-process 'function)
      "The CLI's process (a UIOP process-info) while the engine runs, else NIL.")

(defmethod print-object ((engine claude-engine) stream)
  (print-unreadable-object (engine stream :type t :identity t)
    (format stream "~:[stopped~;running~]~@[ ~A~]"
            (engine-running-p engine) (engine-session-id engine))))

(defun engine-command-line (engine)
  "The whole command line ENGINE runs the CLI with."
  (append (engine-command engine)
          (list "-p" "--input-format" "stream-json" "--output-format" "stream-json"
                "--verbose"
                ;; Permission questions come as control requests on stdout.
                "--permission-prompt-tool" "stdio")
          (when (engine-model engine) (list "--model" (engine-model engine)))
          (when (engine-session-id engine) (list "--resume" (engine-session-id engine)))
          (when (engine-mcp-servers engine)
            (list "--mcp-config"
                  (to-json (json-object
                            "mcpServers"
                            (let ((servers (make-hash-table :test 'equal)))
                              (dolist (server (engine-mcp-servers engine) servers)
                                (let ((name (mcp-server-name server)))
                                  (setf (gethash name servers)
                                        (json-object "type" "sdk" "name" name)))))))))
          (engine-arguments engine)))

;;; Writing and waiting

(defun send-json (engine object)
  (sb-thread:with-mutex ((engine-lock engine))
    (let ((stream (engine-input engine)))
      (when (or (engine-exited-p engine) (null stream))
        (error 'engine-exited :engine engine :message "it is not running"))
      (write-line (to-json object) stream)
      (finish-output stream)))
  object)

(defun stderr-tail (engine)
  (let ((lines (reverse (engine-stderr engine))))
    (and lines (format nil "~{~A~^~%~}" lines))))

(defun wait-for (engine predicate timeout what)
  "Wait, with the lock held, until PREDICATE returns true, and return its
value. Signal ENGINE-EXITED if the engine ends first, ENGINE-TIMEOUT after
TIMEOUT seconds."
  (let ((deadline (and timeout (+ (get-internal-real-time)
                                  (* timeout internal-time-units-per-second)))))
    (loop
      (let ((value (funcall predicate)))
        (when value (return value)))
      (when (engine-exited-p engine)
        (error 'engine-exited :engine engine
                              :message (format nil "it ended while waiting for ~A~@[~%~A~]"
                                               what (stderr-tail engine))))
      (let ((left (and deadline (/ (- deadline (get-internal-real-time))
                                   internal-time-units-per-second))))
        (when (and left (<= left 0))
          (error 'engine-timeout :engine engine
                                 :message (format nil "no answer for ~A in ~A s" what timeout)))
        (sb-thread:condition-wait (engine-changed engine) (engine-lock engine)
                                  :timeout left)))))

(defun control-request (engine subtype &rest fields)
  "Send a control request and return its response, a JSON object."
  (let ((id (sb-thread:with-mutex ((engine-lock engine))
              (format nil "circle-~D" (incf (engine-counter engine))))))
    (send-json engine (json-object "type" "control_request" "request_id" id
                                   "request" (apply #'json-object "subtype" subtype fields)))
    (sb-thread:with-mutex ((engine-lock engine))
      (let ((response (wait-for engine
                                (lambda () (gethash id (engine-responses engine)))
                                (engine-start-timeout engine)
                                (format nil "the ~A request" subtype))))
        (remhash id (engine-responses engine))
        (when (equal "error" (json-get response "subtype"))
          (error 'engine-error :engine engine
                               :message (format nil "~A failed: ~A" subtype
                                                (json-get response "error"))))
        response))))

;;; Reading

(defun receive (engine message)
  (let ((session-id (json-get message "session_id")))
    (when (stringp session-id)
      (setf (engine-session-id engine) session-id)))
  ;; Handlers hear a message before anyone waiting on it wakes, so what a
  ;; handler prints of a turn comes before ASK returns.
  (call-handlers engine message)
  (let ((type (message-type message)))
    (cond ((equal type "control_request")
           (answer-control-request-later engine message))
          ((equal type "control_response")
           (let ((response (json-get message "response")))
             (sb-thread:with-mutex ((engine-lock engine))
               (setf (gethash (json-get response "request_id") (engine-responses engine))
                     response)
               (sb-thread:condition-broadcast (engine-changed engine)))))
          ((equal type "result")
           (sb-thread:with-mutex ((engine-lock engine))
             (setf (engine-result engine) message)
             (sb-thread:condition-broadcast (engine-changed engine)))))))

(defun read-messages (engine stream)
  (unwind-protect
       (loop for line = (handler-case (read-line stream nil)
                          (error () nil))
             while line
             do (let ((message (handler-case (parse-json line)
                                 (error () nil))))
                  (if (hash-table-p message)
                      (receive engine message)
                      (format *error-output* "~&;; circle: the engine wrote a line that is not a message: ~A~%"
                              (subseq line 0 (min 200 (length line)))))))
    (sb-thread:with-mutex ((engine-lock engine))
      (setf (engine-exited-p engine) t)
      (sb-thread:condition-broadcast (engine-changed engine)))))

(defun keep-stderr (engine stream)
  (loop for line = (handler-case (read-line stream nil) (error () nil))
        while line
        do (sb-thread:with-mutex ((engine-lock engine))
             (push line (engine-stderr engine))
             (when (> (length (engine-stderr engine)) 40)
               (setf (engine-stderr engine) (subseq (engine-stderr engine) 0 40))))))

;;; Control requests from the CLI

(defun find-mcp-server (engine name)
  (find name (engine-mcp-servers engine) :key #'mcp-server-name :test #'string=))

(defun control-reply (engine request)
  "The response to the CLI's control REQUEST."
  (let ((subtype (json-get request "subtype")))
    (cond ((equal subtype "can_use_tool")
           (let ((input (or (json-get request "input") (json-object))))
             (multiple-value-bind (decision message)
                 (funcall (engine-permission-function engine)
                          (json-get request "tool_name") input)
               (if (eq decision :allow)
                   (json-object "behavior" "allow" "updatedInput" input)
                   (json-object "behavior" "deny"
                                "message" (or message "Denied by the image."))))))
          ((equal subtype "mcp_message")
           (let ((server (find-mcp-server engine (json-get request "server_name"))))
             (unless server
               (error "no tool server named ~S" (json-get request "server_name")))
             (json-object "mcp_response"
                          (or (handle-mcp-request server (json-get request "message"))
                              (json-object)))))
          (t (error "circle does not answer the control request ~S" subtype)))))

(defun answer-control-request (engine message)
  (let ((id (json-get message "request_id"))
        (*engine* engine))
    (handler-case
        (send-json engine
                   (json-object "type" "control_response"
                                "response" (json-object "subtype" "success" "request_id" id
                                                        "response" (control-reply
                                                                    engine
                                                                    (json-get message "request")))))
      (engine-exited () nil)
      (error (condition)
        (ignore-errors
         (send-json engine
                    (json-object "type" "control_response"
                                 "response" (json-object "subtype" "error" "request_id" id
                                                         "error" (princ-to-string condition)))))))))

(defun answer-control-request-later (engine message)
  ;; A tool may take long; the reader goes on reading meanwhile.
  (sb-thread:make-thread (lambda () (answer-control-request engine message))
                         :name "circle control request"))

;;; The protocol

(defmethod notify-tools-changed ((engine claude-engine) server)
  ;; The CLI lists a server's tools again before its next turn once told;
  ;; told from another thread, so DEFINE-TOOL never waits on the engine.
  (sb-thread:make-thread
   (lambda ()
     (handler-case
         (control-request engine "mcp_message"
                          "server_name" (mcp-server-name server)
                          "message" (json-object "jsonrpc" "2.0"
                                                 "method" "notifications/tools/list_changed"))
       (error () nil)))
   :name "circle tools changed"))

(defmethod engine-running-p ((engine claude-engine))
  (and (engine-process engine) (not (engine-exited-p engine))))

(defmethod start-engine ((engine claude-engine))
  (when (engine-running-p engine)
    (error 'engine-error :engine engine :message "it is already running"))
  (let ((process (uiop:launch-program (engine-command-line engine)
                                      :input :stream :output :stream :error-output :stream
                                      :external-format :utf-8
                                      :directory (engine-directory engine))))
    (sb-thread:with-mutex ((engine-lock engine))
      (setf (engine-process engine) process
            (engine-input engine) (uiop:process-info-input process)
            (engine-exited-p engine) nil
            (engine-result engine) nil
            (engine-stderr engine) '())
      (clrhash (engine-responses engine)))
    (setf (engine-threads engine)
          (list (sb-thread:make-thread #'read-messages
                                       :name "circle engine reader"
                                       :arguments (list engine (uiop:process-info-output process)))
                (sb-thread:make-thread #'keep-stderr
                                       :name "circle engine stderr"
                                       :arguments (list engine (uiop:process-info-error-output process)))))
    (handler-bind ((error (lambda (condition)
                            (declare (ignore condition))
                            (ignore-errors (stop-engine engine)))))
      (control-request engine "initialize"))
    (note-running engine t)
    engine))

(defmethod stop-engine ((engine claude-engine))
  (note-running engine nil)
  (let ((process (engine-process engine)))
    (when process
      ;; The CLI ends when its input does.
      (sb-thread:with-mutex ((engine-lock engine))
        (ignore-errors (close (engine-input engine)))
        (setf (engine-input engine) nil))
      (loop repeat 100 while (uiop:process-alive-p process) do (sleep 0.05))
      (when (uiop:process-alive-p process)
        (uiop:terminate-process process)
        (loop repeat 40 while (uiop:process-alive-p process) do (sleep 0.05))
        (when (uiop:process-alive-p process)
          (uiop:terminate-process process :urgent t)))
      (ignore-errors (uiop:wait-process process))
      (dolist (thread (engine-threads engine))
        (unless (eq thread sb-thread:*current-thread*)
          (ignore-errors (sb-thread:join-thread thread :default nil :timeout 5))))
      (sb-thread:with-mutex ((engine-lock engine))
        (setf (engine-process engine) nil
              (engine-threads engine) '()
              (engine-exited-p engine) t)
        (sb-thread:condition-broadcast (engine-changed engine)))))
  engine)

(defmethod send-user-message ((engine claude-engine) text)
  (check-type text string)
  (send-json engine (json-object "type" "user"
                                 "message" (json-object "role" "user" "content" text)))
  engine)

(defmethod ask ((engine claude-engine) text &key timeout)
  (sb-thread:with-mutex ((engine-turn engine))
    (sb-thread:with-mutex ((engine-lock engine))
      (setf (engine-result engine) nil))
    (send-user-message engine text)
    (let ((result (sb-thread:with-mutex ((engine-lock engine))
                    (wait-for engine (lambda () (engine-result engine)) timeout "the turn"))))
      (when (json-get result "is_error")
        (error 'turn-error :engine engine :result result
                           :message (or (json-get result "result")
                                        (json-get result "subtype"))))
      (values (json-get result "result") result))))

(defmacro with-engine ((var engine) &body body)
  "Start ENGINE, bind VAR to it, run BODY and stop the engine however BODY
ends."
  `(let ((,var (start-engine ,engine)))
     (unwind-protect (progn ,@body)
       (stop-engine ,var))))
