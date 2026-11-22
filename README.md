# circle

**Claude In a Running Common Lisp Environment.**

An agent that lives in a Common Lisp image, powered by Claude through
Claude Code. Not affiliated with Anthropic.

> Status: just started. Nothing here runs yet; the plan below is what is
> being built.

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

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute circle or
work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
