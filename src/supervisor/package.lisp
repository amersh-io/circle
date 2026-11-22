;;;; circle/supervisor -- the generations on disk, and the small program that
;;;; starts the newest good one.
;;;;
;;;; This system needs nothing but UIOP: the supervisor runs it from source in
;;;; a plain Lisp, never from a generation the agent may have changed.

(defpackage #:circle/supervisor
  (:use #:cl)
  (:export
   ;; Where generations live
   #:*generations-directory*
   #:generation-directory
   #:generation-file
   #:generation-numbers
   #:next-generation-number
   ;; Manifests
   #:read-manifest
   #:write-manifest
   #:manifest-get
   ;; Which generation to start
   #:generation-startable-p
   #:startable-generations
   #:newest-startable
   #:mark-start-failed
   #:start-failed-p
   ;; The conversation
   #:read-session-id
   #:write-session-id
   ;; Supervising
   #:supervise
   #:+exit-restart+
   #:*first-backoff*
   #:*most-backoff*
   ;; Writing files whole
   #:write-file-atomically))
