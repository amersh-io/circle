;;;; The engine against the real Claude Code CLI. These run only with
;;;; CIRCLE_TEST_CLAUDE=1, since they need the CLI installed and signed in
;;;; and cost a little. CIRCLE_TEST_MODEL and CIRCLE_TEST_EFFORT pick the model
;;;; and effort (claude-opus-5-5 and high by default).

(in-package #:circle/test)

(defvar cl-user::*circle-claude-secret* nil)

(defun claude-checks ()
  (when (uiop:getenv "CIRCLE_TEST_CLAUDE")
    (let* ((directory (uiop:ensure-directory-pathname
                       (merge-pathnames "claude/" *fake-state*)))
           (model (or (uiop:getenv "CIRCLE_TEST_MODEL") "claude-opus-5-5"))
           (effort (or (uiop:getenv "CIRCLE_TEST_EFFORT") "high"))
           (engine (make-engine :model model :effort effort :directory (ensure-directories-exist directory)))
           (secret (random 1000000)))
      (setf cl-user::*circle-claude-secret* secret)
      (unwind-protect
           (progn
             (check "claude: one turn round trip"
                    (progn (start-engine engine)
                           (says (string-upcase (ask engine "Reply with the single word PONG."
                                                     :timeout 180))
                                 "PONG")))
             (check "claude: the model calls eval in this image"
                    (says (ask engine "Use the mcp__lisp__eval tool to read the value of cl-user::*circle-claude-secret* and reply with only that number."
                               :timeout 180)
                          (princ-to-string secret)))
             (check "claude: a tool defined while running is offered on the next turn"
                    (progn
                      (define-tool circle-claude-word () "Answers the word of the day." "RHUBARB")
                      (unwind-protect
                           (says (string-upcase
                                  (ask engine "Call the mcp__lisp__circle_claude_word tool and reply with only the word it gives."
                                       :timeout 180))
                                 "RHUBARB")
                        (remove-tool "circle_claude_word"))))
             (check "claude: after the engine restarts, the same conversation resumes"
                    (let ((id (engine-session-id engine)))
                      (stop-engine engine)
                      (with-engine (again (make-engine :model model :effort effort :resume id :directory directory))
                        (and (says (ask again "What number did you reply with when you read the variable? Reply with only the number."
                                        :timeout 180)
                                   (princ-to-string secret))
                             (equal id (engine-session-id again)))))))
        (stop-engine engine))
      (claude-generation-checks model effort directory))))

(defun claude-generation-checks (model effort directory)
  "The model keeps a change, freezes a generation, and the supervisor starts
it; the resumed conversation uses the change."
  (let ((generations (scratch-directory "claude-generations/"))
        (addend (+ 1000 (random 9000)))
        (supervised nil))
    (make-first-generation :directory generations
                           :engine-options (list :model model :effort effort
                                                 :directory (uiop:native-namestring directory)))
    (unwind-protect
         (progn
           (setf supervised (start-supervised generations))
           (check "claude: the model keeps a change and freezes a generation"
                  (and (wait-for-line supervised "generation 0 ready" :timeout 180)
                       (progn
                         (say-to supervised
                                 (format nil "Call the mcp__lisp__eval tool with keep set to true to evaluate (defun cl-user::circle-plus-secret (x) (+ x ~D)). Then call the mcp__lisp__freeze_generation tool. Reply with what freeze_generation answered."
                                         addend))
                         ;; Read once that turn is over, :restart starts the newest generation.
                         (exchange supervised ":restart" "generation 1 ready" :timeout 600))
                       (eq :ok (manifest-get 1 :replay generations))))
           (check "claude: the next generation has the change, in the same conversation"
                  (and (exchange supervised
                                 "Call the mcp__lisp__eval tool to evaluate (cl-user::circle-plus-secret 1) and reply with only the number it returns."
                                 (princ-to-string (1+ addend)) :timeout 300)
                       (exchange supervised
                                 "What number did the function you defined before add to its argument? Reply with only the number."
                                 (princ-to-string addend) :timeout 300))))
      (when supervised (finish-supervised supervised)))))
