# SwiftShot Agent Instructions

## Build Artifact Hygiene

- The only normal launchable SwiftShot app is `/Applications/SwiftShot.app`.
  Use `./script/build_and_run.sh` for ordinary build, install, and launch work.
- Do not use bare `xcodebuild` for routine build/run work. When a focused
  diagnostic or test build genuinely requires it, pass a project-local
  `-derivedDataPath` ending in `.noindex`; never use `build/DerivedData`,
  `build/Build`, or another Spotlight-indexable output root.
- Do not leave `SwiftShot.app` in `dist/`. Packaging is explicit and should
  create a ZIP from `/Applications/SwiftShot.app`, not a persistent copied app
  bundle.
- Before completing build or test work, inspect generated `SwiftShot.app`
  bundles. Preserve the installed app and any active evidence; route stale
  generated bundles through `/trashness` with a fresh exact approval manifest.
