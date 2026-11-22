;;;; Show a conversation in a window (macOS), without generations.
;;;;
;;;;   scripts/circle-shell /tmp/circle-example/shell.sock &      # the window
;;;;   sbcl --load .qlot/setup.lisp --eval '(asdf:load-system "circle")' \
;;;;        --load examples/window.lisp
;;;;
;;;; The image holds no window: it connects to the shell on the socket and
;;;; sends it the page. With no shell there it still runs and prints the
;;;; transcript; a shell started meanwhile is connected to within a second.

(in-package #:cl-user)

(let ((socket (or (uiop:getenv "CIRCLE_EXAMPLE_SOCKET") "/tmp/circle-example/shell.sock")))
  (circle:with-engine (engine (circle:make-engine :model "claude-opus-5-5" :effort "high"))
    (circle:with-interface (interface engine socket :name "example")
      ;; The image changes its own window: ext.js loads after the chat.
      (setf (circle:interface-file "ext.js") "document.title = 'circle example';")
      (circle:interface-send "What is the sum of the squares of 3 and 4?")
      (loop repeat 600
            until (find "turn-end" (circle:transcript-entries)
                        :key (lambda (entry) (gethash "kind" entry)) :test #'equal)
            do (sleep 0.1))
      (loop for entry across (circle:transcript-entries)
            do (format t "~A: ~A~%" (gethash "kind" entry) (or (gethash "text" entry) ""))))))
