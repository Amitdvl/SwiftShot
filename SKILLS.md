# SwiftShot Session Skills

## End-of-Session Checklist

After every session that involves code changes:

1. **Build and install the canonical app**
   ```sh
   cd ~/SwiftShot
   ./script/build_and_run.sh --build
   ```

   The script uses a `.noindex` derived-data path, installs only
   `/Applications/SwiftShot.app`, unregisters its disposable build product,
   and removes that product after installation. Do not replace this with a raw
   `xcodebuild` command that writes an indexable app bundle under `build/`.

2. **Package only when explicitly requested**
   ```sh
   mkdir -p dist
   ditto -c -k --sequesterRsrc --keepParent /Applications/SwiftShot.app dist/SwiftShot.zip
   ```

   This creates a distributable ZIP without leaving `dist/SwiftShot.app`.

3. **Commit and push**
   ```sh
   git add <changed files>
   git commit -m "..."
   git push
   ```

Never end a session without both steps complete.
