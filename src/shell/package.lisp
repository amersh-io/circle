;;;; circle/shell -- the process that owns the agent's window (macOS).
;;;;
;;;; A cl-proteus shell: it listens on a socket for the agent's image and
;;;; shows, in one window, the view "circle" that image sends. It holds none
;;;; of the agent; images come and go -- a crash, a new generation -- while
;;;; the window stays.

(defpackage #:circle/shell
  (:use #:cl)
  (:export #:start-shell
           #:close-shell
           #:run-shell
           #:shell
           #:shell-window
           #:shell-webview
           #:shell-server
           #:*waiting-page*))
