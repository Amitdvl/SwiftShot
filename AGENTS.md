## Available CLI Tools

### context7 — up-to-date library docs
Always use context7 before writing code with an external library.
context7 resolve-library-id libraryName=<lib>
context7 get-library-docs context7CompatibleLibraryID=<id> topic=<topic>

### supabase — database management
supabase migration new <name>
supabase db push
supabase gen types typescript --local > supabase/types.ts
supabase status

### docker — container management
After finishing work that uses Docker, always run the cleanup script:
~/scripts/docker-cleanup.sh

This stops running containers and prunes unused resources to prevent disk bloat.
For a full nuclear cleanup (removes ALL images, not just dangling):
docker system prune -a -f

## SwiftShot-Native (~/SwiftShot-Native)

### Build & package
After any code change, always rebuild and package the binary:
```sh
cd ~/SwiftShot-Native
xcodegen generate
xcodebuild -project SwiftShot.xcodeproj -scheme SwiftShot -configuration Release -derivedDataPath build clean build
rm -rf dist && mkdir -p dist
cp -R build/Build/Products/Release/SwiftShot.app dist/
cd dist && zip -r -q SwiftShot.zip SwiftShot.app
```
The `dist/` folder is gitignored — the binary stays local.

### Project structure
- `project.yml` — XcodeGen spec (source of truth for the Xcode project)
- `SwiftShot/` — Swift source (Services/, ViewModels/, Models/, Views/)
- `SwiftShot/Resources/Backgrounds/` — bundled background JPGs
- `Info.plist`, `SwiftShot.entitlements` — at project root
