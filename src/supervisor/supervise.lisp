;;;; The supervisor: start the newest generation that can be started, and
;;;; start one again when it ends.
;;;;
;;;; A generation tells that it has started by writing the file the
;;;; supervisor names after --circle-ready. Ending before that is a failure
;;;; to start: the generation is marked and the one before it is started.
;;;; Ending after it is a crash, unless the exit code says otherwise: 0 is
;;;; the end, +EXIT-RESTART+ asks to be started again at once (the newest
;;;; generation, which may be one it has just made), anything else is
;;;; started again after a pause that doubles each time, up to
;;;; *MOST-BACKOFF* seconds.

(in-package #:circle/supervisor)

(defconstant +exit-restart+ 75
  "The exit code with which a generation asks the supervisor to start the
newest generation now.")

(defvar *first-backoff* 1
  "Seconds the supervisor waits before starting a generation again after its
first crash.")

(defvar *most-backoff* 30
  "The longest the supervisor waits, in seconds, before starting a
generation again after a crash.")

(defvar *steady-seconds* 60
  "A generation that ran this long before crashing is started again after
the first pause, not a longer one.")

(defun note (control &rest arguments)
  (format *error-output* "~&;; circle: ~?~%" control arguments)
  (finish-output *error-output*))

(defun command-line (arguments)
  "Supervise as scripts/circle asks: ARGUMENTS are the generations directory,
if given, then -- and the arguments for each generation. Return the exit
code."
  (let* ((split (position "--" arguments :test #'string=))
         (own (subseq arguments 0 split))
         (rest (and split (subseq arguments (1+ split)))))
    (supervise :directory (first own) :arguments rest)))

(defun run-generation (number directory arguments ready-file)
  "Run generation NUMBER's image with ARGUMENTS on this process's standard
streams; return its exit code, or 128 plus the signal that ended it."
  (let ((process (sb-ext:run-program (uiop:native-namestring
                                      (generation-file number "image" directory))
                                     (list* "--circle-ready" (uiop:native-namestring ready-file)
                                            arguments)
                                     :input t :output t :error t :wait t)))
    (if (eq (sb-ext:process-status process) :signaled)
        (+ 128 (sb-ext:process-exit-code process))
        (sb-ext:process-exit-code process))))

(defun supervise (&key directory arguments)
  "Start the newest generation in DIRECTORY that can be started, with
ARGUMENTS after its own, and keep one running until a generation ends with
exit code 0. Return the exit code to end with: 0, or 2 if there is no
generation left to start."
  (let ((directory (directory-of directory))
        (backoff *first-backoff*))
    (loop
      (let ((number (newest-startable directory)))
        (unless number
          (note "no generation in ~A can be started" (uiop:native-namestring directory))
          (return 2))
        (let ((ready-file (merge-pathnames (format nil "ready-~D" (sb-posix:getpid)) directory))
              (started (get-internal-real-time)))
          (uiop:delete-file-if-exists ready-file)
          (note "starting generation ~D" number)
          (let* ((code (run-generation number directory arguments ready-file))
                 (ready (probe-file ready-file))
                 (seconds (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
            (uiop:delete-file-if-exists ready-file)
            (cond ((and ready (eql code 0))
                   (note "generation ~D ended" number)
                   (return 0))
                  ((and ready (eql code +exit-restart+))
                   (note "generation ~D asked to be started again" number)
                   (setf backoff *first-backoff*))
                  ((not ready)
                   (note "generation ~D failed to start (exit code ~D)" number code)
                   (mark-start-failed number (format nil "exited with code ~D before it was ready"
                                                     code)
                                      directory))
                  (t
                   (when (>= seconds *steady-seconds*)
                     (setf backoff *first-backoff*))
                   (note "generation ~D ended with exit code ~D; starting again in ~D s"
                         number code backoff)
                   (sleep backoff)
                   (setf backoff (min *most-backoff* (* 2 backoff)))))))))))
