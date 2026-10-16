# Instagrammar — Progress

Snapshot of where the build stands, so work can resume in a fresh session. Read with
[PLAN.md](PLAN.md) (the spec) and [MEMORY.md](MEMORY.md) (decisions; entries T1–T45 matter).

**Paused 2026-10-15** at the user's request, partway through Phase 8 (QA).

## Phase status

| Phase | What | Status | Notes |
|---|---|---|---|
| 0 | Scaffold, scripts, Info.plist | ✅ merged | |
| 1 | Crop geometry (`CropGeometry`, `CropState`, `AspectRatio`) | ✅ merged | Opus |
| 2 | Source loading (`SourceImage`, `CIBridge`, fixtures) | ✅ merged | RAW out of scope (T19) |
| 3 | Exporter + `tiler` CLI + `scripts/smoke-export.sh` | ✅ merged | Opus; 0.13–0.24 s per 3 tiles |
| 4 | App shell, `AppModel`, inspector | ✅ merged | |
| 5 | AppKit/CALayer crop canvas + gestures | ✅ merged | Opus |
| 6 | Export UI (`Export/ExportCoordinator`) | ✅ merged | |
| 7a | Icon, carousel preview ⌘P, About, README | ✅ merged | |
| 7b | Undo/redo | ✅ merged | |
| 7 (hi-res refinement) | — | ⏭ skipped | T41 |
| 8 | QA & performance | ⏸ **in progress, not merged** | see below |

After the pause, the inspector sliders were unified into one plain style with double-click reset
(P16, commit 84813af).

**Remote:** `origin` = `git@github.com:rajadain/instagrammar.git`, with `main` pushed and tracking.
`phase-8-wip` is **local only** and not pushed.

**Release 1** (tag `1`, app version 1.0, 2026-10-16) is published on GitHub with an Apple
Silicon zip from `scripts/package-release.sh`. Changes since the pause:
- sliding carousel preview (P17)
- exact-ratio native tile sizes (T46)
- Portrait 3:4 as the default (P18)

On `main`, 87 unit tests and all four DEBUG self-tests (canvas, undo, export, preview) pass.

## Phase 8: where it stopped

The work is on branch **`phase-8-wip`**, two commits on top of `main` (7cf08e3). It is **not
verified and not merged**.
- `9887981`: adds `scripts/qa-matrix.sh` (CLI matrix that builds its own corpus) and a fix
  that blends semi-transparent pixels over white in sRGB space, touching `CIBridge`,
  `SourceImage`, `TileExporter` and `PreviewTiles`. It comes with a new fixture and test.
  Review it, then run `scripts/test.sh` before merging.
- `ce6914c` (WIP): an unfinished `MenuSelfTest.swift` (the T45 menu-enablement
  investigation) and a `Sources/perf/` timing harness, plus a target added in
  `Package.swift`. Its state is unknown. It may not compile.

### Remaining Phase 8 tasks
The full brief is PLAN §10. In short:
1. Finish and run `scripts/qa-matrix.sh` across the samples and the generated corpus (PNG
   alpha, 16-bit TIFF, EXIF 6/8, tiny, ~50 MP, ~100 MP, garbage file, RAF error).
2. Check performance: under 500 ms to preview 50 MP, under 8 s to export 10 tiles from
   100 MP, under 1 GB RSS, 0% idle CPU. Also check canvas sharpness on 100 MP (T41).
3. **T45 menu enablement.** Check whether File > Export, the Image menu and Preview Carousel
   enable after an image loads. A suspected fix is to hold the model as
   `@State private var model = AppModel.shared` in `InstagrammarApp`, or move commands into
   `Commands` structs. If that works, restore `.disabled` and live titles on Undo/Redo.
4. Visual pass via `INSTAGRAMMAR_CANVAS_SELFTEST=1 INSTAGRAMMAR_CANVAS_SNAPSHOT_DIR=…` on
   EXIF-6, tiny, N=20 at 1.91:1, and HEIC.
5. Write `docs/QA.md` with results plus **one consolidated manual checklist for the user**,
   grouped as Canvas, Export, Carousel, Undo and Opening. The items are listed in the Phase 8
   brief: trackpad feel, dialogs, Dock/Finder opening, and undo menu titles.

## How to resume
- **Workflow used so far:** the coordinator (Opus) plans and merges. Phase work goes to
  sub-agents in isolated git worktrees: Opus for complex phases, Sonnet for the rest (T16).
  Each agent commits on its worktree branch. The coordinator reviews, merges into `main`,
  re-runs the tests and self-tests, and appends the agent's suggested decisions to MEMORY.md.
- **Next step:** start a Phase 8 agent from branch `phase-8-wip`, giving it the "Remaining
  Phase 8 tasks" above. Alternatively, merge `9887981` alone after review and redo the
  rest.
- **Verify commands:**
  ```bash
  scripts/test.sh
  ```
  ```bash
  scripts/build-app.sh && open build/Instagrammar.app
  ```
  ```bash
  INSTAGRAMMAR_CANVAS_SELFTEST=1 .build/debug/Instagrammar "$PWD/scratch/samples/DSCF7281.jpg"
  ```
  The self-test flags are `CANVAS`, `UNDO`, `EXPORT=<dir>` and `PREVIEW=<dir>` (T36, T42, T44).

## Environment notes
- Xcode 26.3 is installed, but its license still isn't accepted and `xcode-select` still
  points at Command Line Tools. `scripts/test.sh` handles both cases. To switch:
  `sudo xcodebuild -license accept` and
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- Sample photos are in `scratch/samples/`, which is git-ignored (T14).
- Merged agent worktrees remain under `.claude/worktrees/`, which is git-ignored. They can be
  removed with `git worktree remove` once you no longer need them. Keep
  `agent-a3dd18bb50315a703` (Phase 8) until `phase-8-wip` is dealt with.
