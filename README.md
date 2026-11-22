# circle

**Claude In a Running Common Lisp Environment.**

An agent that lives in a Common Lisp image, powered by Claude through
Claude Code. Not affiliated with Anthropic.

> Status: early. The engine runs: a Lisp image talks to Claude, and Claude
> evaluates Lisp in that image. Changes it keeps become generations a
> supervisor starts again. The interface comes next.

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
- **Generations.** Changes the model keeps are replayed in a fresh process
  started from the image's generation; if they and their checks pass, that
  process saves itself with `save-lisp-and-die` as the next generation. A
  thin supervisor starts the newest good generation and resumes the same
  conversation.
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

## Generations

```lisp
(circle:make-first-generation
 :directory (merge-pathnames "agents/notes/" (user-homedir-pathname)) ; else circle/ under ~/.local/share
 :system "my-agent"                       ; your agent's own code, if any
 :engine-options '(:model "claude-opus-5-5" :effort "high"))
```

```sh
scripts/circle ~/agents/notes/            # start the newest good generation, keep one running
```

The agent answers each line you type. The model keeps a change by calling
`eval` with `keep` set to true, and freezes the kept changes with its
`freeze_generation` tool:

- A fresh process started from the current generation replays the kept
  changes and runs every check noted with `note-check`; only if all pass does
  it save itself as the next generation. What a generation holds is what its
  replay made, not the running image's other state.
- `:restart` ends the image so the supervisor starts the newest generation;
  `:freeze` freezes from the keyboard; the end of input ends both.
- The supervisor runs from source, never from a generation. A generation that
  fails to start is marked and the one before it starts; one that crashes is
  started again after a pause. Each resumes the same conversation.

[docs/generations.md](docs/generations.md) says what a replay checks and why
the running image is not forked; [spec/](spec) models the freeze and the
supervisor in Quint. `examples/generations.lisp` builds generation 0 and runs
it once.

## Tests

`scripts/test` runs the suite against a stand-in CLI (`test/fake-claude.lisp`)
that speaks the same protocol, so it needs no model. `CIRCLE_TEST_CLAUDE=1`
adds checks against the real CLI (`CIRCLE_TEST_MODEL` and `CIRCLE_TEST_EFFORT`, `claude-opus-5-5` and `high`
by default):
one turn, a turn that calls `eval`, a tool defined mid-conversation, a
resumed conversation, and a generation the model freezes and the supervisor
starts. `scripts/check-spec` runs the Quint model's tests.

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute circle or
work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
