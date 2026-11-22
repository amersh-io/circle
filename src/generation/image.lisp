;;;; Generation images: how one starts, how one replays a journal into the
;;;; next, and how the first is built.
;;;;
;;;; Every generation is an executable SBCL image with GENERATION-MAIN as
;;;; its toplevel. Run as DIRECTORY/N/image, it is generation N of
;;;; DIRECTORY and runs the agent. Run with --circle-replay JOURNAL
;;;; --circle-save FILE, it replays JOURNAL instead and, if that passes,
;;;; saves itself to FILE -- the next generation.

(in-package #:circle/generation)

(defvar *generation* nil
  "The number of the generation this image is: the one it started from, or
the last it froze. NIL in an image that did not start from one.")

(defvar *engine-options* '()
  "Initargs for the CLAUDE-ENGINE a generation starts, such as (:MODEL
\"claude-opus-5-5\" :EFFORT \"high\"); set when generation 0 is built and
carried by every generation after it.")

(defun utc-time ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour minute second)))

(defun say (stream control &rest arguments)
  (format stream "~&~?~%" control arguments)
  (finish-output stream))

;;; Where an image is

(defun image-place ()
  "The generations directory and number of this image, from where its
executable is: DIRECTORY/N/image. NIL if it is not there."
  (let* ((runtime sb-ext:*runtime-pathname*)
         (directory (and runtime (pathname-directory (pathname runtime))))
         (name (car (last directory))))
    (when (and (stringp name) (plusp (length name)) (every #'digit-char-p name))
      (values (make-pathname :directory (butlast directory) :name nil :type nil :version nil
                             :defaults (pathname runtime))
              (parse-integer name)))))

;;; Saving

(defun save-generation-image (pathname)
  "Save this image, which must run one thread only, as an executable
generation image at PATHNAME. Does not return."
  (let ((others (remove sb-thread:*current-thread* (sb-thread:list-all-threads))))
    (when others
      (error "Threads are still running: ~{~A~^, ~}. A generation is saved with one thread."
             (mapcar #'sb-thread:thread-name others))))
  (sb-ext:save-lisp-and-die (uiop:native-namestring pathname)
                            :executable t :toplevel #'generation-main))

;;; Replaying

(defun replay-failed (control &rest arguments)
  (say *standard-output* "REPLAY-FAILED ~?" control arguments)
  (sb-ext:exit :code 1 :abort t))

(defun replay (journal output)
  "Replay JOURNAL on this image: evaluate its changes in order, then run
every check; if all pass, print REPLAY-OK and save the image to OUTPUT."
  (let ((*replaying* t)
        (entries (handler-case (read-journal journal)
                   (error (condition) (replay-failed "cannot read the journal: ~A" condition))))
        (changes 0))
    (loop for entry in entries
          for index from 1
          do (handler-case
                 (ecase (getf entry :kind)
                   (:change (evaluate-source (getf entry :source) (getf entry :package))
                            (incf changes))
                   (:check (setf *checks* (append *checks* (list entry)))))
               (serious-condition (condition)
                 (replay-failed "change ~D, ~A: ~A" index (getf entry :source) condition))))
    (dolist (check *checks*)
      (let ((value (handler-case (evaluate-source (getf check :source) (getf check :package))
                     (serious-condition (condition)
                       (replay-failed "check ~A: ~A" (getf check :source) condition)))))
        (unless value
          (replay-failed "check ~A is false" (getf check :source)))))
    (handler-case
        (progn
          (say *standard-output* "REPLAY-OK ~D change~:P, ~D check~:P" changes (length *checks*))
          (save-generation-image output))
      (error (condition) (replay-failed "~A" condition)))))

;;; The toplevel

(defun argument (arguments flag)
  (second (member flag arguments :test #'string=)))

(defun generation-main ()
  "The toplevel of every generation image."
  (sb-ext:disable-debugger)
  (setf *random-state* (make-random-state t))
  (let ((arguments (rest sb-ext:*posix-argv*)))
    (handler-case
        (let ((journal (argument arguments "--circle-replay")))
          (if journal
              (replay journal (argument arguments "--circle-save"))
              (multiple-value-bind (directory number) (image-place)
                (sb-ext:exit :code (run-agent :directory directory :generation number
                                              :ready-file (argument arguments "--circle-ready"))))))
      (sb-sys:interactive-interrupt ()
        (sb-ext:exit :code 130 :abort t))
      (serious-condition (condition)
        (say *error-output* ";; circle: ~A" condition)
        (sb-ext:exit :code 1 :abort t)))))

;;; Generation 0

(defun dependency-name (spec)
  (cond ((or (stringp spec) (symbolp spec)) (asdf:coerce-name spec))
        ((and (consp spec) (eq (first spec) :version)) (dependency-name (second spec)))
        ((and (consp spec) (eq (first spec) :feature)) (dependency-name (third spec)))
        (t nil)))

(defun asd-files (names)
  "The .asd files of the systems NAMES and all they depend on, as this Lisp
finds them, each after those of its dependencies."
  (let ((seen (make-hash-table :test 'equal))
        (files '()))
    (labels ((walk (name)
               (unless (or (null name) (gethash name seen))
                 (setf (gethash name seen) t)
                 (let ((system (asdf:find-system name nil)))
                   (when system
                     (dolist (spec (append (asdf:system-defsystem-depends-on system)
                                           (asdf:system-depends-on system)))
                       (walk (dependency-name spec)))
                     (let ((file (asdf:system-source-file system)))
                       (when file (pushnew (namestring file) files :test #'string=))))))))
      (mapc #'walk names))
    (nreverse files)))

(defun setup-files ()
  "The Quicklisp or qlot setup file this Lisp was started with, in a list."
  (let* ((package (find-package "QL-SETUP"))
         (home (and package (find-symbol "*QUICKLISP-HOME*" package)))
         (file (and home (boundp home)
                    (probe-file (merge-pathnames "setup.lisp" (symbol-value home))))))
    (and file (list (namestring file)))))

(defparameter *build-script* "~
;;;; Written by circle/generation: build generation 0.
(require :asdf)
~{(load ~S)~%~}~
~{(asdf:load-asd ~S)~%~}~
(asdf:load-system \"circle\")
~{(asdf:load-system ~S)~%~}~
~{(load ~S)~%~}~
(setf circle/generation:*engine-options* '~S)
(circle/generation::save-generation-image ~S)
")

(defun make-first-generation (&key directory system load engine-options)
  "Build generation 0 in DIRECTORY, which must have none yet, and return 0.
A fresh Lisp loads circle, the system SYSTEM and the files LOAD -- the
agent's own code -- and saves itself. ENGINE-OPTIONS are the initargs of the
CLAUDE-ENGINE every generation starts, such as (:MODEL \"claude-opus-5-5\"
:EFFORT \"high\")."
  (let ((directory (uiop:ensure-directory-pathname (or directory *generations-directory*))))
    (when (generation-numbers directory)
      (error "~A has generations already." (uiop:native-namestring directory)))
    (let ((image (generation-file 0 "image" directory))
          (temporary (generation-file 0 "image.tmp" directory)))
      (ensure-directories-exist image)
      (uiop:with-temporary-file (:pathname script :type "lisp" :prefix "circle-build")
        (with-open-file (out script :direction :output :if-exists :supersede)
          (with-standard-io-syntax
            (let ((*package* (find-package :keyword))
                  (*print-readably* nil))
              (format out *build-script*
                      (setup-files)
                      (asd-files (remove nil (list "circle" system)))
                      (and system (list system))
                      (mapcar (lambda (file) (namestring (truename file))) (uiop:ensure-list load))
                      engine-options
                      (uiop:native-namestring temporary)))))
        (multiple-value-bind (output error-output code)
            (uiop:run-program (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                                    "--noinform" "--non-interactive" "--no-sysinit" "--no-userinit"
                                    "--load" (uiop:native-namestring script))
                              :output :string :error-output :string :ignore-error-status t)
          (unless (and (eql code 0) (probe-file temporary))
            (uiop:delete-directory-tree (generation-directory 0 directory)
                                        :validate t :if-does-not-exist :ignore)
            (error 'freeze-error :message "Building generation 0 failed."
                                 :output (concatenate 'string output error-output)))))
      (sb-posix:rename (uiop:native-namestring temporary) (uiop:native-namestring image))
      (write-manifest 0 (list :number 0 :parent nil :time (utc-time) :replay :base
                              :lisp (lisp-implementation-version))
                      directory)
      0)))
