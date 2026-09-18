# Changelog

All notable changes to Dart Radar are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and `make release`
reads the section matching the version being released: it becomes both the
GitHub release notes and the Sparkle feed item's description, so write each
entry for the person who will see it in the update prompt.

## 1.0.1 - 2026-09-19

- Project paths and workspace names in the process list are easier to read.
  Inside a link row the muted styling rendered as a low-contrast blue-grey that
  was hard to make out at caption size.
- The app now carries its own notarization ticket. Previously only the disk
  image was stapled, so a copy dragged out of it had to reach Apple to be
  verified, and a first launch with no network could not be.

## 1.0.0 - 2026-09-18

First release.

- Lists every Dart and Flutter process running on your Mac, with live CPU and
  memory for each.
- Names each process by what it actually does (analyzer, tooling daemon,
  frontend compiler, dev service) rather than by the generic runtime binary.
- Attributes processes to the project and editor window they belong to.
- Lives in the menu bar, with total memory always visible.
