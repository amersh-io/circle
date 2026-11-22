;;;; circle/tools -- what the image offers the model.
;;;;
;;;; A tool server is a named set of tools the engine reaches over MCP. Its
;;;; tools are Lisp functions, defined and redefined while the image runs.

(defpackage #:circle/tools
  (:use #:cl #:circle/engine)
  (:export #:tool-server
           #:make-tool-server
           #:tool-server-tools
           #:*tool-server*
           #:tool
           #:tool-name
           #:tool-description
           #:tool-parameters
           #:tool-function
           #:define-tool
           #:add-tool
           #:remove-tool
           #:find-tool
           #:call-tool
           #:tool-error
           #:*mcp-protocol-version*
           #:eval-forms
           #:*eval-package*))
