;;;; The window's page: the view "circle", a chat over the transcript.
;;;;
;;;; Its files are read from chat/ when this system loads, and live in the
;;;; image from then on, so a generation carries them. ext.js and ext.css are
;;;; loaded after the chat and are empty at first: the model changes its own
;;;; window by setting them, or any other file, with INTERFACE-FILE.

(in-package #:circle/interface)

(defvar *interface-view* "circle"
  "The name of the view the window shows, served at proteus://view/circle/.")

(defparameter *chat-directory*
  (asdf:system-relative-pathname "circle/interface" "src/interface/chat/")
  "Where the page's files are read from when this system loads.")

(defun interface-files ()
  "The paths of the files of the window's page, sorted."
  (let ((view (cl-proteus/core:find-view *interface-view*)))
    (and view (sort (mapcar #'car (cl-proteus/core:view-files view)) #'string<))))

(defun interface-file (path)
  "The text of the file PATH of the window's page, or NIL if it has none."
  (let* ((view (cl-proteus/core:find-view *interface-view*))
         (octets (and view (cl-proteus/core:view-file view path))))
    (and octets (sb-ext:octets-to-string octets :external-format :utf-8))))

(defun (setf interface-file) (text path)
  "Make TEXT the file PATH of the window's page, keeping its other files, or
remove the file if TEXT is NIL. Every page showing the window loads again.
Evaluate it through eval with keep true to keep it in the next generation."
  (let* ((view (cl-proteus/core:find-view *interface-view*))
         (files (remove path (and view (cl-proteus/core:view-files view))
                        :key #'car :test #'string=)))
    (cl-proteus/core:ensure-view *interface-view*
                                 :files (if text
                                            (append files (list (cons path text)))
                                            files))
    text))

(cl-proteus/core:ensure-view *interface-view*
                             :directory *chat-directory*
                             :files '(("ext.js" . "") ("ext.css" . "")))
