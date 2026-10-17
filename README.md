# Lori's List for iPhone

The iPhone and iPad app for [Lori's List](https://lorislist.horinetech.com), the shopping-list site in
[horinezachary/shoppingList](https://github.com/horinezachary/shoppingList). It uses that project's JSON
API (`/api/v1`) and carries over the website's look: grey page, white cards, rows in each list's own
colour, and the blue gradient bar.

It does what the website does: sign in or register, make lists with a name and colour, add items with
an optional quantity, tap to cross items off, clear the crossed-off ones, share a list by email
(edit or view), leave a list shared with you, and manage your account. It also lists the devices you
are signed in on, which the website cannot, so a lost phone can be signed out.

## Build it

You need a Mac with Xcode 15 or later (iOS 16+ target).

```sh
brew install xcodegen
xcodegen generate        # writes LorisList.xcodeproj from project.yml
open LorisList.xcodeproj
```

Pick a simulator and run. To run on a device, set your team under Signing & Capabilities. The bundle ID
is `dev.horine.lorislist`.

The `.xcodeproj` is generated and not committed, so there are no project-file merge conflicts. Add a
Swift file under `LorisList/` and run `xcodegen generate` again.

**To point the app at another server**, change `LorisListAPIBaseURL` in `project.yml` and regenerate.

## Tests

```sh
swift test
```

This needs no Xcode project or simulator. The tests run the real API client against responses
recorded from the server's own API code (`Tests/LorisListKitTests/Fixtures`), so they fail if the
server's JSON and the app drift apart. Re-record them with `scripts/capture-fixtures.js` (see the
comments in that file).

## How it is put together

```
Sources/LorisListKit/   Everything that is not UI. A Swift package, testable on its own.
  APIClient.swift         Talks to the API; signs in, refreshes tokens, maps errors
  Models.swift            List, item, user, device, invitation
  TokenStore.swift        Keychain storage for the two sign-in tokens
  ListLogic.swift         Mine/shared split, colours, input checks, suggestions
  APIError.swift          Error codes and the text shown to people
LorisList/              The SwiftUI app
  App/                    App entry, session state, navigation
  Design/                 Colours, cards, buttons, form pieces (the website's look)
  Features/               Auth, Lists, ListDetail, Account
Tests/LorisListKitTests/ Contract and behaviour tests, plus the recorded fixtures
project.yml             XcodeGen project definition
```

### Things the API does that you need to know

These were found by running the server's code, and the client depends on them:

- **One access token per device.** Refreshing replaces it and the old one stops working at once. So
  the client refreshes *single-flight*: when several requests fail together, one refresh happens and
  the rest reuse it. A request that failed with a token that was already replaced is just retried.
- **The refresh response is only `{accessToken, tokenType, expiresIn}`.** The written docs say it also
  has the user and a refresh token; the server does not send them. The refresh token stays valid and
  the client keeps its own.
- **A refresh the server refuses (401) ends the session.** A refresh that fails because the phone is
  offline or the server is down does not: you stay signed in.
- `lastChange` on a list is documented as an ISO date string, but the server passes the database value
  straight through, and the test database sends milliseconds. The client accepts either, and null.
- List colours may come back in either case (`ff9900` or `FF9900`).

### Design notes

- The app is drawn in light mode only, like the website.
- Text on a list's colour switches between white and near-black so it stays readable on light colours
  such as yellow (the website always uses one colour).
- Edit, delete and unsubscribe are in a `…` menu on each list row instead of two buttons, which would
  not fit on a phone.
- Crossed-off items are grey with a line through them, as on the website.

## Links from emails

Invitation (`/share/<key>`) and password-reset (`/passwordReset/<token>`) links open in the app
instead of Safari. Two things make that work, and both need you:

1. **The server vouches for the app.** Put your Apple Team ID in the server's `config.js`:
   `appLinks.ios.appIds: ['ABCDE12345.dev.horine.lorislist']` (Team ID, a dot, the bundle id). The
   server then serves `/.well-known/apple-app-site-association`.
2. **The app declares the domain.** `project.yml` adds the Associated Domains entitlement
   `applinks:lorislist.horinetech.com`. Signing with it needs a paid Apple Developer account;
   a free account can't use that capability on a device.

Until both are in place the links keep opening the website, which still works. iOS only checks the
association file when the app is installed, so after changing it, delete and reinstall the app to
test. Parsing lives in `AppLink.swift` (tested); the screens are in `Features/Auth/LinkSheets.swift`.
An invitation opened while signed out waits: the sign-in screen says so and the invitation appears
after sign-in.

## Not done yet

- **Live updates.** The API has no push yet. The app reloads when you open it, pull to refresh, and
  when it returns to the foreground.
- **Offline use.** Lists are fetched, not stored on the phone.
