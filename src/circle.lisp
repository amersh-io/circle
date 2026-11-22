;;;; circle -- Claude In a Running Common Lisp Environment.
;;;;
;;;; The umbrella package: the engine protocol, the image's tools, its window,
;;;; generations and the supervisor, and MAKE-ENGINE, which puts the first two
;;;; together.

(uiop:define-package #:circle
  (:use #:cl)
  (:use-reexport #:circle/engine #:circle/tools #:circle/interface #:circle/supervisor
                 #:circle/generation)
  (:export #:make-engine))

(in-package #:circle)

(defun make-engine (&rest initargs &key (mcp-servers (list *tool-server*)) &allow-other-keys)
  "A CLAUDE-ENGINE, not yet started, offered the image's own tool server,
*TOOL-SERVER*, with eval in it. INITARGS are those of CLAUDE-ENGINE, such
as :MODEL \"claude-opus-5-5\", :EFFORT \"high\" or :RESUME and a session id."
  (apply #'make-instance 'claude-engine :mcp-servers mcp-servers initargs))
