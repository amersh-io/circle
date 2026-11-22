;;;; A stand-in for the Claude Code CLI that speaks the same stream-json
;;;; protocol with canned turns, so the engine can be tested without a model.
;;;;
;;;; Run as: sbcl --load .qlot/setup.lisp --load test/fake-claude.lisp
;;;;         --end-toplevel-options <the CLI's arguments>
;;;;
;;;; It keeps each conversation's messages in CIRCLE_FAKE_STATE/<id>, so
;;;; --resume continues one. What a user message starts with picks the turn:
;;;;
;;;;   eval: CODE      call the image's eval tool with CODE; answer its text
;;;;   keep: CODE      the same, asking eval to keep CODE as a change
;;;;   freeze          call the image's freeze_generation tool
;;;;   tools           list the image's tools; answer their names
;;;;   use bash        ask permission for Bash; answer allowed or denied
;;;;   history         answer the earlier messages of the conversation
;;;;   fail            end the turn in an error
;;;;   die             exit at once, mid-turn
;;;;   sleep           wait five seconds, then answer
;;;;   anything else   answer "echo: " and the text

(asdf:load-system "com.inuoe.jzon")

(defpackage #:circle-fake-claude
  (:use #:cl))

(in-package #:circle-fake-claude)

(defvar *session-id* nil)
(defvar *servers* '())
(defvar *counter* 0)
(defvar *announced* nil)
(defvar *held* '()
  "User messages read while waiting for a response, to take in order later.")

(defun obj (&rest keys-and-values)
  (let ((table (make-hash-table :test 'equal)))
    (loop for (k v) on keys-and-values by #'cddr do (setf (gethash k table) v))
    table))

(defun get-in (value &rest path)
  (dolist (key path value)
    (setf value (cond ((and (integerp key) (vectorp value))
                       (and (< key (length value)) (aref value key)))
                      ((hash-table-p value) (gethash key value))))))

(defun emit (object)
  (write-line (com.inuoe.jzon:stringify object))
  (finish-output))

(defun state-file ()
  (merge-pathnames *session-id*
                   (uiop:ensure-directory-pathname (uiop:getenv "CIRCLE_FAKE_STATE"))))

(defun history ()
  (let ((file (state-file)))
    (if (probe-file file) (uiop:read-file-lines file) '())))

(defun remember (text)
  (with-open-file (out (ensure-directories-exist (state-file))
                       :direction :output :if-exists :append :if-does-not-exist :create)
    (write-line (substitute #\Space #\Newline text) out)))

(defun answer-host-request (message)
  ;; The host may tell a server's tools changed; nothing else is expected.
  (emit (obj "type" "control_response"
             "response" (obj "subtype" "success"
                             "request_id" (gethash "request_id" message)
                             "response" (obj)))))

(defun request (subtype &rest fields)
  "Send a control request to the host and read until its response."
  (let ((id (format nil "fake-~D" (incf *counter*))))
    (emit (obj "type" "control_request" "request_id" id
               "request" (apply #'obj "subtype" subtype fields)))
    (loop for line = (read-line *standard-input* nil)
          unless line do (uiop:quit 0)
          do (let ((message (com.inuoe.jzon:parse line)))
               (cond ((and (equal "control_response" (gethash "type" message))
                           (equal id (get-in message "response" "request_id")))
                      (return (get-in message "response")))
                     ((equal "control_request" (gethash "type" message))
                      (answer-host-request message))
                     (t (setf *held* (append *held* (list line)))))))))

(defun next-line ()
  (if *held* (pop *held*) (read-line *standard-input* nil)))

(defun mcp (server method &optional params)
  (get-in (request "mcp_message" "server_name" server
                   "message" (obj "jsonrpc" "2.0" "id" (incf *counter*) "method" method
                                  "params" (or params (obj))))
          "response" "mcp_response"))

(defun connect-servers ()
  (dolist (server *servers*)
    (mcp server "initialize" (obj "protocolVersion" "2025-06-18" "capabilities" (obj)))
    (request "mcp_message" "server_name" server
             "message" (obj "jsonrpc" "2.0" "method" "notifications/initialized"))))

(defun prefixp (prefix text)
  (and (>= (length text) (length prefix)) (string= prefix text :end2 (length prefix))))

(defun call (tool arguments)
  "Call the image's TOOL; its text and whether it is an error. As the CLI
does, the call is reported first as an assistant message with a tool_use
block, and its answer then as a user message with a tool_result block."
  (let ((id (format nil "toolu_fake_~D" (incf *counter*))))
    (emit (obj "type" "assistant" "session_id" *session-id*
               "message" (obj "role" "assistant"
                              "content" (vector (obj "type" "tool_use" "id" id
                                                     "name" (format nil "mcp__~A__~A"
                                                                    (first *servers*) tool)
                                                     "input" arguments)))))
    (let* ((result (mcp (first *servers*) "tools/call" (obj "name" tool "arguments" arguments)))
           (text (get-in result "result" "content" 0 "text"))
           (errorp (get-in result "result" "isError")))
      (emit (obj "type" "user" "session_id" *session-id*
                 "message" (obj "role" "user"
                                "content" (vector (obj "type" "tool_result" "tool_use_id" id
                                                       "content" (vector (obj "type" "text"
                                                                              "text" text))
                                                       "is_error" errorp)))))
      (values text errorp))))

(defun turn (text)
  "The answer to TEXT and whether it is an error."
  (cond ((prefixp "eval: " text) (call "eval" (obj "code" (subseq text 6))))
        ((prefixp "keep: " text) (call "eval" (obj "code" (subseq text 6) "keep" t)))
        ((string= text "freeze") (call "freeze_generation" (obj)))
        ((string= text "tools")
         (let ((tools (get-in (mcp (first *servers*) "tools/list") "result" "tools")))
           (format nil "~{~A~^ ~}" (map 'list (lambda (tool) (gethash "name" tool)) tools))))
        ((string= text "use bash")
         (let ((response (get-in (request "can_use_tool" "tool_name" "Bash"
                                          "input" (obj "command" "ls"))
                                 "response")))
           (if (equal "allow" (gethash "behavior" response))
               "allowed"
               (format nil "denied: ~A" (gethash "message" response)))))
        ((string= text "history") (format nil "~{~A~^ | ~}" (butlast (history))))
        ((string= text "fail") (values "it failed" t))
        ((string= text "die") (uiop:quit 3))
        ((string= text "sleep") (sleep 5) "slept")
        (t (format nil "echo: ~A" text))))

(defun user-text (message)
  (let ((content (get-in message "message" "content")))
    (if (stringp content)
        content
        (format nil "~{~A~}" (loop for block across content
                                   when (equal "text" (gethash "type" block))
                                     collect (gethash "text" block))))))

(defun main (arguments)
  (loop for (flag value) on arguments
        do (cond ((string= flag "--resume") (setf *session-id* value))
                 ((string= flag "--mcp-config")
                  (setf *servers* (loop for name being the hash-keys
                                          of (get-in (com.inuoe.jzon:parse value) "mcpServers")
                                        collect name)))))
  (unless *session-id*
    (setf *session-id* (format nil "fake-~36R" (random (expt 36 10) (make-random-state t)))))
  (loop for line = (next-line)
        while line
        do (let* ((message (com.inuoe.jzon:parse line))
                  (type (gethash "type" message)))
             (cond ((and (equal type "control_request")
                         (equal "initialize" (get-in message "request" "subtype")))
                    (emit (obj "type" "control_response"
                               "response" (obj "subtype" "success"
                                               "request_id" (gethash "request_id" message)
                                               "response" (obj "commands" #()))))
                    (connect-servers))
                   ((equal type "control_request") (answer-host-request message))
                   ((equal type "user")
                    (let ((text (user-text message)))
                      (remember text)
                      (unless *announced*
                        (setf *announced* t)
                        (emit (obj "type" "system" "subtype" "init" "session_id" *session-id*)))
                      (multiple-value-bind (answer errorp) (turn text)
                        (emit (obj "type" "assistant" "session_id" *session-id*
                                   "message" (obj "role" "assistant"
                                                  "content" (vector (obj "type" "text"
                                                                         "text" answer)))))
                        (emit (obj "type" "result" "subtype" (if errorp "error" "success")
                                   "is_error" errorp "result" answer
                                   "session_id" *session-id*))))))))
  (uiop:quit 0))

(main (rest sb-ext:*posix-argv*))
