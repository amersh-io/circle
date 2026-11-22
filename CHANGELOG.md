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
- Permission questions go to a Lisp function; the default allows the
  image's own tools and denies the rest with a reason.

### Tools

- Tool servers served to the CLI in process (MCP servers of type `sdk` over
  the same stdio); `define-tool` defines a tool, and running engines are told
  so they list it before their next turn.
- `eval`: reads forms with `*read-eval*` false, evaluates them in the image,
  and answers their output and values, or the error and its backtrace.

### Around the code

- A stand-in CLI for the tests, and opt-in checks against the real one.
- `examples/hello.lisp`, run by the suite.
- CI on Ubuntu and macOS.
