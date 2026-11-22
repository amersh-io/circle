;;;; circle/engine -- the loop the model runs in, seen from the image.
;;;;
;;;; An engine is a protocol: start it, ask it something, hear what it
;;;; says, stop it. CLAUDE-ENGINE runs the Claude Code CLI as a child
;;;; process and speaks its stream-json protocol over stdin and stdout.

(defpackage #:circle/engine
  (:use #:cl)
  (:export
   ;; JSON
   #:parse-json
   #:to-json
   #:json-object
   #:json-get
   ;; The protocol
   #:engine
   #:start-engine
   #:stop-engine
   #:engine-running-p
   #:send-user-message
   #:ask
   #:engine-session-id
   #:engine-handlers
   #:add-engine-handler
   #:remove-engine-handler
   #:*engine*
   #:engine-mcp-servers
   #:engine-permission-function
   #:engine-error
   #:engine-error-engine
   #:engine-exited
   #:engine-timeout
   #:turn-error
   #:turn-error-message
   ;; Tools served to the engine over MCP
   #:mcp-server-name
   #:handle-mcp-request
   #:tools-changed
   #:notify-tools-changed
   ;; Permissions
   #:allow-own-tools
   ;; The Claude Code CLI
   #:claude-engine
   #:*claude-command*
   #:engine-command
   #:engine-model
   #:engine-arguments
   #:engine-directory
   #:engine-process
   #:engine-command-line
   #:with-engine
   #:message-type
   #:message-text))
