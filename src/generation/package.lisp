;;;; circle/generation -- changes the image keeps, and the generations they
;;;; become.
;;;;
;;;; The image changes while it runs; a change meant to last is noted. To
;;;; freeze a generation, a fresh process starts from the image this one
;;;; started from, replays the noted changes and runs the checks; only if
;;;; all of that passes does that same process save itself as the new
;;;; generation. What a generation holds is therefore exactly what its
;;;; replay made, never the running image's other state.

(defpackage #:circle/generation
  (:use #:cl #:circle/engine #:circle/tools #:circle/supervisor)
  (:export
   ;; Changes
   #:note-change
   #:note-check
   #:pending-changes
   #:discard-pending-changes
   #:generation-checks
   ;; Generations
   #:*generation*
   #:*engine-options*
   #:*replay-timeout*
   #:make-first-generation
   #:freeze-generation
   #:freeze-error
   #:freeze-error-output
   #:generation-main
   ;; The agent
   #:run-agent
   #:*agent-engine*))
