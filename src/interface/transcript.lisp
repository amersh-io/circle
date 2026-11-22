;;;; The transcript the window shows: the conversation as entries.
;;;;
;;;; Each entry is a JSON object with an "index", its place in the transcript,
;;;; and a "kind":
;;;;
;;;;   user               the person's text
;;;;   assistant          the model's text
;;;;   tool               a tool call: its "id", "name" and "input" (JSON text)
;;;;   tool-result        a tool's answer: "toolUseId", "text", "isError"
;;;;   turn-end           a turn ended; "isError", and "text" if it failed
;;;;   permission         the engine asks to use a tool: "id", "tool", "input"
;;;;   permission-answer  the answer: "id", "allow", "reason"
;;;;
;;;; Entries are only added. The transcript is kept in this image and, if
;;;; *TRANSCRIPT-FILE* names one, appended to that file as JSON lines and read
;;;; back when the interface starts -- so a new generation shows the
;;;; conversation the generations before it had.

(in-package #:circle/interface)

(defvar *transcript* (make-array 0 :adjustable t :fill-pointer t)
  "The entries, in order.")

(defvar *transcript-lock* (sb-thread:make-mutex :name "circle transcript"))

(defvar *transcript-file* nil
  "A file the transcript is appended to and read back from, or NIL to keep it
in this image only.")

(defun entry (kind &rest fields)
  "A new entry of KIND with FIELDS, a plist of JSON names and values; NIL
values are left out unless the field is a boolean one."
  (let ((object (json-object "kind" kind)))
    (loop for (key value) on fields by #'cddr
          when (or value (member key '("isError" "allow") :test #'string=))
            do (setf (gethash key object) value))
    object))

(defun append-to-file (entry)
  (when *transcript-file*
    (handler-case
        (with-open-file (out (ensure-directories-exist *transcript-file*)
                             :direction :output :if-exists :append :if-does-not-exist :create
                             :external-format :utf-8)
          (write-line (cl-proteus/core:write-json entry) out))
      (error (condition)
        (format *error-output* "~&;; circle: cannot write the transcript: ~A~%" condition)))))

(defun record-entry (entry)
  "Add ENTRY, a JSON object with a \"kind\", to the transcript, give it its
\"index\", and send it to the window's pages as the event circle-entry.
Return it."
  (sb-thread:with-mutex (*transcript-lock*)
    (setf (gethash "index" entry) (length *transcript*))
    (vector-push-extend entry *transcript*)
    (append-to-file entry))
  (cl-proteus/core:emit "circle-entry" entry)
  entry)

(defun record-user-text (text)
  "Record TEXT as what the person said. Return the entry."
  (record-entry (entry "user" "text" text)))

(defun transcript-entries (&optional (from 0))
  "The entries from index FROM on, as a vector."
  (sb-thread:with-mutex (*transcript-lock*)
    (subseq *transcript* (min (max from 0) (length *transcript*)))))

(defun clear-transcript ()
  "Forget every entry, in this image; the file, if any, stays."
  (sb-thread:with-mutex (*transcript-lock*)
    (setf (fill-pointer *transcript*) 0))
  nil)

(defun load-transcript (file)
  "Read FILE's entries into the transcript, if the transcript is empty."
  (when (probe-file file)
    (sb-thread:with-mutex (*transcript-lock*)
      (when (zerop (length *transcript*))
        (with-open-file (in file :external-format :utf-8)
          (loop for line = (read-line in nil)
                while line
                do (let ((entry (ignore-errors (cl-proteus/core:read-json line))))
                     (when (hash-table-p entry)
                       (setf (gethash "index" entry) (length *transcript*))
                       (vector-push-extend entry *transcript*)))))))))

;;; From the engine's messages

(defun block-text (content)
  "The text of a tool result's CONTENT: a string, or text blocks."
  (cond ((stringp content) content)
        ((vectorp content)
         (format nil "~{~A~^~%~}"
                 (loop for block across content
                       when (equal "text" (json-get block "type"))
                         collect (json-get block "text"))))
        (t "")))

(defun message-entries (message)
  "The entries an engine MESSAGE, a JSON object, adds to the transcript: the
text and tool calls of an assistant message, the tool results the engine
reports back, and the end of a turn. Nothing for any other message."
  (let ((type (message-type message)))
    (cond ((equal type "assistant")
           (loop for block across (or (json-get message "message" "content") #())
                 for kind = (json-get block "type")
                 when (and (equal kind "text") (plusp (length (json-get block "text"))))
                   collect (entry "assistant" "text" (json-get block "text"))
                 when (equal kind "tool_use")
                   collect (entry "tool" "id" (json-get block "id")
                                         "name" (json-get block "name")
                                         "input" (to-json (or (json-get block "input")
                                                              (json-object))))))
          ((equal type "user")
           (let ((content (json-get message "message" "content")))
             (when (vectorp content)
               (loop for block across content
                     when (equal "tool_result" (json-get block "type"))
                       collect (entry "tool-result"
                                      "toolUseId" (json-get block "tool_use_id")
                                      "text" (block-text (json-get block "content"))
                                      "isError" (eq t (json-get block "is_error")))))))
          ((equal type "result")
           (let ((errorp (eq t (json-get message "is_error"))))
             (list (entry "turn-end" "isError" errorp
                          "text" (and errorp (or (json-get message "result")
                                                 (json-get message "subtype"))))))))))
