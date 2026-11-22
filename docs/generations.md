# Generations

An agent's image changes while it runs: the model defines functions and
tools with `eval`, redefines them, sets variables. Most of that is trying
things. A change meant to last is *kept*, and kept changes become a
*generation* -- a saved image the supervisor starts next time -- only once a
replay of them has passed.

## Keeping a change

- The model calls `eval` with `keep` set to true. If the forms run without
  error, their source text and the package they were read in are noted as a
  change.
- From Lisp, `(circle:note-change "<forms>" :package "MY-PACKAGE")` notes a
  change already evaluated (a form instead of a string is printed readably).
- `(circle:note-check "<forms>")` notes a check: forms whose last value must
  be true. It runs at once and is refused if it is false here. Checks stay
  with every later generation and run again in every later replay.

`pending-changes` lists what is noted since the image's generation;
`discard-pending-changes` forgets it (the image itself keeps the changes).

Only what is kept is frozen: a function defined with a plain `eval` is gone
from the next generation, even though the running image has it.

## Freezing

`freeze-generation` (the model's `freeze_generation` tool, or `:freeze` typed
to the agent) makes generation N, numbered one past every directory there:

1. The pending changes and checks are written to `N/journal.lisp`.
2. The image of the running image's generation, P, is started fresh with
   `--circle-replay N/journal.lisp --circle-save N/image.tmp`. It evaluates
   each change in order, reading its source again in its package with
   `*read-eval*` false, then runs every check -- P's and the new ones.
3. If all of that passed, that fresh process prints `REPLAY-OK` and saves
   itself, with `save-lisp-and-die`, to `N/image.tmp`.
4. `N/image.tmp` is renamed to `N/image`, then `N/manifest.lisp` is written
   (number, parent, time, the conversation's id, the counts) and renamed into
   place.

A freeze whose replay fails removes `N/` and leaves the changes pending.

### What REPLAY-OK means

`REPLAY-OK` means: a process started from generation P's image, with nothing
of the running image but the journal, evaluated every kept change in order
without signalling an error, then evaluated every check (P's and the new
ones) to a true value without signalling an error, and was left running one
thread. It does not mean the changes are correct beyond what the checks say,
and it says nothing about state the running image holds that was not kept.

Generation N is then the image that replay produced -- not a copy of the
running image. The running image's other state (variables set without
`keep`, open streams, the engine's process) is not in it, so a generation
never holds a dead process or socket.

### Why not fork the running image

The original design forked the running image and had the child save it.
SBCL forks only while one thread runs ("Cannot fork with multiple threads
running"), and a running agent has several: the engine's reader, its
standard-error reader, the thread answering the tool call, and the caller
waiting in `ask`. Stopping them all to fork would end the turn that asked
for the freeze. Saving the replay instead needs no fork and keeps exactly
what the replay proved.

## Starting

`scripts/circle DIRECTORY` runs the supervisor from the repository's source
-- never from a generation, which the agent may have changed. It starts the
newest generation that can be started: one whose manifest says its replay
passed (or that it was built from source), whose image is in place, and that
has not failed to start. A generation tells it has started by writing the
file named after `--circle-ready`; then:

- exit code 0 ends the supervisor;
- exit code 75 (`+exit-restart+`, what `:restart` gives) starts the newest
  generation at once -- the one just frozen, say;
- ending before it was ready marks the generation `start-failed`, and the one
  before it is started;
- any other exit is a crash: the same choice is made again after a pause that
  doubles from 1 s to 30 s, and is back at 1 s after a run of a minute.

Each generation starts the engine with the options generation 0 was built
with (`*engine-options*`) and resumes the conversation in `DIRECTORY/session`,
which the running image keeps current.

## Generation 0

`make-first-generation` builds it from source in a fresh Lisp: circle, plus
the agent's own `:system` or `:load` files, saved with `:engine-options` such
as `(:model "claude-opus-5-5" :effort "high")`.

## On disk

```
DIRECTORY/                 (circle/ under $XDG_DATA_HOME, else ~/.local/share)
  session                  the conversation's id
  0/  image  manifest.lisp
  1/  journal.lisp  image  manifest.lisp  [start-failed]
```

A directory without a manifest is a freeze that was interrupted; nothing
starts it, and the next freeze is numbered past it. One image freezes into a
directory at a time.

The freeze and the supervisor are modelled in Quint: [../spec](../spec).
