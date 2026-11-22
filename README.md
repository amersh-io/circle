# circle

**Claude In a Running Common Lisp Environment.**

An agent that lives in a Common Lisp image, powered by Claude through
Claude Code. Not affiliated with Anthropic.

> Status: early. The engine runs: a Lisp image talks to Claude, and Claude
> evaluates Lisp in that image. Generations and the interface come next.

## The idea

A Lisp image can be changed while it runs: a function redefined, a frame
restarted, a new screen loaded. circle keeps an agent's body in such an image
and lets the agent work on it — its own tools, its own interface, its own
supervisor — without stopping the conversation.

- **Engine.** The model's loop runs in the Claude Code CLI, started as a child
  process and spoken to over `stream-json` on stdin and stdout. The engine is
  a protocol, so another loop can take its place later.
- **Body.** The image hands the engine its tools, first among them `eval` in
  the running image.
- **Generations.** When a change passes a replay check, a forked child saves
  the image with `save-lisp-and-die`. A thin supervisor starts the last good
  generation again and resumes the same conversation.
- **Interface.** Windows live in a separate shell process built on
  [cl-proteus](https://github.com/amersh-io/cl-proteus); the image holds no
  Cocoa state and sends its views and commands over a socket, so saving a
  generation never captures a window.

## Requirements

- SBCL on macOS or Linux.
- The Claude Code CLI (`claude`), signed in.

## Using it

```sh
scripts/bootstrap                 # SBCL 2.6.9 and qlot under .local/
.local/bin/qlot exec sbcl
```

```lisp
(asdf:load-system "circle")

(defvar *claude* (circle:start-engine (circle:make-engine :model "claude-opus-5-5" :effort "high")))

(circle:ask *claude* "Define a function SQUARE in this image with eval, then use it on 12.")
;; => "SQUARE is defined; (square 12) is 144."

(square 12)          ; the model defined it here, in CL-USER
;; => 144

(circle:engine-session-id *claude*)
;; => "6b5c41c9-..."
```

- **`ask`** sends a message and waits for the turn to end, returning its
  final text. `send-user-message` sends one without waiting;
  `add-engine-handler` hears every message the engine emits, as JSON objects
  (`json-get`, `message-type`, `message-text`).
- **Tools.** The image serves its tools to the CLI in process, as an MCP
  server of type `sdk` routed over the same stdio; nothing else is started.
  `eval` is the first. Define more while the engine runs; it lists them again
  before its next turn:

  ```lisp
  (circle:define-tool word-count ((text :string "The text to count."))
    "Count the words in a text."
    (length (uiop:split-string text)))
  ```

- **Permissions.** The CLI asks the image before a tool its own settings do
  not allow. The default answer, `allow-own-tools`, allows the image's tools
  and denies the rest with a reason; set `engine-permission-function` to
  decide otherwise.
- **Resuming.** `stop-engine` keeps the session id, and starting the engine
  again continues the conversation; so does a new engine made with
  `:resume` and that id, in another image.
- The CLI runs as it would for you, with your settings; give it more
  arguments with `:arguments`, such as `("--tools" "")` to offer the model
  no tools but the image's.

`examples/hello.lisp` asks one question and prints the answer.

## Tests

`scripts/test` runs the suite against a stand-in CLI (`test/fake-claude.lisp`)
that speaks the same protocol, so it needs no model. `CIRCLE_TEST_CLAUDE=1`
adds checks against the real CLI (`CIRCLE_TEST_MODEL` and `CIRCLE_TEST_EFFORT`, `claude-opus-5-5` and `high`
by default):
one turn, a turn that calls `eval`, a tool defined mid-conversation, and a
resumed conversation.

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute circle or
work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
