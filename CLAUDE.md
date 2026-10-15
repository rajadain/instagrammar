# Instagrammar

Native macOS (SwiftUI + AppKit canvas) app that splits a wide photo into seamless Instagram carousel tiles.

- **Plan:** [PLAN.md](PLAN.md). Work phase by phase, honouring the acceptance criteria.
- **Decisions:** [MEMORY.md](MEMORY.md). Read it before starting. Append new decisions with a date.
- Build: `swift build` · Test: `scripts/test.sh` (never bare `swift test`, since Swift Testing needs CLT framework flags) · App bundle: `scripts/build-app.sh && open build/Instagrammar.app`
- No Xcode is installed (Command Line Tools only). Image processing uses ImageIO/Core Image only. Don't write custom pixel code.
- Commit after each phase on `main`, prefixed `Phase N:`.
