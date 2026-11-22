;;;; The shell: a socket for the agent's image and one window showing its page.

(in-package #:circle/shell)

(defparameter *waiting-page*
  "<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><title>circle</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 -apple-system, sans-serif; display: grid; place-items: center;
         height: 100vh; margin: 0; color: #6b6a64; }
</style></head>
<body><p>Waiting for the agent's image to connect.</p></body></html>"
  "The page the window shows until an image sends its own view \"circle\".")

(defclass shell ()
  ((server :initarg :server :reader shell-server
           :documentation "The cl-proteus shell server listening for the image.")
   (window :initarg :window :reader shell-window
           :documentation "The window, a cl-iris WINDOW.")
   (webview :initarg :webview :reader shell-webview
            :documentation "The window's webview, showing the view \"circle\"."))
  (:documentation "A running shell, made by START-SHELL."))

(setf (documentation 'shell-server 'function)
      "The cl-proteus server of a SHELL, listening for the agent's image."
      (documentation 'shell-window 'function)
      "The window of a SHELL."
      (documentation 'shell-webview 'function)
      "The webview of a SHELL's window.")

(defmethod print-object ((shell shell) stream)
  (print-unreadable-object (shell stream :type t)
    (format stream "~A" (cl-proteus/shell:shell-server-path (shell-server shell)))))

(defun start-shell (socket &rest window-options &key (title "circle") (width 760) (height 820)
                                                  &allow-other-keys)
  "Listen for the agent's image on SOCKET and open the window that shows
its page, the view \"circle\" -- a page that says the window waits for the
image, until the image sends its own. Call it while the cl-iris application
runs. WINDOW-OPTIONS go to cl-iris's MAKE-WINDOW. Return the SHELL."
  (unless (cl-proteus/core:find-view "circle")
    (cl-proteus/core:ensure-view "circle" :files (list "index.html" *waiting-page*)))
  (let* ((server (cl-proteus/shell:serve-shell socket))
         (window (handler-bind ((error (lambda (condition)
                                         (declare (ignore condition))
                                         (cl-proteus/shell:stop-shell server))))
                   (apply #'cl-iris:make-window :title title :width width :height height
                          :center t
                          (loop for (key value) on window-options by #'cddr
                                unless (member key '(:title :width :height))
                                  append (list key value)))))
         (webview (cl-proteus/shell:make-app-webview window :view "circle")))
    (make-instance 'shell :server server :window window :webview webview)))

(defun close-shell (shell)
  "Close SHELL's window and stop listening; an image connected to it is
dropped."
  (ignore-errors (cl-proteus/shell:destroy-app-webview (shell-webview shell)))
  (ignore-errors (cl-iris:close-window (shell-window shell)))
  (cl-proteus/shell:stop-shell (shell-server shell))
  nil)

(defun run-shell (socket &rest window-options &key (activation-policy :regular)
                                                &allow-other-keys)
  "Run the shell on this thread, the main thread, until its window is
closed: listen on SOCKET and show the image's page, as START-SHELL does
with WINDOW-OPTIONS. ACTIVATION-POLICY is cl-iris's: :REGULAR shows the
shell in the Dock."
  (let ((shell nil)
        (window-options (loop for (key value) on window-options by #'cddr
                              unless (eq key :activation-policy)
                                append (list key value))))
    (unwind-protect
         (cl-iris:run-application
          :on-launch (lambda ()
                       ;; START-SHELL waits on the main thread, so not from it.
                       (sb-thread:make-thread
                        (lambda ()
                          (handler-case (setf shell (apply #'start-shell socket window-options))
                            (error (condition)
                              (format *error-output* "~&;; circle shell: ~A~%" condition)
                              (cl-iris:stop-application))))
                        :name "circle shell start"))
          :quit-on-last-window-closed t
          :activation-policy activation-policy)
      (when shell
        (ignore-errors (cl-proteus/shell:stop-shell (shell-server shell)))))))

(defun command-line (arguments)
  "Run the shell as scripts/circle-shell asks: ARGUMENTS hold the socket
path. With CIRCLE_TEST_HIDDEN_SHELL set, as circle's tests set it, the
window is transparent and the shell stays out of the Dock and the focus."
  (destructuring-bind (socket &rest ignore) arguments
    (declare (ignore ignore))
    (if (uiop:getenv "CIRCLE_TEST_HIDDEN_SHELL")
        (progn
          (setf cl-iris:*window-defaults* (list* :alpha 0 cl-iris:*window-defaults*))
          (run-shell socket :activation-policy :accessory :activate nil))
        (run-shell socket))
    0))
