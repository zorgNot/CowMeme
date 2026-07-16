# CowMeme — Developer Notes

Internal notes for developing CowMeme. Not shipped guidance for end users
(see README.md for that); this is where we track our own conventions.

## Versioning

The version in `CowMeme.toc` is always bumped for every release, regardless
of what kind of release it is — there's no such thing as re-shipping the same
version number under a different label.

Every release gets a version bump. There is no separate "release-" track:
e.g. the next release is `1.4.00`, shipped only as `beta-1.4.00` — there will
never be a corresponding `release-1.4.00`.

## Gotcha: raid-target tokens in received chat payloads

A sent `{rt8}` does **not** always arrive as the literal token in `CHAT_MSG_*`
event payloads. The client can deliver it already expanded into its texture
escape — observed on GUILD chat (raid appeared to keep the literal form):

```
{rt8}  ->  |TInterface\TargetingFrame\UI-RaidTargetingIcon_8:0|t
```

Both render identically as the skull icon, so the difference is invisible in
chat and only shows up in a byte dump. Any matching logic against received
messages must accept **both forms** (see `HasSkullMark` in CowMeme_FnC.lua).
Debugged the hard way: milestone sounds silently skipped on the guild channel
because `find("{rt8}")` failed against the expanded payload.
