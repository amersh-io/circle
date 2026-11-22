;;;; The window (macOS): a shell in this process, the agent's image as a
;;;; supervised generation in another, against the stand-in CLI. What is
;;;; typed in the window reaches the engine; tool calls and permission cards
;;;; show there; the image changes its own window; a new generation keeps
;;;; the same window. Windows stay transparent unless CIRCLE_TEST_VISIBLE is
;;;; set.

(in-package #:circle/test)

(defun socket-path (name)
  "A socket path short enough for a Unix-domain socket, under /tmp."
  (format nil "/tmp/circle-test-~D-~36R/~A.sock" (sb-posix:getpid)
          (random (expt 36 5) (make-random-state t)) name))

(defun page (shell script)
  "The value of SCRIPT in SHELL's page."
  (cl-iris:eval-js (circle/shell:shell-webview shell) script))

(defun page-text (shell)
  (or (ignore-errors (page shell "(document.getElementById('transcript') || {}).innerText || ''"))
      ""))

(defun wait-page (shell script &key (timeout 30) what)
  "Wait until SCRIPT is true in SHELL's page; on a timeout, say WHAT was
awaited and what the page shows."
  (or (loop repeat (* timeout 20)
            thereis (eq t (ignore-errors (page shell (format nil "!!(~A)" script))))
            do (sleep 0.05))
      (progn (format t "~&;; the page never showed ~A; it shows:~%~A~%" (or what script)
                     (page-text shell))
             nil)))

(defun wait-page-text (shell text &key (timeout 60))
  (wait-page shell (format nil "(document.getElementById('transcript') || {innerText: ''}).innerText.includes(~A)"
                           (to-json text))
             :timeout timeout :what (format nil "the text ~S" text)))

(defun type-in-window (shell text)
  "Type TEXT in SHELL's window and send it, as the person would."
  (page shell (format nil "document.getElementById('input').value = ~A;
document.getElementById('composer').requestSubmit(); 0" (to-json text))))

(defun image-registered-p ()
  (member "circle-send" (cl-proteus/shell:remote-commands) :test #'string=))

(defun wait-for-image (supervised generation)
  (and (wait-for-line supervised (format nil "generation ~D ready" generation) :timeout 120)
       (or (loop repeat 600 thereis (image-registered-p) do (sleep 0.1))
           (progn (format t "~&;; the image never registered its commands~%") nil))))

(defun window-checks ()
  (let* ((socket (socket-path "shell"))
         (directory (scratch-directory "window/"))
         (shell (circle/shell:start-shell socket :activate nil))
         (window (circle/shell:shell-window shell))
         (webview (circle/shell:shell-webview shell))
         (supervised nil))
    (unwind-protect
         (progn
           (make-first-generation :directory directory
                                  :engine-options (list :command (fake-command)))
           (setf supervised (start-supervised directory "--shell" socket))
           (check "window: the image connects to the shell and the window shows its chat"
                  (and (wait-for-image supervised 0)
                       (wait-page shell "document.getElementById('status').classList.contains('online')"
                                  :what "the image online")))
           (check "window: text typed in the window reaches the engine and its answer shows"
                  (progn (type-in-window shell "hello window")
                         (and (wait-page-text shell "echo: hello window")
                              (wait-page shell "document.querySelector('.entry.user').textContent === 'hello window'"
                                         :what "the person's own line"))))
           (check "window: a tool call shows folded, with its answer"
                  (progn (type-in-window shell "eval: (+ 40 2)")
                         (wait-page shell "[...document.querySelectorAll('details.tool')].some(d =>
  !d.open && d.querySelector('summary').textContent === 'lisp: eval'
  && (d.querySelector('pre.result') || {textContent: ''}).textContent.includes('=> 42'))"
                                    :what "a folded eval call with => 42")))
           (check "window: a permission card asks in the window, and allowing lets the tool run"
                  (progn (type-in-window shell "use bash")
                         (and (wait-page shell "document.querySelector('.card button.allow:not(:disabled)')"
                                         :what "a card to answer")
                              (page shell "document.querySelector('.card button.allow:not(:disabled)').click(); 0")
                              (wait-page-text shell "allowed")
                              (wait-page shell "document.querySelector('.card .answer').textContent === 'Allowed.'"
                                         :what "the card answered"))))
           (check "window: denying a card denies the tool, saying the person did"
                  (progn (type-in-window shell "use bash")
                         (and (wait-page shell "document.querySelector('.card button.deny:not(:disabled)')"
                                         :what "a second card")
                              (page shell "document.querySelector('.card button.deny:not(:disabled)').click(); 0")
                              (wait-page-text shell "denied: The person denied it in the window."))))
           (check "window: what is said in the terminal shows in the window too"
                  (and (exchange supervised "hello terminal" "echo: hello terminal")
                       (wait-page-text shell "echo: hello terminal")))
           (check "window: the image changes its own window, which reloads with its transcript"
                  (and (exchange supervised
                                 "keep: (setf (circle:interface-file \"ext.js\") \"document.body.insertAdjacentHTML('beforeend', '<div id=circle-ext>extended</div>')\")"
                                 "kept as a change")
                       (wait-page shell "document.getElementById('circle-ext')" :what "the image's change")
                       (wait-page-text shell "echo: hello window")
                       (not (cl-iris:window-closed-p window))
                       (not (cl-iris:webview-destroyed-p webview))))
           (check "window: after a freeze and a restart, the same window carries on with the change"
                  (and (exchange supervised "freeze" "Generation 1 frozen from generation 0")
                       (progn (page shell "window.circleMarker = 1; 0") t)
                       (exchange supervised ":restart" "generation 1 ready" :timeout 120)
                       (wait-for-image supervised 1)
                       (wait-page shell "document.getElementById('status').classList.contains('online')"
                                  :what "the new generation online")
                       ;; The view came back unchanged: the page was not reloaded.
                       (eql 1 (page shell "window.circleMarker || 0"))
                       (wait-page shell "document.getElementById('circle-ext')" :what "the change")
                       (progn (type-in-window shell "after restart")
                              (wait-page-text shell "echo: after restart"))
                       (not (cl-iris:window-closed-p window))))
           (check "window: the new generation goes on with the same conversation"
                  (progn (type-in-window shell "history")
                         (wait-page-text shell "hello window | eval: (+ 40 2)")))
           (check "window: the end of input ends the agent; the window stays"
                  (and (eql 0 (prog1 (finish-supervised supervised) (setf supervised nil)))
                       (wait-page shell "document.getElementById('status').classList.contains('offline')"
                                  :what "the image gone")
                       (not (cl-iris:window-closed-p window)))))
      (when supervised (finish-supervised supervised))
      (circle/shell:close-shell shell)
      (ignore-errors (uiop:delete-directory-tree
                      (uiop:pathname-directory-pathname socket) :validate t
                                                                :if-does-not-exist :ignore)))))

(defun shell-start-checks ()
  "The supervisor starts a shell of its own when none answers, and the same
shell serves the next generation."
  (let* ((socket (socket-path "own"))
         (directory (scratch-directory "own-shell/"))
         (supervised nil))
    (unwind-protect
         (progn
           (make-first-generation :directory directory
                                  :engine-options (list :command (fake-command)))
           (setf supervised (start-supervised directory "--shell" socket))
           (check "window: the supervisor starts the shell when none answers"
                  (or (and (wait-for-line supervised "starting the window" :timeout 30)
                           (wait-for-line supervised "generation 0 ready" :timeout 240)
                           (socket-answers-p socket))
                      (progn (format t "~&;; the supervisor said:~%~{;;   ~A~%~}~@[;; shell.log:~%~A~%~]"
                                     (last (output-lines supervised) 20)
                                     (ignore-errors (uiop:read-file-string
                                                     (merge-pathnames "shell.log" directory))))
                             nil)))
           (check "window: the next generation finds the same shell"
                  (let ((after (mark supervised)))
                    (and (exchange supervised ":restart" "generation 0 ready" :timeout 120)
                         (not (find-if (lambda (line) (search "starting the window" line))
                                       (nthcdr after (output-lines supervised))))
                         (socket-answers-p socket)))))
      (when supervised (finish-supervised supervised))
      (kill-matching socket)
      (ignore-errors (uiop:delete-directory-tree
                      (uiop:pathname-directory-pathname socket) :validate t
                                                                :if-does-not-exist :ignore)))))

(defun window-suite ()
  (let ((defaults cl-iris:*window-defaults*))
    ;; Test windows are transparent, so a run does not flash on the screen;
    ;; a shell the supervisor starts is told so too.
    (unless (uiop:getenv "CIRCLE_TEST_VISIBLE")
      (setf cl-iris:*window-defaults* (list* :alpha 0 defaults)
            (uiop:getenv "CIRCLE_TEST_HIDDEN_SHELL") "1"))
    (unwind-protect
         (cl-iris:with-application (:activation-policy :accessory)
           (window-checks)
           (claude-window-checks))
      (setf cl-iris:*window-defaults* defaults)))
  (shell-start-checks))

;;; Against the real CLI

(defun transcript-has-turn-end-after (directory text)
  "True if DIRECTORY's transcript ends a turn after the person's TEXT."
  (let ((file (merge-pathnames "transcript.jsonl" directory)))
    (and (probe-file file)
         (let* ((lines (uiop:read-file-lines file))
                (start (position-if (lambda (line) (and (search "\"user\"" line) (search text line)))
                                    lines :from-end t)))
           (and start (some (lambda (line) (search "\"turn-end\"" line))
                            (nthcdr (1+ start) lines)))))))

(defun claude-window-checks ()
  "With CIRCLE_TEST_CLAUDE=1: the model adds a button to its own window,
freezes it into a generation, and the next generation shows it."
  (when (uiop:getenv "CIRCLE_TEST_CLAUDE")
    (let* ((model (or (uiop:getenv "CIRCLE_TEST_MODEL") "claude-opus-5-5"))
           (effort (or (uiop:getenv "CIRCLE_TEST_EFFORT") "high"))
           (socket (socket-path "claude"))
           (directory (scratch-directory "claude-window/"))
           (workdir (scratch-directory "claude-window-cwd/"))
           (request "Add a button to your own window, with the id circle-count and the label Count, that counts how many times it is pressed and shows the count in its label: Count 1, Count 2 and so on. Change your window through the eval tool with keep set to true, as its description says. Then call freeze_generation. Reply with one short sentence.")
           (shell (circle/shell:start-shell socket :activate nil))
           (supervised nil))
      (unwind-protect
           (progn
             (make-first-generation :directory directory
                                    :engine-options (list :model model :effort effort
                                                          :directory (uiop:native-namestring workdir)
                                                          ;; Only the image's own tools.
                                                          :arguments '("--tools" "")))
             (setf supervised (start-supervised directory "--shell" socket))
             (check "claude: the model adds a working button to its own window"
                    (and (wait-for-image supervised 0)
                         (wait-page shell "document.getElementById('status').classList.contains('online')"
                                    :what "the image online")
                         (progn (type-in-window shell request) t)
                         (wait-page shell "document.getElementById('circle-count')" :timeout 900
                                                                                     :what "the button")
                         (progn (page shell "document.getElementById('circle-count').click(); 0")
                                (page shell "document.getElementById('circle-count').click(); 0")
                                (wait-page shell "document.getElementById('circle-count').textContent.includes('2')"
                                           :what "Count 2 after two presses"))))
             (check "claude: the button lasts into the next generation, in the same window"
                    (and (loop repeat 9000
                               thereis (and (eq :ok (manifest-get 1 :replay directory))
                                            (transcript-has-turn-end-after directory "circle-count"))
                               do (sleep 0.1))
                         (exchange supervised ":restart" "generation 1 ready" :timeout 180)
                         (wait-for-image supervised 1)
                         (progn (page shell "location.reload(); 0") t)
                         (wait-page shell "document.getElementById('status').classList.contains('online')"
                                    :what "generation 1 online")
                         (wait-page shell "document.getElementById('circle-count')" :what "the button again")
                         (search "circle-count" (uiop:read-file-string
                                                 (generation-file 1 "journal.lisp" directory))))))
        (when supervised (finish-supervised supervised))
        (circle/shell:close-shell shell)
        (ignore-errors (uiop:delete-directory-tree
                        (uiop:pathname-directory-pathname socket) :validate t
                                                                  :if-does-not-exist :ignore))))))
