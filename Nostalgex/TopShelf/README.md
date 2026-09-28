# Top Shelf extension

Everything here is written and ready. It is **not yet a target** in the Xcode
project, because adding an app-extension target means editing `project.pbxproj`,
and this project uses `PBXFileSystemSynchronizedRootGroup` (the newer Xcode
format). The `pbxproj` tooling cannot round-trip that format: a test on a copy
threw and produced a zero-byte file. Xcode's own template does it correctly in
seconds, so that step is left to Xcode rather than risking the project file.

## What is already done

- `ContentProvider.swift` — the extension. Reads the snapshot, shows "On Now",
  deep links to `nostalgex://channel/<id>`. Holds no credentials, makes no
  network calls to the user's server, contains no scheduling logic.
- `Info.plist` — the `com.apple.tv-top-shelf` extension point.
- `Nostalgex.entitlements` / `TopShelf.entitlements` — App Group membership for
  the app and the extension.
- App side (already in the main target, already building and shipping safely):
  - `Services/TopShelfSnapshot.swift` — the shared model and the read/write
    store. Writing no-ops cleanly until the App Group exists, so this is
    harmless in the current build.
  - `AppState+Schedule.swift` → `refreshTopShelfSnapshot()` builds the snapshot.
  - `AppState+Library.swift` calls it when a library load completes, which is
    when the lineup actually changes.

## Remaining manual step

**One:** confirm the App Group is added to *both* targets in Xcode. Project icon
→ TARGETS → Signing & Capabilities → App Groups → `group.com.muellhaus.nostalgex`.
Xcode registers the group and updates provisioning; this cannot be done through
the App Store Connect API (no `appGroups` endpoint, verified 404).

Everything else is wired: the target exists, both entitlements files are in
place and referenced, and the extension compiles and embeds as
`Nostalgex.app/PlugIns/TopShelf.appex`.

### Template defaults that were corrected

Xcode's new-target template set three values that would have failed App Store
validation, all now fixed in the project:

| Setting | Template gave | Corrected to | Why |
|---|---|---|---|
| `TVOS_DEPLOYMENT_TARGET` | 26.1 | 18.0 | An extension cannot require a newer tvOS than its host app, and 26.1 would have excluded every Apple TV below it |
| `CURRENT_PROJECT_VERSION` | 1 | 27 | Must match the app's build number |
| `MARKETING_VERSION` | 1.0 | 1.0.12 | Must match the app's version |

## Verifying it

Top Shelf content only renders when Nostalgex is in the **top row** of the Apple
TV home screen and focused. Move it there, open the app once so a library load
writes the snapshot, then go back to the home screen and focus the icon.

`TopShelfStore.read()` returning nil is the designed fallback: tvOS shows the
static Top Shelf image, exactly as it does today.
