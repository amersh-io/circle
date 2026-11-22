;;;; Running the interface: the engine's messages into the transcript, the
;;;; window's commands, permission cards, and the connection to the shell.
;;;;
;;;; START-INTERFACE keeps this image connected to the shell on a socket --
;;;; trying again every second while there is none, so the shell may start
;;;; after the image or go and come back. While connected, the shell's
;;;; window shows the view "circle" and its page calls the commands below.

(in-package #:circle/interface)

(defvar *permission-timeout* 300
  "Seconds a permission card waits for the person before it denies.")

(defclass interface ()
  ((engine :initarg :engine :reader interface-engine
           :documentation "The engine whose conversation the window shows.")
   (socket :initarg :socket :reader interface-socket
           :documentation "The path of the shell's socket.")
   (name :initarg :name :initform nil :reader interface-name)
   (handler :initform nil :accessor interface-handler)
   (previous-permission-function :initform nil :accessor interface-previous-permission-function)
   (keeper :initform nil :accessor interface-keeper)
   (stopping :initform nil :accessor interface-stopping-p))
  (:documentation "The image's side of its window, made by START-INTERFACE."))

(setf (documentation 'interface-engine 'function)
      "The engine whose conversation an INTERFACE's window shows."
      (documentation 'interface-socket 'function)
      "The path of the socket of the shell an INTERFACE connects to.")

(defvar *interface* nil
  "The running interface, if any.")

(defun interface-connected-p (&optional (interface *interface*))
  "True while INTERFACE, by default the running one, is connected to its
shell, so a window can show this image's page."
  (and interface (not (interface-stopping-p interface))
       (cl-proteus/client:shell-connected-p)))

(defmethod print-object ((interface interface) stream)
  (print-unreadable-object (interface stream :type t)
    (format stream "~A~:[ not connected~; connected~]" (interface-socket interface)
            (interface-connected-p interface))))

;;; Permission cards

(defvar *cards* (make-hash-table)
  "Permission cards waiting for an answer, by id: a cons of the answer, or
NIL while there is none, and nothing else.")

(defvar *cards-lock* (sb-thread:make-mutex :name "circle permission cards"))
(defvar *cards-changed* (sb-thread:make-waitqueue :name "circle permission cards"))
(defvar *card-counter* 0)

(defun ask-window (tool-name input)
  "Show a permission card for TOOL-NAME with INPUT in the window, wait for
the person's answer at most *PERMISSION-TIMEOUT* seconds, and return :ALLOW,
or :DENY and the reason."
  (let ((id (sb-thread:with-mutex (*cards-lock*)
              (let ((id (incf *card-counter*)))
                (setf (gethash id *cards*) (list nil))
                id))))
    (record-entry (entry "permission" "id" id "tool" tool-name
                         "input" (to-json (or input (json-object)))))
    (let* ((deadline (+ (get-internal-real-time)
                        (* *permission-timeout* internal-time-units-per-second)))
           (answer (sb-thread:with-mutex (*cards-lock*)
                     (loop
                       (let ((answer (car (gethash id *cards*))))
                         (when answer (return answer)))
                       (let ((left (/ (- deadline (get-internal-real-time))
                                      internal-time-units-per-second)))
                         (when (<= left 0) (return nil))
                         (sb-thread:condition-wait *cards-changed* *cards-lock*
                                                   :timeout left))))))
      (sb-thread:with-mutex (*cards-lock*)
        (remhash id *cards*))
      (let ((allow (eq answer :allow))
            (reason (case answer
                      (:allow nil)
                      (:deny "The person denied it in the window.")
                      (t (format nil "No answer in the window in ~D seconds." *permission-timeout*)))))
        (record-entry (entry "permission-answer" "id" id "allow" allow "reason" reason))
        (if allow :allow (values :deny reason))))))

(defun answer-card (id allow)
  "Answer the permission card ID: allow the tool if ALLOW is true. Return
true if the card was waiting."
  (sb-thread:with-mutex (*cards-lock*)
    (let ((cell (gethash id *cards*)))
      (when (and cell (null (car cell)))
        (setf (car cell) (if allow :allow :deny))
        (sb-thread:condition-broadcast *cards-changed*)
        t))))

(defun interface-permission (tool-name input)
  "The permission function of an engine whose window is shown: the image's
own tools are allowed, as ALLOW-OWN-TOOLS allows them; any other tool is
asked about in the window while it is connected, and denied otherwise."
  (multiple-value-bind (decision reason) (allow-own-tools tool-name input)
    (if (or (eq decision :allow) (not (interface-connected-p)))
        (values decision reason)
        (ask-window tool-name input))))

;;; The commands the page calls

(cl-proteus/core:define-command circle-send (text)
  "Send TEXT, typed in the window, to the engine. Answers the entry's index."
  (gethash "index" (interface-send text)))

(cl-proteus/core:define-command circle-transcript (from)
  "The transcript's entries from index FROM on."
  (transcript-entries (if (integerp from) from 0)))

(cl-proteus/core:define-command circle-answer (id allow)
  "Answer the permission card ID; true if it was waiting."
  (answer-card id (eq allow t)))

(cl-proteus/core:define-command circle-status ()
  "What the window shows in its title bar: whether the engine runs, and the
conversation's id."
  (let ((engine (and *interface* (interface-engine *interface*))))
    (json-object "running" (and engine (engine-running-p engine) t)
                 "sessionId" (or (and engine (engine-session-id engine)) "")
                 "entries" (length (transcript-entries)))))

;;; Running

(defun interface-send (text &optional (interface *interface*))
  "Record TEXT as the person's and send it to INTERFACE's engine; return
the entry. The answer reaches the transcript as the engine gives it."
  (check-type text string)
  (unless interface
    (error "No interface is running."))
  (prog1 (record-user-text text)
    (send-user-message (interface-engine interface) text)))

(defun keep-connected (interface)
  (loop until (interface-stopping-p interface)
        do (unless (cl-proteus/client:shell-connected-p)
             (handler-case (cl-proteus/client:connect-shell (interface-socket interface)
                                                            :name (interface-name interface))
               (error () nil)))
           (sleep 1)))

(defun start-interface (engine socket &key transcript-file name)
  "Show ENGINE's conversation in a window: connect this image to the shell
listening on SOCKET, and keep connecting while it is not, until
STOP-INTERFACE. The engine's messages go to the transcript; tools other
than the image's own are asked about in the window. TRANSCRIPT-FILE, if
given, keeps the transcript across images (see *TRANSCRIPT-FILE*); NAME is
how the shell shows this image. Return the interface, now *INTERFACE*."
  (when *interface*
    (stop-interface *interface*))
  (let ((interface (make-instance 'interface :engine engine
                                             :socket (uiop:native-namestring socket)
                                             :name name)))
    (when transcript-file
      (setf *transcript-file* (uiop:native-namestring transcript-file))
      (load-transcript *transcript-file*))
    (setf (interface-handler interface)
          (add-engine-handler engine (lambda (message)
                                       (mapc #'record-entry (message-entries message))))
          (interface-previous-permission-function interface) (engine-permission-function engine)
          (engine-permission-function engine) 'interface-permission
          *interface* interface
          (interface-keeper interface)
          (sb-thread:make-thread #'keep-connected :arguments (list interface)
                                                  :name "circle interface"))
    interface))

(defun stop-interface (&optional (interface *interface*))
  "Stop INTERFACE: disconnect from the shell, whose window stays, and give
the engine back its permission function."
  (when interface
    (setf (interface-stopping-p interface) t)
    (let ((keeper (interface-keeper interface)))
      (when (and keeper (not (eq keeper sb-thread:*current-thread*)))
        (ignore-errors (sb-thread:join-thread keeper :default nil :timeout 5))))
    (cl-proteus/client:disconnect-shell)
    (let ((engine (interface-engine interface)))
      (remove-engine-handler engine (interface-handler interface))
      (when (eq (engine-permission-function engine) 'interface-permission)
        (setf (engine-permission-function engine)
              (interface-previous-permission-function interface))))
    ;; Cards still waiting are denied now.
    (sb-thread:with-mutex (*cards-lock*)
      (loop for cell being the hash-values of *cards*
            unless (car cell) do (setf (car cell) :deny))
      (sb-thread:condition-broadcast *cards-changed*))
    (when (eq *interface* interface)
      (setf *interface* nil)))
  nil)

(defmacro with-interface ((var engine socket &rest options) &body body)
  "Run BODY with VAR bound to an interface showing ENGINE's conversation in
the window of the shell on SOCKET, as START-INTERFACE makes it with
OPTIONS, and stop the interface however BODY ends."
  `(let ((,var (start-interface ,engine ,socket ,@options)))
     (declare (ignorable ,var))
     (unwind-protect (progn ,@body)
       (stop-interface ,var))))
