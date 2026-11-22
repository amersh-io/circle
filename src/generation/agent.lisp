;;;; The agent a generation runs: the engine, resumed, and a line-by-line
;;;; conversation on the standard streams.

(in-package #:circle/generation)

(defun touch (pathname)
  (with-open-file (out pathname :direction :output :if-exists :supersede)
    (write-line "ready" out)))

(defun keep-session-id (engine directory)
  "A handler that records ENGINE's session id in DIRECTORY when it changes."
  (let ((known (read-session-id directory)))
    (lambda (message)
      (declare (ignore message))
      (let ((id (engine-session-id engine)))
        (when (and (stringp id) (not (equal id known)))
          (setf known id)
          (write-session-id id directory))))))

(defun run-agent (&key directory generation ready-file
                    (input *standard-input*) (output *standard-output*))
  "Run the agent of GENERATION in DIRECTORY: start the engine with
*ENGINE-OPTIONS*, resuming the conversation DIRECTORY records, write
READY-FILE once it runs, then answer each line of INPUT on OUTPUT. A line
:restart ends with +EXIT-RESTART+, so the supervisor starts the newest
generation; :freeze freezes one; the end of INPUT ends with 0. Return the
exit code."
  (let* ((directory (uiop:ensure-directory-pathname (or directory *generations-directory*)))
         (engine (apply #'make-instance 'claude-engine
                        :mcp-servers (list *tool-server*)
                        :resume (read-session-id directory)
                        *engine-options*)))
    (setf *generations-directory* directory
          *generation* generation
          *agent-engine* engine)
    (add-engine-handler engine (keep-session-id engine directory))
    (start-engine engine)
    (unwind-protect
         (progn
           (when ready-file (touch ready-file))
           (say output "circle: generation ~A ready" generation)
           (loop
             (let ((line (read-line input nil)))
               (cond ((null line) (return 0))
                     ((string= (string-trim " " line) "") nil)
                     ((string= (string-trim " " line) ":restart") (return +exit-restart+))
                     ((string= (string-trim " " line) ":freeze")
                      (say output "~A" (handler-case (nth-value 1 (freeze-generation))
                                         (freeze-error (condition) (princ-to-string condition)))))
                     (t
                      (handler-case (say output "~A" (ask engine line))
                        (engine-exited (condition)
                          (say *error-output* ";; circle: ~A" condition)
                          (return 1))
                        (engine-error (condition)
                          (say output "circle: ~A" condition))))))))
      (ignore-errors (stop-engine engine))
      (setf *agent-engine* nil))))
