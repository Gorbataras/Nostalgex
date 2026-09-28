# tvOS platform features — scope for 1.0.12

Scoping pass on the five platform features from the 2026-09-02 audit's Missing list.
Every claim here was checked against the code or compiled against the tvOS SDK, not
assumed. Read the verdicts before planning: one of the five is **not buildable** and
another needs its existing spec corrected.

**Recommended for 1.0.12:** Now Playing Info Center, accessibility pass, iCloud
preference sync. **Defer:** Top Shelf (own release, touches signing). **Drop:**
rating prompt (no API exists on tvOS).

---

## 1. Top Shelf extension

**Verdict: buildable, but it is its own release. Defer past 1.0.12.**

The hard part is already done. `DailyManifestFile` (`Services/DailyManifestStore.swift`)
persists `blocks: [StoredManifestBlock]`, each carrying `ratingKey`, `startUnix` and
`endUnix`, per channel per day. "What is on channel 12 right now" is a time lookup
against a file on disk. No network, no library scan, no Plex round-trip. That is
exactly the shape a Top Shelf provider needs.

What is missing is plumbing, and it is the invasive kind:

| Blocker | Detail |
|---|---|
| No extension target | The project has four targets (app, tests, UI tests, TelemetryDeck). Existing targets use `PBXFileSystemSynchronizedRootGroup`, so source files are picked up automatically, but **adding a new target still means editing `project.pbxproj` by hand.** |
| No App Group | `git grep application-groups` returns nothing and there are **zero `.entitlements` files** in the project. The manifest lives in the app's Application Support container, which an extension cannot read. |
| Manifest has no display data | Blocks store `ratingKey` only. Titles and artwork live in the library snapshot, and `thumbnailURL(for:)` needs the server URL and token to build an image URL. |

**Recommended shape.** Do *not* give the extension Keychain access or make it read the
snapshot. On each schedule rebuild, the app writes a small denormalized
`topshelf.json` into the App Group container: per channel, the current and next
programme with title, channel name and a pre-resolved thumbnail URL. The extension
then does no logic at all, holds no credentials, and cannot break if the schedule
internals change.

**Effort:** 2 to 3 days. **Risk:** medium. Adding an App Group and a second target
changes the provisioning profile, which is the one thing that can break signing for
a release you are otherwise ready to ship. That is the argument for keeping it out
of 1.0.12.

---

## 2. Now Playing Info Center

**Verdict: build it. Best value-per-day of the five.**

Today: zero `import MediaPlayer`, no `MPNowPlayingInfoCenter`, no `MPRemoteCommandCenter`,
no `AVAudioSession` configuration. Playback is a raw `AVPlayer` created in
`AppState+Playback.swift`, not an `AVPlayerViewController`, so none of this comes free
and all of it has to be set explicitly.

Everything needed is already in hand at play time: `currentItem` is a `PlexMediaItem`
with title, duration and thumb, and `currentChannel` gives the channel name for the
subtitle line.

**The design question to answer first.** This is simulated live TV. Pause is
*deliberately* disabled: `onPlayPauseCommand` only flashes the OSD, because pausing
would desync the schedule. So decide what the system transport controls should do:

- Safest: publish Now Playing metadata only, and register **no** remote commands, so
  Control Center shows what is airing and nothing can desync it.
- Better, more work: map next/previous track to channel up/down, and leave
  play/pause and seek disabled.

Do not wire `MPRemoteCommandCenter`'s seek handlers at all. A scrub from Control
Center would fight the deterministic schedule.

**Effort:** about a day for metadata-only, plus half a day for channel-change commands.
**Risk:** low. No entitlement, no new target, no signing impact.

---

## 3. Rating prompt

**Verdict: not buildable. Drop it from the release.**

The audit called this "twenty lines". That was wrong, and this scoping pass is where
it got caught. Both rating APIs are unavailable on tvOS. Compiled against the tvOS
SDK to confirm rather than trusting documentation:

```
SKStoreReviewController.requestReview()
  → error: 'SKStoreReviewController' is unavailable in tvOS
  → SKStoreReviewController.h:22  __TVOS_PROHIBITED

@Environment(\.requestReview)          // SwiftUI
  → error: 'requestReview' is unavailable in tvOS
```

There is no in-app rating sheet on tvOS. There is no API to ask for one.

**What already exists.** `Views/BundleManagerView.swift` has a Rate row that opens
`AppStoreLink.productPage`, and it already carries an accessibility hint. The
buildable part of this feature shipped some time ago.

**What could still be built:** a custom nudge after N successful sessions that
deep-links to the product page. It is non-standard, Apple provides no frequency
throttling to lean on, so the app would have to implement its own, and a badly timed
nudge on a TV is more intrusive than on a phone.

**Recommendation:** skip it. The listing has no ratings because the app has few users,
not because the button is missing. Asking the Resend list is free, has no platform
restriction, and reaches people who already chose to hear from you.

---

## 4. iCloud preference sync

**Verdict: build it, but correct the existing spec first.**

`docs/cloud-sync.md` scoped this at one to two days for about five keys. The effort
estimate holds. One row of its table is wrong and would be a security regression if
implemented as written.

**The correction.** The doc lists `plex_token` as "Sync? Yes". Credentials are not in
UserDefaults, they are Keychain items, and neither the syncable nor the device-local
write sets `kSecAttrSynchronizable`. Putting a media-server token into
`NSUbiquitousKeyValueStore` would move a credential into iCloud in clear text.
**Sync preferences only. Let each Apple TV sign in once.**

Of the 19 UserDefaults keys in the app, only these are user preferences worth syncing:

| Sync | Do not sync |
|---|---|
| `nostalgex_enabled_bundles` | `plex90_client_id` (per device by definition) |
| `nostalgex_enabled_collections` | `nostalgex_last_load_at_unix`, `nostalgex_last_scan_date` |
| `nostalgex_retro_mode` | `nostalgex_keychain_load_statuses`, `nostalgex_keychain_write_unverified` |
| `nostalgex_stream_quality` | `nostalgex_consecutive_invalid_verdicts`, `nostalgex_consecutive_unauthorized_loads` |
| `nostalgex_audio_language`, `nostalgex_subtitle_language` | `nostalgex_completed_initial_load`, `nostalgex_has_held_sign_in` |
| `nostalgex_subtitles_fullscreen`, `nostalgex_auto_subs_foreign_audio` | `nostalgex_last_signout_notice` |
| `nostalgex_sync_plex_activity` | |

Syncing any of the right-hand column would carry one device's diagnostic state onto
another and confuse the sign-in loss diagnostics that were added in build 23.

**Also worth knowing:** the doc's observation that two Apple TVs already show the same
programme at the same time still holds, because the schedule is deterministic from
date and channel id. Only the setup has to sync, never the schedule.

**Effort:** about a day, plus real testing across two devices. **Risk:** low to medium.
Needs the iCloud capability, which is an entitlement change, which touches provisioning.
If Top Shelf is deferred for that reason, consider pairing these two into one release
so the signing change happens once.

---

## 5. Accessibility and localization

**Verdict: do accessibility. Defer localization until the data says otherwise.**

These were one line in the audit and they are not one job.

**Accessibility — do it.** 12 `accessibilityLabel`/`accessibilityHint` uses across 10
view files. The app is entirely focus-driven, which is the good news: the focus engine
already provides structure, so the work is naming things rather than rebuilding
navigation. Highest value on the channel guide, the Now Playing panel and settings.
Incremental, low risk, no entitlement, and it can land view by view without a big-bang
change. **1 to 2 days for a solid pass.**

**Localization — defer, and let data decide.** Zero strings are externalized: no
`.xcstrings` catalog, no `.lproj`, no `NSLocalizedString`. The surface is roughly 57
`Text("…")` literals plus around 243 capitalized string literals across the view layer.
Extraction alone is 1 to 2 days, and that produces an English catalogue, not a
translated app. Translation is a cost decision.

**Before spending anything on this, look at the data you already collect.**
TelemetryDeck attaches `locale`, `region`, `appLanguage` and `preferredLanguage` to
every signal automatically (confirmed in `Signals/Signal.swift`). The question "do
non-English users exist in meaningful numbers" is already answerable from the
dashboard. Answer it first.

---

## Suggested cut for 1.0.12

| Feature | In? | Why |
|---|---|---|
| Now Playing Info Center | Yes | Highest value per day, no signing impact |
| Accessibility pass | Yes | Incremental, low risk, lands view by view |
| iCloud preference sync | Yes, if you want one entitlement change | Spec corrected above; sync preferences, never the token |
| Top Shelf | No | Own release. New target plus App Group is a provisioning change |
| Rating prompt | No | No API exists on tvOS. Ask the email list instead |
| Localization | No | Check TelemetryDeck locale data before spending |

If you would rather keep 1.0.12 free of any entitlement change, ship Now Playing plus
accessibility, and pair iCloud sync with Top Shelf in 1.0.13 so provisioning moves once.
