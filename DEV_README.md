# CowMeme — Developer Notes

Internal notes for developing CowMeme. Not shipped guidance for end users
(see README.md for that); this is where we track our own conventions.

## Versioning

The version in `CowMeme.toc` is always bumped for every release, regardless
of what kind of release it is — there's no such thing as re-shipping the same
version number under a different label.

Every release is tagged as a **beta**. There is no separate "release-" track:
e.g. the next release is `1.4.00`, shipped only as `beta-1.4.00` — there will
never be a corresponding `release-1.4.00`.
