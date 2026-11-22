# Quint model of circle's generations

`generations.qnt` models freezing a generation and the supervisor that starts
one (`src/generation/freeze.lisp`: `FREEZE-GENERATION`, `RUN-REPLAY`;
`src/supervisor/store.lisp`: `NEXT-GENERATION-NUMBER`,
`GENERATION-STARTABLE-P`; `src/supervisor/supervise.lisp`: `SUPERVISE`). What
a generation is and how one is made is described in
[../docs/generations.md](../docs/generations.md).

The file has a base module with one constant, `DESIGN`, one module per design
at the bottom, the invariants, and `run` tests for `quint test`.

Checked with Quint 0.32.0. "TLC: holds" means TLC explored the whole
reachable state space of the instance, within the bounds below, and found no
violation of `safe` (all three invariants).

## Scope

Four generation directories; generation 0 is built and finished at the
start. While an image runs it may freeze a generation: take a number, write
the journal, replay (which may fail, removing the directory), save
(partially, then completely), rename the image into place, write the
manifest. The image may crash at any moment, mid-freeze included, and a
replay it started may carry on alone and finish its save into a directory
nobody finishes. When no image runs, the supervisor starts the newest
startable generation -- one with a manifest, an image and no failed-start
mark, as `GENERATION-STARTABLE-P` sees it -- and that start may fail, for any
generation.

## Invariants

- `startsOnlyFinished` -- the supervisor starts only a generation whose
  freeze finished (replay passed, image renamed into place, manifest
  written) and whose image is whole.
- `noRestartOfFailed` -- a generation that failed to start is not started
  again.
- `finishedStaysStartable` -- a generation whose freeze finished stays
  startable until it fails to start itself: no later freeze, failed replay or
  crash takes it away.

## Results

| Instance | Design | Result |
|---|---|---|
| `guarded` | the code: a number past every directory; save to `image.tmp`, then rename; manifest last; the supervisor checks manifest, image and mark, and marks a failed start | TLC: holds (2,313 distinct states, depth 26) |
| `saveInPlace` | the replay saves straight to `image`, no rename | TLC: holds (679 distinct states, depth 20) -- the manifest written last is enough on its own |
| `saveInPlaceManifestFirst` | that, and the manifest written before the save | **violation** of `startsOnlyFinished` (5 states): freeze 1 begins and writes its manifest, the replay starts saving, the image crashes, and the supervisor starts generation 1 with half an image |
| `noFailMark` | the supervisor does not mark a failed start | **violation** of `noRestartOfFailed` (4 states): generation 0 fails to start and is started again |
| `numberFromStartable` | the next number is one past the newest startable generation | **violation** of `finishedStaysStartable` (14 states): generation 1 is frozen and fails to start; the next freeze is numbered 1 again, lands in the same directory, and the new generation 1 inherits the old one's failed-start mark, so a generation that passed its replay can never be started |

So the image is kept whole by two guards, either of which suffices: the save
goes to `image.tmp` and is renamed into place, and the manifest is written
last. The code keeps both.

## Running it

```sh
scripts/check-spec                         # the run tests, as CI does
quint verify spec/generations.qnt --main guarded \
  --backend tlc --tlc-config spec/tlc.json --invariant safe   # needs Java
```

## Simplified away

The journal's content and the checks (a replay passes or fails as a whole);
the session id; the backoff between restarts and the exit codes (a start
succeeds or fails); fsync (a rename is taken as atomic and durable); two
images freezing into one directory at once (the code supports one).
