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
;;;;
;;;; With a shell socket, the supervisor also keeps the agent's window up: it
;;;; starts the shell when nothing answers on that socket, and gives each
;;;; generation the socket with --circle-shell. The shell is a process of its
;;;; own, so the window outlives every generation.

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

(defvar *shell-start-timeout* 120
  "Seconds the supervisor waits for a shell it started to answer.")

(defun socket-answers-p (path)
  "True if something accepts connections on the Unix-domain socket PATH."
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (handler-case (progn (sb-bsd-sockets:socket-connect socket (uiop:native-namestring path))
                              t)
           (error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))))

(defun ensure-shell (socket command directory)
  "Start COMMAND with SOCKET as its argument, its output going to
DIRECTORY/shell.log, unless something answers on SOCKET already; wait until
it does. Return true if a shell answers."
  (or (socket-answers-p socket)
      (let ((log (merge-pathnames "shell.log" directory)))
        (note "starting the window")
        (handler-case
            (progn
              ;; Appending to a file that is not there fails, so make it.
              (with-open-file (out log :direction :output :if-exists :append
                                       :if-does-not-exist :create))
              (uiop:launch-program (append command (list (uiop:native-namestring socket)))
                                   :input nil :output log :if-output-exists :append
                                   :error-output :output))
          (error (condition)
            (note "cannot start the window: ~A" condition)
            (return-from ensure-shell nil)))
        (loop repeat (* 10 *shell-start-timeout*)
              when (socket-answers-p socket) do (return t)
              do (sleep 0.1)
              finally (note "the window did not answer on ~A; see ~A"
                            (uiop:native-namestring socket) (uiop:native-namestring log))))))

(defun command-line (arguments)
  "Supervise as scripts/circle asks: ARGUMENTS are the generations directory,
if given, --window (a shell socket in that directory) or --shell SOCKET,
then -- and the arguments for each generation. The shell is started with
the command in CIRCLE_SHELL_COMMAND. Return the exit code."
  (let* ((split (position "--" arguments :test #'string=))
         (own (subseq arguments 0 split))
         (rest (and split (subseq arguments (1+ split))))
         (directory nil)
         (window nil)
         (shell nil))
    (loop while own
          do (let ((argument (pop own)))
               (cond ((string= argument "--window") (setf window t))
                     ((string= argument "--shell") (setf shell (pop own)))
                     (t (setf directory argument)))))
    (when (and window (not shell))
      (setf shell (uiop:native-namestring (merge-pathnames "shell.sock" (directory-of directory)))))
    (supervise :directory directory :arguments rest :shell shell
               :shell-command (let ((command (uiop:getenv "CIRCLE_SHELL_COMMAND")))
                                (and command (plusp (length command)) (list command))))))

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

(defun supervise (&key directory arguments shell shell-command)
  "Start the newest generation in DIRECTORY that can be started, with
ARGUMENTS after its own, and keep one running until a generation ends with
exit code 0. Return the exit code to end with: 0, or 2 if there is no
generation left to start.

With SHELL, a socket path, each generation is given --circle-shell SHELL to
show its conversation in the window there; before each start, if nothing
answers on SHELL and SHELL-COMMAND (a program and its first arguments) is
given, it is started with SHELL as its last argument."
  (let ((directory (directory-of directory))
        (backoff *first-backoff*)
        (arguments (if shell
                       (append arguments (list "--circle-shell" (uiop:native-namestring shell)))
                       arguments)))
    (loop
      (let ((number (newest-startable directory)))
        (unless number
          (note "no generation in ~A can be started" (uiop:native-namestring directory))
          (return 2))
        (when (and shell shell-command)
          (ensure-shell shell shell-command directory))
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
