# Privacy Policy

Effective: September 2, 2026

Nostalgex turns your own Plex, Jellyfin, or Emby library into live TV channels. We do not host, supply, or stream any media. Everything you watch comes off your own server.

This policy covers two separate things: the Nostalgex app on Apple TV, and the nostalgex.app website. They collect different things, so they are described separately.

## Summary

- No accounts. No ads. Nothing is sold or rented to anyone.
- Your server address and login token stay on your Apple TV.
- The app sends a small, fixed list of anonymous usage events so we can tell whether things are working. No names, no library contents, no titles.
- The website uses two lightweight analytics scripts to count page visits.
- Nothing we collect follows you into other companies' apps or across the web.

## The app: what it sends

Nostalgex sends anonymous usage events to [TelemetryDeck](https://telemetrydeck.com), a privacy-focused analytics service. This is the complete list of events the app can send. There are seven, and there are no others:

- A server connection was started
- A server connection finished, with the number of servers found
- A server connection failed, with a short reason code (for example `no_reachable_server` or `jellyfin_auth_failed`)
- A library finished loading, with the number of channels, the number of items, and whether it happened in the background
- A library failed to load, with a short error reason
- A channel was tuned, with the channel number
- Playback started, with the channel number

## The app: what it never sends

- Your name, email address, or any account details
- Your Plex, Jellyfin, or Emby username, password, or token
- Your server address, hostname, or IP address
- Your library contents. No titles, no filenames, no posters, no watch history
- Any advertising identifier, and nothing that lets anyone track you across other apps or websites

## The app: how events are grouped

Every event carries an anonymous device identifier so one Apple TV's events can be counted as one device instead of many. It comes from Apple's vendor identifier, which is specific to us and is not shared with other developers. It is hashed on your device before it leaves, and TelemetryDeck hashes it again on arrival. It cannot be turned back into you, and it resets if you delete the app.

Alongside each event, the analytics library also records ordinary technical details: app version and build number, tvOS version, Apple TV model, platform and architecture, language and region, and whether the build came from the App Store, TestFlight, or a debug run.

## The website

Three pages on nostalgex.app load two analytics scripts, Data Haus (our own) and statsngraphs: the home page, the connect page, and the support page. They count page visits, referrers, and basic device and country information. They do not use advertising cookies and do not build a profile of you across other sites.

The web tuner itself loads neither. Once you are connected and watching, no analytics script is running on the page, so nothing about your library or what you play is measured. The privacy policy page does not load them either. All of this is separate from the app, and nothing from the app is joined to anything from the website.

## What the app stores on your device

Nostalgex keeps your setup on your Apple TV so you do not have to sign in again:

- Your server address and login token, stored in the device Keychain
- Which server type you connected to, and your Jellyfin or Emby user ID
- Your channel and bundle preferences, retro mode, subtitle and audio language settings, and the date of your last library scan
- A cached copy of your channel guide, and a short list of what is on now for the Apple TV home screen. Both are titles and artwork links from your own library, kept in the app's cache on the device

This stays on your device. It is not synced to us, and it is removed when you delete the app.

## Services the app connects to

- Your own Plex, Jellyfin, or Emby server, for the library and for playback
- plex.tv, for Plex sign-in using Plex's own PIN flow. That is Plex's system, not ours
- TMDB (The Movie Database) and OMDb, for public movie and TV metadata used to sort titles onto the right channels
- MusicBrainz, for public music metadata used by the music video channels
- A Supabase database we run, which caches the metadata above so it does not have to be fetched again on every device

These lookups use public identifiers and titles for the purpose of matching metadata. The Supabase cache is keyed on public TMDB identifiers and holds metadata about films and shows. It does not record who asked for it, and it holds no account, device, or server information.

## Sign-in

Plex sign-in runs through Plex's own PIN system. We never see your Plex username or password. Jellyfin and Emby sign-in goes straight from the app to the server you typed in. Tokens are held in the Keychain on your Apple TV and are never sent to us.

## Plex activity sync

The app can report what you are watching back to your own Plex server, so Continue Watching and play counts stay accurate. This is **off by default** and you turn it on in Settings under Plex Activity. When it is on, the reports go only to your own Plex server. They do not come to us.

## Tracking

Nostalgex does not track you across apps or websites owned by other companies, and does not use data for advertising or ad measurement.

## Data retention

Analytics events are held by TelemetryDeck in aggregate and are not tied to an identifiable person. Website analytics are kept as visit counts. Anything stored on your Apple TV stays there until you remove the app, sign out, or reset the device.

## Your choices

- Deleting Nostalgex removes everything the app stored on your Apple TV, including your server token.
- Plex activity sync is off unless you turn it on, and you can turn it back off at any time.
- If you want your app analytics removed, email us and we will ask TelemetryDeck to delete them.
- If you contact support, you decide what goes in the message.

## Children's privacy

Nostalgex is not directed at children and does not knowingly collect personal information from anyone, including children.

## Changes to this policy

If this policy changes, we'll update it here with a new effective date.

## Contact

Questions about this policy? Reach us at support@nostalgex.app, or through https://www.nostalgex.app/support

Muell Haus Inc.
