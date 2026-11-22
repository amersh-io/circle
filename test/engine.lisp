;;;; The engine against a stand-in CLI (test/fake-claude.lisp) that speaks
;;;; the same protocol with canned turns.

(in-package #:circle/test)

(defvar *fake-state* nil
  "The directory the stand-in keeps its conversations in.")

(defun fake-command ()
  (list (uiop:native-namestring sb-ext:*runtime-pathname*)
        "--noinform" "--non-interactive" "--no-userinit"
        "--load" (root ".qlot/setup.lisp")
        "--load" (root "test/fake-claude.lisp")
        "--end-toplevel-options"))

(defun fake-engine (&rest initargs)
  "An engine, not started, that runs the stand-in CLI."
  (apply #'make-engine :command (fake-command) initargs))

(defvar cl-user::*circle-test-secret* nil)

(defun engine-checks ()
  (let ((engine (fake-engine))
        (heard '()))
    (add-engine-handler engine (lambda (message) (push (message-type message) heard)))
    (unwind-protect
         (progn
           (check "an engine starts and says it runs"
                  (and (eq engine (start-engine engine))
                       (engine-running-p engine)
                       (says (prin1-to-string engine) "running")))
           (check "starting a running engine is an error"
                  (handler-case (progn (start-engine engine) nil)
                    (engine-error () t)))
           (check "ask answers a turn's text, the result message second"
                  (multiple-value-bind (text result) (ask engine "hello" :timeout 30)
                    (and (equal "echo: hello" text) (equal "result" (message-type result)))))
           (check "the engine's session id is known after a turn"
                  (says (engine-session-id engine) "fake-"))
           (check "handlers hear a turn's messages before ask returns"
                  (progn (setf heard '())
                         (ask engine "again" :timeout 30)
                         (and (member "assistant" heard :test #'equal)
                              (member "result" heard :test #'equal))))
           (check "message-text reads a result's or an assistant message's text"
                  (let ((assistant (parse-json "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"tool_use\"},{\"type\":\"text\",\"text\":\"b\"}]}}")))
                    (and (equal "ab" (message-text assistant))
                         (equal "r" (message-text (json-object "type" "result" "result" "r"))))))
           (check "the engine calls the image's eval over MCP in process"
                  (says (ask engine "eval: (+ 40 2)" :timeout 30) "=> 42"))
           (check "eval sees what only this image holds"
                  (let ((secret (random 1000000)))
                    (setf cl-user::*circle-test-secret* secret)
                    (says (ask engine "eval: cl-user::*circle-test-secret*" :timeout 30)
                          (format nil "=> ~D" secret))))
           (check "an error in eval ends the turn in an error with its backtrace"
                  (handler-case (progn (ask engine "eval: (car 1)" :timeout 30) nil)
                    (turn-error (e) (says (json-get (turn-error-message e) "result") "Backtrace"))))
           (check "the engine lists the image's tools"
                  (says (ask engine "tools" :timeout 30) "eval"))
           (check "a tool defined while the engine runs is announced to it and listed"
                  (let ((before (count "control_response" heard :test #'equal)))
                    (define-tool circle-test-live () "Answers live." "live")
                    (unwind-protect
                         (and (loop repeat 100
                                    thereis (> (count "control_response" heard :test #'equal) before)
                                    do (sleep 0.05))
                              (says (ask engine "tools" :timeout 30) "circle_test_live"))
                      (remove-tool "circle_test_live"))))
           (check "by default a tool outside the image is denied, with the reason"
                  (says (ask engine "use bash" :timeout 30) "denied: circle allows only"))
           (check "a permission function decides other tools"
                  (let ((old (engine-permission-function engine)))
                    (setf (engine-permission-function engine)
                          (lambda (name input)
                            (declare (ignore input))
                            (if (equal name "Bash") :allow (values :deny "no"))))
                    (unwind-protect (equal "allowed" (ask engine "use bash" :timeout 30))
                      (setf (engine-permission-function engine) old))))
           (check "a failed turn signals turn-error"
                  (handler-case (progn (ask engine "fail" :timeout 30) nil)
                    (turn-error (e) (equal "it failed" (json-get (turn-error-message e) "result")))))
           (check "ask gives up after its timeout"
                  (handler-case (progn (ask engine "sleep" :timeout 0.5) nil)
                    (engine-timeout () t)))
           (check "the engine stops, keeping its session id"
                  (let ((id (engine-session-id engine)))
                    (sleep 5)        ; the stand-in finishes the sleeping turn
                    (stop-engine engine)
                    (and (not (engine-running-p engine))
                         (equal id (engine-session-id engine))
                         (says (prin1-to-string engine) "stopped"))))
           (check "asking a stopped engine is an error"
                  (handler-case (progn (ask engine "hello" :timeout 5) nil)
                    (engine-exited () t)))
           (check "starting it again continues the same conversation"
                  (progn (start-engine engine)
                         (says (ask engine "history" :timeout 30) "hello | again")))
           (check "a new engine resumes the conversation by its id"
                  (let ((id (engine-session-id engine)))
                    (stop-engine engine)
                    (with-engine (other (fake-engine :resume id))
                      (and (says (ask other "history" :timeout 30) "hello | again")
                           (equal id (engine-session-id other))))))
           (check "an engine that ends mid-turn signals engine-exited and stops running"
                  (progn (start-engine engine)
                         (handler-case (progn (ask engine "die" :timeout 30) nil)
                           (engine-exited () (not (engine-running-p engine)))))))
      (stop-engine engine)))
  (check "with-engine stops the engine however its body ends"
         (let ((engine (fake-engine)))
           (ignore-errors (with-engine (e engine) (error "out")))
           (not (engine-running-p engine))))
  (check "an engine whose CLI ends at once fails to start"
         (let ((engine (make-engine :command (list "/bin/sh" "-c" "exit 2" "sh"))))
           (handler-case (progn (start-engine engine) nil)
             (engine-exited () (not (engine-running-p engine)))))))
