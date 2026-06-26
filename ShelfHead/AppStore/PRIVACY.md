# ShelfHead Privacy Policy

_Last updated: June 17, 2026_

ShelfHead is an iOS client for [Audiobookshelf](https://www.audiobookshelf.org), the
self-hosted audiobook and podcast server. ShelfHead connects only to the Audiobookshelf
server **you** configure. This policy explains what data the app handles and where it goes.

## The short version

ShelfHead does not collect, sell, or share your personal data. There are no analytics,
no advertising, and no third-party tracking. The app talks only to your own server.

## What ShelfHead stores on your device

- **Server credentials.** The server address, username, and the authentication tokens
  issued by your server are stored in the iOS **Keychain**, which is encrypted and
  sandboxed to ShelfHead. Your password, if saved for automatic re-login, is also stored
  in the Keychain.
- **App settings and listening state.** Preferences such as playback speed, skip
  intervals, sleep-timer and download options, and per-book resume positions are stored
  locally on the device (in app preferences and, for downloads, in a small manifest file).
- **Downloaded audiobooks.** When you download a title for offline listening, the audio
  files and cover art are saved to the app's private storage on your device. You can
  delete them at any time from the Downloads screen.

This data stays on your device. ShelfHead does not transmit it to the developer or to any
third party.

## What ShelfHead sends to your server

ShelfHead communicates directly with the Audiobookshelf server you specify, using the
Audiobookshelf API, in order to:

- Sign you in and keep your session active.
- Browse your libraries, books, authors, series, collections, and playlists.
- Stream or download audio you are authorized to access.
- Sync your listening progress, bookmarks, and "finished" status back to your server.

What your server does with that information is governed by **your** server and its
operator (which, for a self-hosted server, is typically you). ShelfHead has no access to
your data outside of this direct connection.

## Network connections

ShelfHead connects only to the server address you enter. It uses standard operating-system
networking (HTTPS via URLSession and AVFoundation). Because some users self-host on local
networks or without TLS, the app can also connect to servers over plain HTTP when you
configure such an address; in that case traffic is sent without transport encryption, as
with any HTTP connection, between your device and your server.

## Data the developer receives

None. The developer of ShelfHead does not operate a server, does not receive your
credentials or listening data, and includes no analytics or crash-reporting SDKs that
transmit data off your device.

## Children's privacy

ShelfHead is a general-audience media player and does not knowingly collect any personal
information from anyone, including children.

## Deleting your data

- Use **Sign Out** in Settings to remove your stored credentials and tokens from the device.
- Remove downloaded audiobooks individually or via **Remove All** in Downloads.
- Deleting the app removes all locally stored ShelfHead data from your device.

## Changes to this policy

If this policy changes, the "Last updated" date above will be revised and the updated
policy will be posted at the same URL.

## Contact

Questions about this policy can be raised as an issue on the project's GitHub
repository (https://github.com/Juzzycooks/ShelfHead/issues) or sent to:
**263102983+juzzycooks@users.noreply.github.com**
