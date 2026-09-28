# Icon + Launch Screen Replacement Guide

The Asset Catalog already has the correct structure for tvOS layered icons + Top Shelf images. You just need to replace the PNG files with the new Nostalgex logo design (neon lightning bolt + glitchy CRT background).

## Files to replace

All paths relative to `Nostalgex/Nostalgex/Assets.xcassets/App Icon & Top Shelf Image.brandassets/`

### App Icon (used on Apple TV home screen)
Layered for parallax effect. tvOS stacks Back behind Middle behind Front, animating depth on focus.

**Sizes (all PNG, no transparency on Back layer):**

| Layer | 1x | 2x | What goes on it |
|---|---|---|---|
| `App Icon.imagestack/Back.imagestacklayer/Content.imageset/icon-back.png` | 400×240 | 800×480 (icon-back@2x.png) | CRT/static background only, no logo |
| `App Icon.imagestack/Middle.imagestacklayer/Content.imageset/` | (currently empty) | (optional) | Optional accent layer |
| `App Icon.imagestack/Front.imagestacklayer/Content.imageset/icon-front.png` | 400×240 | 800×480 (icon-front@2x.png) | Lightning bolt + "NOSTALGEX" text on transparent background |

### App Icon - App Store (used on App Store listing)
Higher-res version. Same layered structure.

| Layer | Size | File |
|---|---|---|
| `App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/icon-store-back.png` | 1280×768 | CRT background only |
| `App Icon - App Store.imagestack/Middle.imagestacklayer/Content.imageset/` | (optional) | |
| `App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/icon-store-front.png` | 1280×768 | Logo on transparent |

### Top Shelf Image (wide banner above app on Apple TV home screen)

| File | Size |
|---|---|
| `Top Shelf Image.imageset/topshelf.png` | 1920×720 |
| `Top Shelf Image.imageset/topshelf@2x.png` | 3840×1440 |
| `Top Shelf Image Wide.imageset/topshelf-wide.png` | 2320×720 |
| `Top Shelf Image Wide.imageset/topshelf-wide@2x.png` | 4640×1440 |

For the Top Shelf you want a wide composition — logo on the left or center, with the CRT background filling the rest. Single-layer PNG (no parallax).

## Easy mode (single-layer icon, no parallax)

If you just want to ship and don't care about the parallax animation:
1. Save the full Nostalgex image (lightning bolt + text + CRT background) at the 4 sizes listed above
2. Drop the same image into BOTH the Front and Back layers (it'll work, just no depth animation)
3. tvOS will still display it correctly

## Better mode (proper parallax)

1. **Background layer** = the glitchy CRT/static texture only, no logo, no text
2. **Foreground layer** = the lightning bolt + "NOSTALGEX" text on a fully transparent PNG
3. tvOS animates the layers when the icon is focused on the home screen

## Replacing the launch screen

Currently the project uses `INFOPLIST_KEY_UILaunchScreen_Generation = YES` which auto-generates a blank black launch screen.

To use the Nostalgex logo as the launch screen:

**Option A: Use the existing NostalgexLogo image**
The launch screen at app open is brief. The auto-generated black launch screen is fine — your custom `LoadingView` shows the logo immediately after.

**Option B: Custom launch image**
1. Drop a 1920×1080 logo PNG into `Nostalgex/Assets.xcassets/` as `LaunchImage.imageset`
2. Open the project in Xcode → target → General → App Icons and Launch Screen → Launch Screen File → set to your image
3. Disable `INFOPLIST_KEY_UILaunchScreen_Generation` in the project's build settings

For first launch, Option A is fine. Skip Option B unless you want a polished branded splash.

## Verify after replacing

1. Clean build folder (⌘⇧K in Xcode)
2. Build and run on Apple TV
3. Quit the app, look at Apple TV home screen — new icon should show
4. Focus the icon — parallax animation if you went with multi-layer
