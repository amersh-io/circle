;;;; circle -- Claude In a Running Common Lisp Environment.

(defsystem "circle"
  :description "An agent that lives in a Common Lisp image, powered by Claude through Claude Code."
  :license "Apache-2.0"
  :version "0.0.1"
  :homepage "https://github.com/amersh-io/circle"
  :depends-on ("circle/engine" "circle/tools" "circle/interface" "circle/supervisor"
               "circle/generation")
  :pathname "src/"
  :components ((:file "circle"))
  :in-order-to ((test-op (test-op "circle/test"))))

(defsystem "circle/engine"
  :description "The engine protocol, and an engine that runs the Claude Code CLI over stdio."
  :license "Apache-2.0"
  :depends-on ("uiop" "com.inuoe.jzon")
  :pathname "src/engine/"
  :serial t
  :components ((:file "package")
               (:file "json")
               (:file "protocol")
               (:file "claude")))

(defsystem "circle/tools"
  :description "Tools the image offers the model, served over MCP: eval first among them."
  :license "Apache-2.0"
  :depends-on ("circle/engine")
  :pathname "src/tools/"
  :serial t
  :components ((:file "package")
               (:file "server")
               (:file "eval")))

(defsystem "circle/interface"
  :description "The image's side of its window: a chat view, permission cards, and the
connection to the shell that shows them. Loads no window code."
  :license "Apache-2.0"
  :depends-on ("circle/engine" "circle/tools" "cl-proteus/client")
  :pathname "src/interface/"
  :serial t
  :components ((:file "package")
               (:file "transcript")
               (:file "interface")
               (:static-file "chat/index.html")
               (:static-file "chat/chat.css")
               (:static-file "chat/chat.js")
               (:file "view")))

(defsystem "circle/shell"
  :description "The process that owns the agent's window, on cl-proteus and cl-iris (macOS)."
  :license "Apache-2.0"
  :depends-on ("cl-proteus" "cl-iris")
  :pathname "src/shell/"
  :serial t
  :components ((:file "package")
               (:file "shell")))

(defsystem "circle/supervisor"
  :description "Generations on disk, and the supervisor that starts the newest good one."
  :license "Apache-2.0"
  :depends-on ("uiop" "sb-posix" "sb-bsd-sockets")
  :pathname "src/supervisor/"
  :serial t
  :components ((:file "package")
               (:file "store")
               (:file "supervise")))

(defsystem "circle/generation"
  :description "Changes the image keeps, replayed and frozen into generations."
  :license "Apache-2.0"
  :depends-on ("circle/engine" "circle/tools" "circle/interface" "circle/supervisor"
               "sb-posix")
  :pathname "src/generation/"
  :serial t
  :components ((:file "package")
               (:file "journal")
               (:file "image")
               (:file "freeze")
               (:file "agent")))

(defsystem "circle/test"
  :license "Apache-2.0"
  :depends-on ("circle" (:feature :darwin "circle/shell"))
  :pathname "test/"
  :serial t
  :components ((:file "package")
               (:file "tools")
               (:file "engine")
               (:file "generations")
               (:file "interface")
               (:file "window" :if-feature :darwin)
               (:file "claude")
               (:file "examples")
               (:file "run"))
  :perform (test-op (o c) (symbol-call :circle/test :run!)))
