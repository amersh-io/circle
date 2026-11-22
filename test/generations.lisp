;;;; Generations and the supervisor: generations on disk, changes and checks,
;;;; and a whole agent under scripts/circle against the stand-in CLI --
;;;; keep, freeze, restart into the new generation, a replay that fails, an
;;;; interrupted freeze and a generation that cannot start.

(in-package #:circle/test)

(defun scratch-directory (name)
  "A fresh directory NAME under the suite's state directory."
  (let ((directory (uiop:ensure-directory-pathname (merge-pathnames name *fake-state*))))
    (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore)
    (ensure-directories-exist directory)))

(defun fake-generation (directory number &key manifest image failed)
  "Lay out generation NUMBER by hand: a manifest with REPLAY (:OK, :BASE or
NIL for none), an image file holding IMAGE (a shell script) if given, and a
start-failed mark if FAILED."
  (ensure-directories-exist (generation-file number "x" directory))
  (when manifest
    (write-manifest number (list :number number :replay manifest) directory))
  (when image
    (let ((file (generation-file number "image" directory)))
      (with-open-file (out file :direction :output :if-exists :supersede)
        (write-string image out))
      (sb-posix:chmod (uiop:native-namestring file) #o755)))
  (when failed
    (mark-start-failed number "by hand" directory)))

(defun store-checks ()
  (let ((directory (scratch-directory "store/")))
    (check "an empty directory has no generations and numbers the first 0"
           (and (null (generation-numbers directory))
                (eql 0 (next-generation-number directory))
                (null (newest-startable directory))))
    (fake-generation directory 0 :manifest :base :image "#!/bin/sh")
    (fake-generation directory 1 :image "#!/bin/sh")
    (fake-generation directory 2 :manifest :ok)
    (fake-generation directory 3 :manifest :ok :image "#!/bin/sh" :failed t)
    (fake-generation directory 4 :manifest :failed :image "#!/bin/sh")
    (check "only a generation with a passing manifest, its image and no failed start is startable"
           (and (generation-startable-p 0 directory)
                (not (generation-startable-p 1 directory))   ; no manifest: unfinished
                (not (generation-startable-p 2 directory))   ; no image
                (not (generation-startable-p 3 directory))   ; failed to start
                (not (generation-startable-p 4 directory))   ; its replay did not pass
                (equal '(0) (startable-generations directory))
                (eql 0 (newest-startable directory))))
    (check "the next generation is numbered past every one there, finished or not"
           (eql 5 (next-generation-number directory)))
    (check "a manifest and the session id read back as written, with no file left over"
           (progn
             (write-manifest 6 (list :number 6 :replay :ok :time "now" :session-id "abc") directory)
             (write-session-id "conversation-1" directory)
             (and (equal "now" (manifest-get 6 :time directory))
                  (equal "conversation-1" (read-session-id directory))
                  (equal '("manifest.lisp")
                         (mapcar #'file-namestring
                                 (uiop:directory-files (generation-directory 6 directory)))))))))

(defun change-checks ()
  (discard-pending-changes)
  (check "a noted change and check are pending, in order, as source"
         (progn
           (note-change "(defun circle-test-noted () 1)" :package "CL-USER")
           (note-check '(= 1 1) :package "CL-USER")
           (let ((pending (pending-changes)))
             (and (equal '(:change :check) (mapcar (lambda (e) (getf e :kind)) pending))
                  (equal "(defun circle-test-noted () 1)" (getf (first pending) :source))
                  (equal "COMMON-LISP-USER" (getf (first pending) :package))))))
  (check "a check that is false here is refused"
         (handler-case (progn (note-check "(= 1 2)" :package "CL-USER") nil)
           (error () (= 2 (length (pending-changes))))))
  (check "discarding forgets the pending changes"
         (progn (discard-pending-changes) (null (pending-changes))))
  (check "an image that did not start from a generation cannot freeze one"
         (handler-case (progn (freeze-generation :directory (scratch-directory "none/")) nil)
           (freeze-error (e) (says (princ-to-string e) "did not start from a generation")))))

;;; A supervised agent

(defclass supervised ()
  ((process :initarg :process :reader supervised-process)
   (lines :initform '() :accessor supervised-lines)
   (lock :initform (sb-thread:make-mutex) :reader supervised-lock)
   (reader :initform nil :accessor supervised-reader)))

(defun start-supervised (directory &rest arguments)
  "Run scripts/circle on DIRECTORY, with ARGUMENTS after it, with pipes to
its streams."
  (let* ((process (uiop:launch-program (list* (root "scripts/circle") (uiop:native-namestring directory)
                                              arguments)
                                       :input :stream :output :stream :error-output :output))
         (supervised (make-instance 'supervised :process process)))
    (setf (supervised-reader supervised)
          (sb-thread:make-thread
           (lambda ()
             (loop for line = (read-line (uiop:process-info-output process) nil)
                   while line
                   do (sb-thread:with-mutex ((supervised-lock supervised))
                        (push line (supervised-lines supervised)))))
           :name "circle test supervisor output"))
    supervised))

(defun output-lines (supervised)
  (sb-thread:with-mutex ((supervised-lock supervised))
    (reverse (supervised-lines supervised))))

(defun mark (supervised)
  "How many lines SUPERVISED has printed so far."
  (length (output-lines supervised)))

(defun wait-for-line (supervised text &key (after 0) (timeout 60))
  "Wait until a line SUPERVISED printed after the first AFTER lines contains
TEXT; return that line, or NIL after TIMEOUT seconds."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((line (find-if (lambda (line) (search text line))
                           (nthcdr after (output-lines supervised)))))
        (when line (return line)))
      (when (> (get-internal-real-time) deadline)
        (format t "~&;; no line with ~S; the last lines:~%~{;;   ~A~%~}" text
                (last (output-lines supervised) 15))
        (return nil))
      (sleep 0.05))))

(defun say-to (supervised line)
  (let ((stream (uiop:process-info-input (supervised-process supervised))))
    (write-line line stream)
    (finish-output stream)))

(defun exchange (supervised line text &key (timeout 60))
  "Send LINE and wait for a line containing TEXT in what follows."
  (let ((after (mark supervised)))
    (say-to supervised line)
    (wait-for-line supervised text :after after :timeout timeout)))

(defun finish-supervised (supervised)
  "Close SUPERVISED's input and return its exit code, killing it if it does
not end within a minute."
  (let ((process (supervised-process supervised)))
    (ignore-errors (close (uiop:process-info-input process)))
    (loop repeat 600 while (uiop:process-alive-p process) do (sleep 0.1))
    (when (uiop:process-alive-p process)
      (uiop:terminate-process process :urgent t))
    (prog1 (uiop:wait-process process)
      (sb-thread:join-thread (supervised-reader supervised) :default nil :timeout 10))))

(defun kill-matching (pattern)
  "Kill the processes whose command line contains PATTERN, by pid, as pgrep
lists them."
  (dolist (line (uiop:split-string (uiop:run-program (list "pgrep" "-f" pattern)
                                                     :output :string :ignore-error-status t)
                                   :separator '(#\Newline)))
    (let ((pid (parse-integer line :junk-allowed t)))
      (when (and pid (/= pid (sb-posix:getpid)))
        (ignore-errors (sb-posix:kill pid sb-posix:sigkill))))))

(defun answer-integer (line)
  "The integer after => in LINE."
  (parse-integer line :start (+ 2 (search "=>" line)) :junk-allowed t))

(defun agent-checks ()
  (let* ((directory (scratch-directory "agent/"))
         (journal-pattern (format nil "circle-replay ~A" (uiop:native-namestring directory)))
         (supervised nil))
    (check "make-first-generation builds generation 0 from source"
           (and (eql 0 (make-first-generation :directory directory
                                              :engine-options (list :command (fake-command))))
                (eq :base (manifest-get 0 :replay directory))
                (eql 0 (newest-startable directory))))
    (unwind-protect
         (progn
           (setf supervised (start-supervised directory))
           (check "the supervisor starts generation 0 and the agent answers"
                  (and (wait-for-line supervised "generation 0 ready" :timeout 120)
                       (exchange supervised "eval: (+ 40 2)" "=> 42")))
           (check "a change whose replay fails is not frozen and stays pending"
                  (and (exchange supervised "eval: (defparameter cl-user::*circle-live-only* 7)"
                                 "=> *CIRCLE-LIVE-ONLY*")
                       (exchange supervised
                                 "keep: (defparameter cl-user::*circle-from-live* cl-user::*circle-live-only*)"
                                 "kept as a change")
                       (exchange supervised "freeze" "REPLAY-FAILED")
                       (equal '(0) (generation-numbers directory))
                       (exchange supervised "eval: (length (circle:pending-changes))" "=> 1")
                       (exchange supervised "eval: (circle:discard-pending-changes)" "=> NIL")))
           (check "a kept change and a check freeze into generation 1"
                  (and (exchange supervised "keep: (defun cl-user::circle-triple (x) (* 3 x))"
                                 "kept as a change")
                       (exchange supervised
                                 "eval: (circle:note-check \"(= (circle-triple 2) 6)\" :package \"CL-USER\") t"
                                 "=> T")
                       (exchange supervised "freeze" "Generation 1 frozen from generation 0")
                       (eq :ok (manifest-get 1 :replay directory))
                       (eql 1 (manifest-get 1 :checks directory))
                       (eql 1 (newest-startable directory))
                       (search "circle-triple"
                               (uiop:read-file-string (generation-file 1 "journal.lisp" directory)))))
           (check "the agent restarts into generation 1, which has the change"
                  (and (exchange supervised ":restart" "generation 1 ready" :timeout 120)
                       (exchange supervised "eval: (cl-user::circle-triple 14)" "=> 42")))
           (check "generation 1 holds what its replay made, not the old image's other state"
                  (exchange supervised
                            "eval: (list circle:*generation* (boundp 'cl-user::*circle-live-only*))"
                            "=> (1 NIL)"))
           (check "generation 1 resumes the same conversation"
                  (and (equal (read-session-id directory) (manifest-get 1 :session-id directory))
                       (exchange supervised "history" "keep: (defun cl-user::circle-triple")))
           (check "an image killed while freezing leaves no generation the supervisor picks"
                  (let ((pid (answer-integer (exchange supervised "eval: (sb-posix:getpid)" "=> "))))
                    (and (exchange supervised "eval: (make-package \"CIRCLE-TEST-LIVE\") t" "=> T")
                         ;; Replayed in a fresh process, which lacks the package, it waits.
                         (exchange supervised
                                   "keep: (unless (find-package \"CIRCLE-TEST-LIVE\") (sleep 120)) t"
                                   "kept as a change")
                         (let ((after (mark supervised)))
                           (say-to supervised "freeze")
                           (loop repeat 600
                                 until (probe-file (generation-file 2 "journal.lisp" directory))
                                 do (sleep 0.1))
                           (sleep 1)
                           (sb-posix:kill pid sb-posix:sigkill)
                           (and (wait-for-line supervised "generation 1 ended with exit code 137"
                                               :after after :timeout 60)
                                (wait-for-line supervised "generation 1 ready" :after after :timeout 120)
                                (not (eql pid (answer-integer
                                               (exchange supervised "eval: (sb-posix:getpid)" "=> "))))))
                         (equal '(0 1 2) (generation-numbers directory))
                         (null (read-manifest 2 directory))
                         (eql 1 (newest-startable directory)))))
           (check "a generation that fails to start is marked, and the one before it starts"
                  (progn
                    (fake-generation directory 3 :manifest :ok :image (format nil "#!/bin/sh~%exit 3~%"))
                    (let ((after (mark supervised)))
                      (say-to supervised ":restart")
                      (and (wait-for-line supervised "generation 3 failed to start" :after after
                                                                                   :timeout 120)
                           (wait-for-line supervised "generation 1 ready" :after after :timeout 120)
                           (start-failed-p 3 directory)
                           (eql 1 (newest-startable directory))))))
           (check "the end of input ends the agent and the supervisor with 0"
                  (eql 0 (prog1 (finish-supervised supervised) (setf supervised nil)))))
      (when supervised (finish-supervised supervised))
      (kill-matching journal-pattern))))

(defun generations-suite ()
  (store-checks)
  (change-checks)
  (agent-checks))
