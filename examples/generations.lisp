;;;; Build generation 0 of an agent in a fresh directory, start it once, and
;;;; say how to keep one running.
;;;;
;;;;   sbcl --load .qlot/setup.lisp --eval '(asdf:load-system "circle")' \
;;;;        --load examples/generations.lisp
;;;;
;;;; Generation 0 holds circle and, given :SYSTEM or :LOAD, your agent's own
;;;; code. It runs the engine with the options given here, resuming the
;;;; conversation the directory records.

(in-package #:cl-user)

(let ((directory (uiop:ensure-directory-pathname
                  (merge-pathnames (format nil "circle-example-~36R/" (random (expt 36 8)
                                                                               (make-random-state t)))
                                   (uiop:temporary-directory)))))
  (unwind-protect
       (progn
         (circle:make-first-generation
          :directory directory
          :engine-options (list :model "claude-opus-5-5" :effort "high"
                                :command circle:*claude-command*))
         (format t "Generation 0 is in ~A~%" (uiop:native-namestring directory))
         ;; Run it once, as the supervisor would, with one line of input.
         (format t "~A" (uiop:run-program
                         (list (uiop:native-namestring (circle:generation-file 0 "image" directory)))
                         :input (make-string-input-stream (format nil "Say hello in five words.~%"))
                         :output :string))
         (format t "Keep one running with: scripts/circle ~A~%" (uiop:native-namestring directory)))
    (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore)))
