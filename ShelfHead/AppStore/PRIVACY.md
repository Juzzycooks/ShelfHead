# ShelfHead Privacy Policy

_Last updated: 11 November 2026_

ShelfHead is an iPhone and Apple Watch app for [Audiobookshelf](https://www.audiobookshelf.org),
the self-hosted audiobook and podcast server. This policy explains what the app stores, what it
sends, and where it sends it.

## The short version

- ShelfHead has no analytics, no advertising and no tracking, and it includes no third-party code.
- The developer does not run a server for this app and receives none of your data.
- The app talks to the Audiobookshelf server you sign in to.
- A few optional features use other services: Apple's iCloud, Audible's public catalogue and
  Hardcover. Each one is off until you turn it on, and each is described below.

## What ShelfHead stores on your device

- **Sign-in details.** Your server address, username, the sign-in tokens your server issues, and any
  custom HTTP headers you add for a reverse proxy are stored in the iOS Keychain. Your password is
  stored there only if you turn on the option to stay signed in. None of this syncs to iCloud
  Keychain; it stays on the device it was entered on.
- **Settings and listening state.** Your preferences, playback positions, playback speed per book,
  the Up Next queue, listening history, your recent library searches, bookmark notes, favourite
  authors and narrators, and profiles for children's accounts.
- **Downloads.** Audio files, ebooks and cover art you download for offline use, stored in the
  app's private storage.
- **Things the app works out from your books.** Transcripts, captions, X-Ray notes, recaps and
  mixtapes. See "Processing on your device" below.
- **A search index.** Book titles, authors, narrators and series are added to Spotlight so you can
  search for a book from the Home Screen. This is on by default and can be turned off in Settings.
  The index is cleared when you sign out or switch accounts.

## What ShelfHead sends to your Audiobookshelf server

ShelfHead talks directly to the server you sign in to, in order to:

- sign you in and keep your session active
- browse your libraries and search them
- stream or download audio, ebooks and covers
- sync your progress, bookmarks and finished status, and report listening sessions (how long you
  listened), which is how your server builds its listening statistics
- keep a live connection open so progress made on another device shows up promptly
- carry out changes you choose to make, such as uploading files, fixing a book's cover, chapters or
  series details, removing a book from Continue Listening, starting a server backup, or (for
  server administrators) creating an account for a child
- ask your server to email an ebook to an e-reader, if you choose Send to E-reader. Your server
  sends that email, to a device address its administrator has set up; ShelfHead does not send it
  and does not keep the address.

With each playback session the app also tells your server which client is playing: the app name
and version, the type of device (for example "iPhone"), the iOS version number, and a device
identifier that Apple provides to apps from the same developer. Your server uses this to list your
devices and sessions. It is not an advertising identifier and ShelfHead does not use it for
anything else.

If your server uses single sign-on, the sign-in page of your identity provider opens in a private
web session inside the app. Custom HTTP headers you add are sent with every request to your server.

What your server does with this information is up to the server and whoever runs it, which for a
self-hosted server is usually you. Podcasts are also played through your server; the app does not
contact podcast publishers itself.

## Optional features that use other services

Everything in this section is off until you turn it on.

### iCloud position backup

If you turn on "Sync positions with iCloud", ShelfHead saves your place in each book to your own
iCloud account, as a fallback for when your server can't be reached. For each book it stores the
book's identifier, your position, the book's length, the time it was saved and the generic name of
the device (for example "iPhone"). Your server address and username are not stored; they are used
only to make a scrambled label that keeps different accounts apart. Turning the setting off stops
further updates. Positions already saved remain in your iCloud account.

### Household

Household lets people you invite see what you choose to share: recommendations, book clubs and,
if you turn it on separately, what you are listening to now. It uses Apple's CloudKit, so the data
is stored in iCloud: in the private storage of the person who created the household, shared only
with the people they invite. Nothing is published publicly.

What is stored there:

- the display name, symbol and colour you choose for yourself
- recommendations you send: the book's title and author, and your note
- book clubs: the book's title and author, the goal, and the posts members write, each with a
  position in the book
- if you turn on "Share what I'm listening to": the title, author and your progress through your
  current book
- a scrambled label made from your server address, used to tell whether two members share a
  server. The address itself is not stored.

Your username, password, sign-in tokens and audio are never stored there. Invitations are sent
through Apple's iCloud sharing, so members may see the name or contact detail attached to each
other's Apple Account. iCloud tells your devices when household data changes; that notification
goes from Apple to your device and not to the developer.

Leaving a household deletes your profile, your "listening now" entry, the recommendations you sent
and the posts you wrote. If you created the household, deleting it removes everything for everyone.

### Listen Together

Listen Together uses Apple's SharePlay. When you start or join a session, the people in it receive
the book's title, author and identifier, the playback position, and a scrambled label made from
your server address (used to check that everyone is on the same server). Audio is not shared: each
person plays the book from the server they are signed in to.

### Release Radar

If you turn on Release Radar, ShelfHead checks Audible's public catalogue for new books in series
you have started. It sends Audible the catalogue numbers of books in those series, and the series
name and author as a search. It does not send an account, your server address or your sign-in
details. Cover images for the results load from Audible's image servers. As with any internet
request, Audible can see your IP address.

### Reading sites (Hardcover)

If you connect a Hardcover account, you paste in a Hardcover access token, which is stored in the
Keychain and sent only to Hardcover. To match your books, ShelfHead sends Hardcover the book's
ISBN or catalogue number, or its title and author. Depending on the options you turn on, it then
sends your reading status, your listening progress, the date you finished and your star rating.
Disconnecting removes the token from your device. Nothing is sent to Hardcover from a child's
profile.

### Cover search

When you fix a missing cover in Library Doctor, your server searches for candidates and ShelfHead
shows them. The preview images load directly from the websites your server found, so those sites
can see your IP address.

Audible, Hardcover and Apple handle what they receive under their own privacy policies.

## Processing on your device

Some features work on the content of your books: transcripts, live captions, caption translation,
search inside a book, X-Ray, questions about a book, recaps and reading aloud. These use Apple's
speech, translation and language features built into iOS:

- Transcripts are made from books you have downloaded, using speech models that iOS downloads from
  Apple and runs on your device. On devices that support it, this is on by default and runs while
  the device is charging. You can turn it off, and delete all transcripts, in Settings.
- X-Ray, questions and recaps use the Apple Intelligence model on your device.
- Translation uses Apple's translation feature, which asks before downloading a language.

ShelfHead does not send your audio, transcripts or questions to the developer or to any
third-party transcription or AI service. What these features produce is stored on your device and
is not uploaded anywhere.

## Apple features ShelfHead works with

- **Siri and CarPlay.** When you ask Siri to play a book, Apple processes your speech and passes
  ShelfHead the title you asked for.
- **Handoff.** The title, identifier and position of the book you are playing are offered to your
  other devices signed in to the same Apple Account.
- **Widgets and Live Activities.** These show the current book, progress, sleep timer and
  downloads on your own device.
- **Apple Watch.** Your iPhone sends your Watch what it needs to show and play your library. So
  that the Watch can connect to your server on its own, the iPhone also passes it your server
  address, custom headers and a sign-in token. Your password is never sent to the Watch.

## Permissions

- **Face ID, Touch ID or passcode:** for App Lock and to protect settings from children's profiles.
  The check is done by iOS; ShelfHead never sees your biometric data.
- **Notifications:** reminders and download notices are created on your device.
- **Local network:** to reach a server on your home network.
- **Siri:** to play books by voice.
- **Photos (add only):** to save a share card you create. ShelfHead cannot read your photo library.
- **Files:** only the files you pick, for uploads and imports.

ShelfHead does not use your microphone, camera, contacts, calendar or location.

## Network security

ShelfHead uses HTTPS when your server offers it. Because some people run their server on a home
network without encryption, the app can also connect over plain HTTP; on iPhone it asks you to
confirm before doing so for a server outside your local network. Traffic sent over HTTP is not
encrypted.

An optional compatibility setting, off by default, adds your sign-in token to streaming addresses.
With it on, the token may appear in your server's or proxy's logs.

## Things you choose to share

Share cards, quote clips, the year in review, mixtape links (which can include quotes from a book),
exported settings and a diagnostics report go only where you send them through the iOS share
sheet. Exports never include passwords, and the diagnostics report has sign-in tokens and server
addresses removed.

## Data the developer receives

None. The developer does not operate a server for ShelfHead, does not receive your sign-in details
or listening data, and includes no analytics or crash-reporting tools that send data off your
device. ShelfHead has no in-app purchases.

## Children's privacy

ShelfHead does not knowingly collect personal information from anyone, including children.

A children's profile in ShelfHead is a label on an Audiobookshelf account on your own server. Its
symbol and colour are stored only on the device, and what a child can see is controlled by your
server. While a child's profile is active, Household sharing is unavailable and nothing is sent to
Hardcover.

## Deleting your data

- **Sign out** in Settings to remove your sign-in details and tokens from the device.
- **Remove downloads** one at a time or all at once from Downloads.
- **Delete transcripts** in Settings.
- **Leave or delete a household** to remove what you shared there.
- **Disconnect Hardcover** to remove its token. Anything already sent to Hardcover stays in your
  Hardcover account until you remove it there.
- **Deleting the app** removes everything stored on the device. It does not remove data on your
  Audiobookshelf server, positions saved to your iCloud account, or household data in iCloud.

## Changes to this policy

If this policy changes, the "Last updated" date above will be revised and the updated policy will
be posted at the same URL.

## Contact

Questions about this policy can be raised as an issue on the project's GitHub repository
(https://github.com/Juzzycooks/ShelfHead/issues) or sent to:
**263102983+juzzycooks@users.noreply.github.com**
