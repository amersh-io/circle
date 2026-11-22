# Changelog

All notable changes to circle are listed here. The project follows
[Semantic Versioning](https://semver.org/); until 1.0, a minor release may
change the API.

## Unreleased

### Engine

- An engine protocol (`start-engine`, `ask`, `send-user-message`,
  `stop-engine`, handlers), and `claude-engine`, which runs the Claude Code
  CLI as a child process over stream-json and answers its control requests.
- Conversations resume: the session id survives `stop-engine`, and
  `:resume` continues one in a new engine.
- `:model` and `:effort` choose the model and its effort level
  (`--model`, `--effort`).
- Permission questions go to a Lisp function; the default allows the
  image's own tools and denies the rest with a reason.

### Tools

- Tool servers served to the CLI in process (MCP servers of type `sdk` over
  the same stdio); `define-tool` defines a tool, and running engines are told
  so they list it before their next turn.
- `eval`: reads forms with `*read-eval*` false, evaluates them in the image,
  and answers their output and values, or the error and its backtrace.

### Generations

- Changes the image keeps: `eval` with `keep`, `note-change`, and checks
  that must hold, `note-check`.
- `freeze-generation` and the model's `freeze_generation` tool: the kept
  changes are replayed in a fresh process started from the image's
  generation, every check runs, and only then does that process save itself
  as the next generation; image and manifest are put in place by rename,
  the manifest last.
- `make-first-generation` builds generation 0 from source with the engine's
  options; every generation resumes the conversation its directory records.
- `scripts/circle`, the supervisor: starts the newest generation that can be
  started, marks one that fails to start and falls back to the one before,
  starts one that crashes again after a doubling pause, and starts the
  newest at once on `:restart`.
- The freeze and the supervisor modelled in Quint (`spec/`), with a CI job.

### Interface

- `circle/interface`, the image's side of a window, which loads no window
  code: the view `circle`, a chat over the conversation, sent to a shell
  with `cl-proteus/client`; `start-interface` keeps the image connected,
  `interface-send`, and a transcript built from the engine's messages
  (`message-entries`, `transcript-entries`), kept in a file across images.
- Permission cards: a tool other than the image's own is asked about in the
  window (`interface-permission`), denied after `*permission-timeout*`.
- `interface-file` and its `setf`: the model changes its own window through
  `eval`, and `keep` carries the change into the next generation.
- `circle/shell` (macOS), the process that owns the window, and
  `scripts/circle-shell`; `scripts/circle --window` or `--shell SOCKET`
  starts it when nothing answers and gives every generation its socket.
- Depends on cl-proteus 0.1.0 and cl-iris 0.2.0.

### Around the code

- A stand-in CLI for the tests, and opt-in checks against the real one.
- `examples/hello.lisp` and `examples/generations.lisp`, run by the suite.
- CI on Ubuntu and macOS.
