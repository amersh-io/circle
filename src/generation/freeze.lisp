;;;; Freezing a generation.
;;;;
;;;;   1. The pending changes and checks are written to N/journal.lisp.
;;;;   2. The image this one is a generation of runs fresh with
;;;;      --circle-replay N/journal.lisp --circle-save N/image.tmp: it
;;;;      replays the journal, runs every check and, if all pass, saves
;;;;      itself to N/image.tmp.
;;;;   3. N/image.tmp becomes N/image in one rename.
;;;;   4. N/manifest.lisp is written, in one rename. Only now can the
;;;;      supervisor start generation N.
;;;;
;;;; A failure at any step removes N/; an interruption leaves N/ without a
;;;; manifest, which nothing starts and the next freeze numbers past.

(in-package #:circle/generation)

(define-condition freeze-error (error)
  ((message :initarg :message :reader freeze-error-message)
   (output :initarg :output :initform nil :reader freeze-error-output))
  (:report (lambda (condition stream)
             (format stream "~A~@[~%~A~]" (freeze-error-message condition)
                     (freeze-error-output condition))))
  (:documentation "Freezing a generation failed; FREEZE-ERROR-OUTPUT is what
the replay printed, or NIL."))

(setf (documentation 'freeze-error-output 'function)
      "What the replay of a failed freeze printed, or NIL.")

(defvar *replay-timeout* 600
  "Seconds a replay may take before the freeze gives up on it.")

(defvar *freeze-lock* (sb-thread:make-mutex :name "circle freeze"))

(defvar *agent-engine* nil
  "The engine RUN-AGENT started, while it runs.")

(defun last-lines (text count)
  (let ((lines (uiop:split-string (string-right-trim '(#\Newline) text) :separator '(#\Newline))))
    (format nil "~{~A~^~%~}" (last lines count))))

(defun run-replay (image journal output)
  "Run IMAGE to replay JOURNAL into OUTPUT; return what it printed and
whether it passed."
  (let* ((process (uiop:launch-program (list (uiop:native-namestring image)
                                             "--circle-replay" (uiop:native-namestring journal)
                                             "--circle-save" (uiop:native-namestring output))
                                       :input nil :output :stream :error-output :output))
         (text (make-string-output-stream))
         (reader (sb-thread:make-thread
                  (lambda ()
                    (let ((stream (uiop:process-info-output process)))
                      (loop for line = (read-line stream nil)
                            while line do (write-line line text))))
                  :name "circle replay output"))
         (deadline (+ (get-internal-real-time) (* *replay-timeout* internal-time-units-per-second))))
    (loop while (and (uiop:process-alive-p process) (< (get-internal-real-time) deadline))
          do (sleep 0.05))
    (when (uiop:process-alive-p process)
      (uiop:terminate-process process :urgent t))
    (let ((code (uiop:wait-process process)))
      (sb-thread:join-thread reader :default nil :timeout 10)
      (let ((printed (get-output-stream-string text)))
        (values printed
                (and (eql code 0)
                     (some (lambda (line) (uiop:string-prefix-p "REPLAY-OK" line))
                           (uiop:split-string printed :separator '(#\Newline)))
                     (probe-file output)
                     t))))))

(defun sync-file (pathname)
  (with-open-file (stream pathname :direction :input :element-type '(unsigned-byte 8))
    (sb-posix:fsync (sb-sys:fd-stream-fd stream))))

(defun freeze-generation (&key (directory *generations-directory*))
  "Make the changes and checks noted since this image's generation into a
new generation in DIRECTORY: replay them in a fresh process started from
this image's generation and, if every change and check passes there, keep
what that process saved. Return the new generation's number and a summary.
Signal FREEZE-ERROR if there is nothing to freeze or the replay fails; the
changes stay pending then."
  (sb-thread:with-mutex (*freeze-lock*)
    (let ((entries (pending-changes))
          (directory (uiop:ensure-directory-pathname directory)))
      (unless *generation*
        (error 'freeze-error :message "This image did not start from a generation; build one with MAKE-FIRST-GENERATION and run it."))
      (unless entries
        (error 'freeze-error :message "Nothing to freeze: no change has been kept since this generation."))
      (let* ((parent *generation*)
             (number (next-generation-number directory))
             (journal (generation-file number "journal.lisp" directory))
             (temporary (generation-file number "image.tmp" directory))
             (image (generation-file number "image" directory)))
        (write-journal journal entries number)
        (multiple-value-bind (printed passed)
            (run-replay (generation-file parent "image" directory) journal temporary)
          (unless passed
            (uiop:delete-directory-tree (generation-directory number directory)
                                        :validate t :if-does-not-exist :ignore)
            (error 'freeze-error :message "The replay did not pass; the changes stay pending."
                                 :output (last-lines printed 30)))
          (sync-file temporary)
          (sb-posix:rename (uiop:native-namestring temporary) (uiop:native-namestring image))
          (write-manifest number
                          (list :number number :parent parent :time (utc-time) :replay :ok
                                :changes (count :change entries :key (lambda (e) (getf e :kind)))
                                :checks (count :check entries :key (lambda (e) (getf e :kind)))
                                :session-id (or (and *agent-engine* (engine-session-id *agent-engine*))
                                                (read-session-id directory)))
                          directory)
          (forget-frozen entries)
          (setf *generation* number)
          (values number
                  (format nil "Generation ~D frozen from generation ~D: ~A"
                          number parent (last-lines printed 1))))))))

(define-tool freeze-generation ()
  "Freeze the changes kept so far into a new generation of this image. Keep a
change by calling eval with keep set to true; note a check that must hold by
evaluating (circle:note-check \"<forms>\"). A fresh process started from this
image's generation replays every kept change and runs every check; only if
all pass is it saved as the new generation, which the supervisor starts the
next time this image is started. Answers what happened."
  (handler-case (nth-value 1 (freeze-generation))
    (freeze-error (condition) (error 'tool-error :message (princ-to-string condition)))))
