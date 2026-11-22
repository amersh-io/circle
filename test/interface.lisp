;;;; The image's side of its window, without a window: what it loads, the
;;;; transcript made from the engine's messages, the page's files and
;;;; commands, permission cards, and a conversation through INTERFACE-SEND
;;;; against the stand-in CLI.

(in-package #:circle/test)

(defun fresh-lisp-output (&rest forms)
  "Run FORMS, printed, in a fresh Lisp that has loaded circle; return what it
printed and its exit code."
  (multiple-value-bind (output error-output code)
      (uiop:run-program
       (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                     "--noinform" "--non-interactive" "--no-userinit"
                     "--load" (root ".qlot/setup.lisp")
                     "--eval" (format nil "(asdf:load-asd ~S)" (root "circle.asd"))
                     "--eval" "(asdf:load-system \"circle\")")
               (loop for form in forms
                     collect "--eval"
                     collect (with-standard-io-syntax (prin1-to-string form))))
       :output :string :error-output :string :ignore-error-status t)
    (values (concatenate 'string output error-output) code)))

(defun parse (text)
  (parse-json text))

(defun kinds (entries)
  (map 'list (lambda (entry) (gethash "kind" entry)) entries))

(defun interface-unit-checks ()
  (check "the image side loads no window code: no cl-iris, no CFFI"
         (multiple-value-bind (output code)
             (fresh-lisp-output '(format t "~&LOADED ~A ~A~%"
                                  (and (find-package "CL-IRIS") t) (and (find-package "CFFI") t)))
           (and (eql 0 code) (says output "LOADED NIL NIL"))))
  (check "an assistant message gives its text and tool calls as entries"
         (let ((entries (message-entries
                         (parse "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Let me look.\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"mcp__lisp__eval\",\"input\":{\"code\":\"(+ 1 2)\"}}]}}"))))
           (and (equal '("assistant" "tool") (kinds entries))
                (equal "Let me look." (gethash "text" (first entries)))
                (equal "t1" (gethash "id" (second entries)))
                (equal "(+ 1 2)" (gethash "code" (parse (gethash "input" (second entries))))))))
  (check "a tool result and the end of a turn become entries; other messages none"
         (let ((result (message-entries
                        (parse "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":[{\"type\":\"text\",\"text\":\"=> 3\"}],\"is_error\":false}]}}")))
               (failed (message-entries
                        (parse "{\"type\":\"result\",\"is_error\":true,\"result\":\"it failed\"}")))
               (system (message-entries (parse "{\"type\":\"system\",\"subtype\":\"init\"}"))))
           (and (equal '("tool-result") (kinds result))
                (equal "t1" (gethash "toolUseId" (first result)))
                (equal "=> 3" (gethash "text" (first result)))
                (eq nil (gethash "isError" (first result)))
                (equal '("turn-end") (kinds failed))
                (eq t (gethash "isError" (first failed)))
                (equal "it failed" (gethash "text" (first failed)))
                (null system))))
  (clear-transcript)
  (check "recorded entries are numbered, sent to pages, and read back from an index"
         (let* ((heard '())
                (listener (cl-proteus/core:listen-event
                           "circle-entry" (lambda (entry) (push (gethash "index" entry) heard)))))
           (unwind-protect
                (progn
                  (record-user-text "one")
                  (record-user-text "two")
                  (and (equal '(1 0) heard)
                       (equal '("two") (map 'list (lambda (e) (gethash "text" e))
                                            (transcript-entries 1)))
                       (equalp (transcript-entries 0)
                               (cl-proteus/core:call-command
                                "circle-transcript" (json-object "from" 0)))))
             (cl-proteus/core:unlisten-event listener))))
  (clear-transcript)
  (check "the transcript file keeps the entries for the next image"
         (let ((file (merge-pathnames "transcript.jsonl" (scratch-directory "transcript/"))))
           (let ((*transcript-file* (uiop:native-namestring file)))
             (record-user-text "kept")
             (clear-transcript)
             (circle/interface::load-transcript *transcript-file*)
             (prog1 (equal '("kept") (map 'list (lambda (e) (gethash "text" e))
                                          (transcript-entries)))
               (clear-transcript)))))
  (check "the window's page is the view circle, with ext.js and ext.css empty"
         (and (subsetp '("index.html" "chat.js" "chat.css" "ext.js" "ext.css")
                       (interface-files) :test #'string=)
              (equal "" (interface-file "ext.js"))
              (says (interface-file "index.html") "ext.js")
              (cl-proteus/core:find-view *interface-view*)))
  (check "setting a file of the page keeps the others and tells the shell"
         (let* ((heard nil)
                (cl-proteus/core:*views-changed-hook*
                  (list (lambda (view) (setf heard (cl-proteus/core:view-name view)))))
                (before (interface-files)))
           (unwind-protect
                (progn
                  (setf (interface-file "ext.css") "body { margin: 1px; }")
                  (and (equal "circle" heard)
                       (equal "body { margin: 1px; }" (interface-file "ext.css"))
                       (equal before (interface-files))))
             (setf (interface-file "ext.css") ""))))
  (check "a permission card waits for its answer from the page"
         (let* ((decision nil)
                (thread (sb-thread:make-thread
                         (lambda () (setf decision (circle/interface::ask-window "Bash" (json-object)))))))
           (loop repeat 100
                 until (find "permission" (kinds (transcript-entries)) :test #'equal)
                 do (sleep 0.05))
           (let ((card (find "permission" (transcript-entries) :key (lambda (e) (gethash "kind" e))
                                                                 :test #'equal)))
             (and card
                  (eq t (cl-proteus/core:call-command
                         "circle-answer" (json-object "id" (gethash "id" card) "allow" t)))
                  (progn (sb-thread:join-thread thread :timeout 10) (eq :allow decision))
                  (eq t (gethash "allow" (aref (transcript-entries) (1- (length (transcript-entries))))))))))
  (check "a permission card nobody answers denies, saying so"
         (let ((*permission-timeout* 0.2))
           (multiple-value-bind (decision reason) (circle/interface::ask-window "Bash" (json-object))
             (and (eq :deny decision) (says reason "No answer in the window")))))
  (check "without a window, the interface's permission function denies other tools"
         (let ((circle/engine:*engine* (fake-engine)))
           (eq :deny (interface-permission "Bash" (json-object)))))
  (clear-transcript)
  (check "text sent through the interface reaches the engine and the answer the transcript"
         (let ((engine (fake-engine))
               (socket (format nil "/tmp/circle-test-none-~D.sock" (sb-posix:getpid))))
           (unwind-protect
                (progn
                  (start-engine engine)
                  (start-interface engine socket :name "test")
                  (cl-proteus/core:call-command "circle-send" (json-object "text" "eval: (+ 1 2)"))
                  (and (loop repeat 200
                             thereis (find "turn-end" (kinds (transcript-entries)) :test #'equal)
                             do (sleep 0.05))
                       (equal '("user" "tool" "tool-result" "assistant" "turn-end")
                              (kinds (transcript-entries)))
                       (says (gethash "text" (aref (transcript-entries) 2)) "=> 3")
                       (not (interface-connected-p))
                       (eq 'interface-permission (engine-permission-function engine))))
             (stop-interface)
             (stop-engine engine)
             (clear-transcript))))
  (check "stopping the interface gives the engine back its permission function"
         (let ((engine (fake-engine)))
           (start-interface engine "/tmp/circle-test-none.sock")
           (stop-interface)
           (and (null *interface*) (eq 'allow-own-tools (engine-permission-function engine))))))
