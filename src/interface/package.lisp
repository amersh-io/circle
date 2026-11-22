;;;; circle/interface -- the image's side of its window.
;;;;
;;;; The window lives in another process, a shell built on cl-proteus and
;;;; cl-iris; this image holds no window code. It owns the page the window
;;;; shows -- the view "circle", a chat over the conversation -- and the
;;;; commands that page calls, and sends both to the shell over cl-proteus's
;;;; socket. So the model can change its own window while it runs, and a
;;;; generation saved from this image carries that window along.

(defpackage #:circle/interface
  (:use #:cl #:circle/engine #:circle/tools)
  (:export
   ;; The transcript the window shows
   #:transcript-entries
   #:message-entries
   #:record-entry
   #:record-user-text
   #:clear-transcript
   #:*transcript-file*
   ;; The window's page
   #:*interface-view*
   #:interface-file
   #:interface-files
   ;; Running it
   #:interface
   #:start-interface
   #:stop-interface
   #:with-interface
   #:*interface*
   #:interface-engine
   #:interface-socket
   #:interface-connected-p
   #:interface-send
   ;; Permission cards
   #:interface-permission
   #:*permission-timeout*))
