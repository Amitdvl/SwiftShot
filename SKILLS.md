# SwiftShot Session Skills

## End-of-Session Checklist

After every session that involves code changes:

1. **Rebuild & package the binary**
   ```sh
   cd ~/SwiftShot
   xcodegen generate
   xcodebuild -project SwiftShot.xcodeproj -scheme SwiftShot -configuration Release -derivedDataPath build clean build
   rm -rf dist && mkdir -p dist
   cp -R build/Build/Products/Release/SwiftShot.app dist/
   cd dist && zip -r -q SwiftShot.zip SwiftShot.app
   ```

2. **Commit and push**
   ```sh
   git add <changed files>
   git commit -m "..."
   git push
   ```

Never end a session without both steps complete.
