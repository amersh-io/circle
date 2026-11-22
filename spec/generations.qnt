// generations.qnt -- freezing a generation and the supervisor that starts one
// (src/generation/freeze.lisp: FREEZE-GENERATION, RUN-REPLAY;
// src/supervisor/store.lisp: NEXT-GENERATION-NUMBER, GENERATION-STARTABLE-P;
// src/supervisor/supervise.lisp: SUPERVISE).
//
// What is modelled
//   * Generation directories 0 .. SLOTS-1. Generation 0 is built from source
//     and starts out finished: its image is in place and its manifest says so.
//   * While an agent image runs, it may freeze a generation: it takes a
//     number, writes the journal there, and a fresh process replays the
//     journal and saves itself -- to image.tmp, which takes a while (Partial,
//     then Complete). The replay may fail, and the directory is removed. If it
//     passes, image.tmp is renamed to image, then the manifest is written.
//   * The running image may crash at any moment, mid-freeze included; the
//     directory stays as it is. A replay process outlives a crashed image and
//     may still finish its save.
//   * When no image runs, the supervisor starts the newest startable
//     generation. Starting may fail (any generation, at any time); the
//     supervisor then marks it failed to start.
//
// Designs (const DESIGN)
//   "guarded"             -- the code: a fresh number past every directory;
//                            the save goes to image.tmp and is renamed into
//                            place; the manifest is written last; the
//                            supervisor starts only a generation with a
//                            manifest, an image and no failed-start mark, and
//                            marks one that fails to start.
//   "saveInPlace"         -- the replay saves straight to image (no rename).
//   "saveInPlaceManifestFirst" -- that, and the manifest is written before the
//                            save rather than after it.
//   "noFailMark"          -- the supervisor does not mark a failed start.
//   "numberFromStartable" -- the next number is one past the newest startable
//                            generation, not past every directory.
//
// Simplified away: the journal's content and the checks (a replay passes or
// fails as a whole); the session id; the backoff between restarts; the
// exit codes (a start succeeds or fails); fsync (a rename is atomic and
// durable).
module generations {
  const DESIGN: str

  pure val SLOTS = 4
  pure val NS = 0.to(SLOTS - 1)
  pure val NONE = -1

  type File = Absent | Partial | Complete
  type Step = Idle | Replaying | Saving | Saved | Renamed

  type Dir = { exists: bool, tmp: File, image: File, manifest: bool, failed: bool,
               // ghosts: the freeze that made this directory finished, and
               // whether the generation it made has itself failed to start
               finished: bool, ownFailure: bool }

  var dirs: int -> Dir
  var running: bool            // an agent image runs
  var freezing: int            // the number being frozen, or NONE
  var phase: Step
  var lastStarted: int         // the generation started last
  var badStart: bool           // a start of a generation that is not finished and whole
  var restartedFailed: bool    // a generation started again after it failed to start

  pure val emptyDir: Dir = { exists: false, tmp: Absent, image: Absent, manifest: false,
                             failed: false, finished: false, ownFailure: false }

  action init = all {
    dirs' = NS.mapBy(n => if (n == 0) { ...emptyDir, exists: true, image: Complete,
                                        manifest: true, finished: true }
                          else emptyDir),
    running' = true,
    freezing' = NONE,
    phase' = Idle,
    lastStarted' = 0,
    badStart' = false,
    restartedFailed' = false,
  }

  def inPlace: bool = DESIGN == "saveInPlace" or DESIGN == "saveInPlaceManifestFirst"

  // What the supervisor sees: a manifest, an image file of any kind, no mark.
  def startable(n: int): bool =
    dirs.get(n).exists and dirs.get(n).manifest and dirs.get(n).image != Absent
      and not(dirs.get(n).failed)

  def startables: Set[int] = NS.filter(n => startable(n))

  def maxDir: int = NS.fold(NONE, (m, n) => if (dirs.get(n).exists and n > m) n else m)

  def maxStartable: int = startables.fold(NONE, (m, n) => if (n > m) n else m)

  def nextNumber: int = if (DESIGN == "numberFromStartable") maxStartable + 1 else maxDir + 1

  action unchangedSupervisor = all {
    lastStarted' = lastStarted, badStart' = badStart, restartedFailed' = restartedFailed,
  }

  // The running image starts a freeze: a number, and the journal written there.
  action beginFreeze = all {
    running, freezing == NONE,
    nextNumber < SLOTS,
    val n = nextNumber
    all {
      // A directory already there (only when numbered badly) keeps its files.
      dirs' = dirs.put(n, { ...dirs.get(n), exists: true, finished: false, ownFailure: false,
                            manifest: if (DESIGN == "saveInPlaceManifestFirst") true
                                      else dirs.get(n).manifest }),
      freezing' = n,
    },
    phase' = Replaying,
    running' = running,
    unchangedSupervisor,
  }

  def writeSave(d: Dir, f: File): Dir = if (inPlace) { ...d, image: f } else { ...d, tmp: f }

  // The replay passed and is saving itself.
  action saving = all {
    phase == Replaying,
    dirs' = dirs.put(freezing, writeSave(dirs.get(freezing), Partial)),
    phase' = Saving,
    running' = running, freezing' = freezing,
    unchangedSupervisor,
  }

  action saved = all {
    phase == Saving,
    dirs' = dirs.put(freezing, writeSave(dirs.get(freezing), Complete)),
    phase' = if (inPlace) Renamed else Saved,
    running' = running, freezing' = freezing,
    unchangedSupervisor,
  }

  // The replay failed (or was cut off) while the image waited: the directory goes.
  action replayFailed = all {
    phase == Replaying or phase == Saving,
    dirs' = dirs.put(freezing, emptyDir),
    phase' = Idle, freezing' = NONE,
    running' = running,
    unchangedSupervisor,
  }

  action rename = all {
    phase == Saved,
    dirs' = dirs.put(freezing, { ...dirs.get(freezing), image: Complete, tmp: Absent }),
    phase' = Renamed,
    running' = running, freezing' = freezing,
    unchangedSupervisor,
  }

  action writeManifest = all {
    phase == Renamed,
    dirs' = dirs.put(freezing, { ...dirs.get(freezing), manifest: true, finished: true }),
    phase' = Idle, freezing' = NONE,
    running' = running,
    unchangedSupervisor,
  }

  // The image crashes, mid-freeze or not; the directory stays as it is.
  action crash = all {
    running,
    running' = false,
    freezing' = NONE,
    dirs' = dirs,
    phase' = Idle,
    unchangedSupervisor,
  }

  def saveFile(d: Dir): File = if (inPlace) d.image else d.tmp

  // A replay whose image crashed carries on alone: it saves, or finishes
  // saving, into a directory nobody will finish.
  action orphanSaves(n: int): bool = all {
    n != freezing,
    dirs.get(n).exists, not(dirs.get(n).finished),
    saveFile(dirs.get(n)) != Complete,
    dirs' = dirs.put(n, writeSave(dirs.get(n),
                                  if (saveFile(dirs.get(n)) == Absent) Partial else Complete)),
    running' = running, freezing' = freezing, phase' = phase,
    unchangedSupervisor,
  }

  // The supervisor starts the newest startable generation, which runs.
  action startOk = all {
    not(running),
    startables.size() > 0,
    val n = maxStartable
    all {
      // (if-then-else: TLC reads x' = a \/ b as (x' = a) \/ b)
      badStart' = if (dirs.get(n).finished and dirs.get(n).image == Complete) badStart else true,
      restartedFailed' = if (dirs.get(n).ownFailure) true else restartedFailed,
      lastStarted' = n,
    },
    running' = true,
    dirs' = dirs, freezing' = freezing, phase' = phase,
  }

  // ... or it fails to start, and is marked.
  action startFails = all {
    not(running),
    startables.size() > 0,
    val n = maxStartable
    all {
      // (if-then-else: TLC reads x' = a \/ b as (x' = a) \/ b)
      badStart' = if (dirs.get(n).finished and dirs.get(n).image == Complete) badStart else true,
      restartedFailed' = if (dirs.get(n).ownFailure) true else restartedFailed,
      lastStarted' = n,
      dirs' = dirs.put(n, { ...dirs.get(n), ownFailure: true,
                            failed: DESIGN != "noFailMark" }),
    },
    running' = false,
    freezing' = freezing, phase' = phase,
  }

  action stuttered = all {
    dirs' = dirs, running' = running, freezing' = freezing, phase' = phase,
    unchangedSupervisor,
  }

  action step = any {
    beginFreeze, saving, saved, replayFailed, rename, writeManifest, crash, startOk, startFails,
    nondet n = NS.oneOf()
    orphanSaves(n),
    stuttered,
  }

  // The supervisor starts only a generation whose freeze finished -- replay
  // passed, image renamed into place, manifest written -- and whose image is
  // whole.
  val startsOnlyFinished: bool = not(badStart)

  // A generation that failed to start is not started again.
  val noRestartOfFailed: bool = not(restartedFailed)

  // A generation whose freeze finished stays startable until it fails to start
  // itself: no freeze or crash after it takes it away.
  val finishedStaysStartable: bool =
    NS.forall(n => (dirs.get(n).finished and not(dirs.get(n).ownFailure) and freezing != n)
                     implies startable(n))

  val safe: bool = startsOnlyFinished and noRestartOfFailed and finishedStaysStartable

  // Freeze, crash, and the supervisor starts the new generation.
  run freezeThenRestartTest =
    init
      .then(beginFreeze).then(saving).then(saved).then(rename).then(writeManifest)
      .then(crash).then(startOk)
      .expect(lastStarted == 1 and safe)

  // A crash while the replay saves leaves generation 1 unstartable; 0 starts.
  run crashWhileSavingTest =
    init
      .then(beginFreeze).then(saving).then(crash).then(startOk)
      .expect(lastStarted == 0 and safe)

  // A crash after the rename, before the manifest: still 0.
  run crashBeforeManifestTest =
    init
      .then(beginFreeze).then(saving).then(saved).then(rename).then(crash).then(startOk)
      .expect(lastStarted == 0 and safe)

  // Generation 1 fails to start: it is marked and 0 starts; the next freeze is 2.
  run fallbackTest =
    init
      .then(beginFreeze).then(saving).then(saved).then(rename).then(writeManifest)
      .then(crash).then(startFails).then(startOk)
      .expect(lastStarted == 0 and dirs.get(1).failed and safe)
      .then(beginFreeze)
      .expect(freezing == 2)

  // A failed replay removes its directory and leaves the rest alone.
  run replayFailsTest =
    init
      .then(beginFreeze).then(replayFailed)
      .expect(not(dirs.get(1).exists) and startable(0) and safe)
}

module guarded { import generations(DESIGN = "guarded").* from "./generations" }
module saveInPlace { import generations(DESIGN = "saveInPlace").* from "./generations" }
module saveInPlaceManifestFirst { import generations(DESIGN = "saveInPlaceManifestFirst").* from "./generations" }
module noFailMark { import generations(DESIGN = "noFailMark").* from "./generations" }
module numberFromStartable { import generations(DESIGN = "numberFromStartable").* from "./generations" }
