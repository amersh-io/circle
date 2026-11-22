;;;; The engine against the real Claude Code CLI. These run only with
;;;; CIRCLE_TEST_CLAUDE=1, since they need the CLI installed and signed in
;;;; and cost a little. CIRCLE_TEST_MODEL picks the model (haiku by default).

(in-package #:circle/test)

(defvar cl-user::*circle-claude-secret* nil)

(defun claude-checks ()
  (when (uiop:getenv "CIRCLE_TEST_CLAUDE")
    (let* ((directory (uiop:ensure-directory-pathname
                       (merge-pathnames "claude/" *fake-state*)))
           (model (or (uiop:getenv "CIRCLE_TEST_MODEL") "haiku"))
           (engine (make-engine :model model :directory (ensure-directories-exist directory)))
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
                      (with-engine (again (make-engine :model model :resume id :directory directory))
                        (and (says (ask again "What number did you reply with when you read the variable? Reply with only the number."
                                        :timeout 180)
                                   (princ-to-string secret))
                             (equal id (engine-session-id again)))))))
        (stop-engine engine)))))
