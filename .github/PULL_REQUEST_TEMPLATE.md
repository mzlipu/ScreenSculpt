## What and why

<!-- What changes, and what problem it solves. Link the issue if there is one. -->

## Testing

<!-- How you verified this. Note anything that needed real hardware — capture on
     mixed-scale displays, permission flows, hotkeys, scroll driving — since none
     of that can run in CI. -->

- [ ] `make test` passes
- [ ] `swiftlint --strict` passes
- [ ] Tested by hand on: <!-- e.g. M4 2x internal + 1x external -->

## Checklist

- [ ] Commits are signed off (`git commit -s`) — DCO, no CLA
- [ ] Conventional Commit messages
- [ ] No `.xcodeproj` committed (edit `project.yml` instead)
- [ ] Lengths use the tagged types; no bare `Double` crossing a unit boundary
- [ ] No `import AppKit` added to a compute module
