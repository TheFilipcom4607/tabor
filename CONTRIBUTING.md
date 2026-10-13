# Contributing to TABOR

Issues and pull requests are very welcome. Most of TABOR's fixes started as an
issue from someone who caught a bug on the street. Write in Polish or English,
whichever you like.

## Reporting a bug

[New issue](https://github.com/TheFilipcom4607/tabor/issues/new/choose) offers a
form for each kind of report (a bug, a misread number, a vehicle, an idea), and
each one asks for what's below.

Look through the [issues](https://github.com/TheFilipcom4607/tabor/issues) first,
closed ones too: it may already be fixed in the next build. Then open one issue per
problem, with a title that says what's wrong and where, e.g. "HUNT: the compass
points the wrong way".

What helps most:

- What you did, what happened, and what you expected instead.
- A screenshot or a screen recording. Often it says more than the text.
- The app's version and build, from the bottom of Settings, e.g. `1.2 (37)`.
- Your iPhone model and iOS version, especially for layout bugs: text that doesn't
  fit on one phone can look fine on another.
- For a misread number: the photo, if you're happy to share it, and the number that
  should have been read.

## A wrong or missing vehicle

Say which vehicle and what's wrong, and add a source: a link (Warszawikia,
TransInfo, the KMKM club, tramwar.pl, ZTM's vehicle database), or a photo with the
fleet number on it. If you saw it on the live map, say when and on which line.
Nothing goes into the book without a source.

Vehicles the city adds to its own list usually show up by themselves within a day,
because the fleet data is refreshed every night.

## Ideas

Tell me what you'd use it for, not only what it should look like: that often leads
to a better solution than the first one. TABOR is built by one person in their free
time, so some ideas wait a while, and some don't happen. Every one gets read.

## Pull requests

For anything bigger than a small fix, open an issue first, so we agree on the
approach before you spend your time on it.

- **Building:** see [Install](README.md#install). Set your own team under Signing &
  Capabilities, but leave that change out of the pull request.
- **Tests:** run `swift test` before you send it, and add a test when you change
  something in `Tabor/Core`.
- **Fleet data:** never edit `fleet.json` by hand. Change the lists in
  `scripts/fetch_fleet.py`, run `python3 scripts/fetch_fleet.py --offline`, and
  commit both. A check fails any `fleet.json` the script doesn't build.
- **Text:** anything the app shows needs both English and Polish in
  `Localizable.xcstrings`. Check that the Polish fits on a narrow phone (390 pt).
- **Style:** match the code around your change. Comments explain why, in plain words.
  A commit subject says what the change does, e.g. "Keep the stop list smooth on a
  busy map", and the body says why.
- **Size:** one thing per pull request, with a screenshot for anything you can see.

By sending a pull request, you're OK with your change becoming part of TABOR,
App Store version included.

## License

TABOR's code is public to read and learn from, but it has no open-source license:
all rights are reserved. If you'd like to build something of your own from it, like
TABOR for another city, write to [tabor@thefilip.com](mailto:tabor@thefilip.com)
first. I'm happy to talk.

## Anything private

A security problem, or something you'd rather not post in public? Write to
[tabor@thefilip.com](mailto:tabor@thefilip.com) instead of opening an issue.
