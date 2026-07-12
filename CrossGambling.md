# CrossGambling — "Classic Game" reference

This is a self-contained summary of how CrossGambling's **Classic** game mode works,
written so CowMeme development never needs to open the CrossGambling source again.
It covers the two data planes CrossGambling exposes, the full game lifecycle, the
exact wire formats, and how CowMeme's two modules ([CopyPasta](CowMeme_CopyPasta.lua)
and [GambaRoster](CowMeme_GambaRoster.lua)) hook into each plane.

CrossGambling source (for provenance only, not needed going forward):
`C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\CrossGambling`

---

## 1. The two data planes

CrossGambling emits information two ways. CowMeme deliberately uses a different plane
in each of its modules.

| Plane | Transport | Who emits | CowMeme consumer | Trust |
|-------|-----------|-----------|------------------|-------|
| **Visible chat** | `SendChatMessage` to PARTY/RAID/GUILD (+ Blizzard `/roll` system messages) | The **host** only | **CopyPasta** — loose, human-visible tracking | Fakeable; anyone can type a matching line |
| **Addon comm** | `CHAT_MSG_ADDON`, prefix `CrossGambling` | Host broadcasts; every client's CrossGambling relays roster | **GambaRoster** — authoritative signup roster | Real; only CrossGambling emits it |

Key design consequence CowMeme relies on: **both planes are shared-observable.** Every
group member sees the same host chat lines and the same addon-comm broadcasts, so each
CowMeme client can compute panel state locally and independently — no CowMeme-to-CowMeme
syncing of game state is needed.

### ⚠️ The `chatframeOption` caveat (host-side)

CrossGambling has an in-addon chat panel (a toggle `>`/`<` button on its window). While
that panel is **open**, the host's `game.chatframeOption` flips to `false` and **all the
"visible" lines below are redirected into addon-comm `CHAT_MSG:...` messages instead of
real chat.** In that state CopyPasta sees nothing (GambaRoster still works — it's on the
addon-comm plane regardless). CopyPasta therefore only functions when the **host** runs
with the CrossGambling chat panel closed (the default: `chatframeOption = true`).

---

## 2. Game states

CrossGambling's `game.state` is one of three values, advanced by the host:

```
START  →  REGISTER  →  ROLL  →  (back to START on close)
```

- **START** — idle. Pressing "New Game" moves the host to REGISTER.
- **REGISTER** — signups open. Host listens to party/raid/guild chat for the join word.
- **ROLL** — entries closed. Host listens to `CHAT_MSG_SYSTEM` for `/roll` results.
- On completion (or a tie chain resolving) the host closes back to START.

Only the **host** owns authoritative state and result computation. Clients mirror a roster
and display via addon-comm; they never compute the winner.

---

## 3. Addon-comm protocol

- **Prefix:** `CrossGambling` (registered via `C_ChatInfo.RegisterAddonMessagePrefix`).
- **Send:** `ChatThrottleLib:SendAddonMessage("BULK", "CrossGambling", msg, chatMethod)`.
- **Channel (`chatMethod`):** one of `PARTY` (default), `RAID`, `GUILD`. In RAID mode the
  host also reads `CHAT_MSG_INSTANCE_CHAT`. Addon messages ride the same channel as the game.
- **Message shape:** colon-delimited — `EVENT`, `EVENT:arg`, or `EVENT:arg1:arg2`. Parsed
  with `strsplit(":", msg)`.

### Events, in lifecycle order

| Message | Args | Emitted when | Effect on receivers |
|---------|------|--------------|---------------------|
| `R_NewGame` | — | Host presses "New Game" | Clears client GUI player list |
| `New_Game` | — | Host presses "New Game" | Client enters REGISTER, starts listening |
| `SET_WAGER:<n>` | wager (max roll / stake), e.g. `1000` | Host presses "New Game" | Sets `wager` (the stake) |
| `GAME_MODE:<name>` | e.g. `Classic` | Host presses "New Game" | Sets game mode |
| `Chat_Method:<ch>` | `PARTY`/`RAID`/`GUILD` | Host presses "New Game" | Sets channel |
| `SET_HOUSE:<n>` | house cut %, e.g. `10` | Host presses "New Game" | Sets house cut |
| `ADD_PLAYER:<name>` | player name (may carry realm) | Host sees someone type the join word | Adds player to roster |
| `Remove_Player:<name>` | player name | Host sees someone type the leave word | Removes player from roster |
| `Disable_Join` | — | Host presses "Start Rolling" | Entries closed; join button disabled → **roll phase begins** |
| `PLAYER_ROLL:<name>:<roll>` | name, roll value | Host records a valid roll | Client shows that player's roll in CG's list |
| `CHAT_MSG:<...>` | free text | In-addon chat panel / `chatframeOption=false` redirects | Rendered in CG's own chat panel only |

Notes:
- The **host is the only sender** of `ADD_PLAYER`/`Remove_Player`/`Disable_Join`/`PLAYER_ROLL`.
  Joining works by a player *typing the join word in real chat*; only the host's chat handler
  sees it and rebroadcasts the authoritative `ADD_PLAYER`. This is why GambaRoster trusts these.
- `New_Game` and `R_NewGame` are both sent at game start; treat either as "new game, clear roster."
- There is **no explicit game-over addon message.** The next `New_Game`/`R_NewGame` is the
  reset signal. (CopyPasta instead ends its tracking on the host's visible "owes" line.)

---

## 4. Visible chat lines (the CopyPasta plane)

These are the exact strings the host sends to real chat (when `chatframeOption = true`).
The join/leave words default to `1` / `-1` but are configurable (`db.global.joinWord` /
`leaveWord`); the "owes"/"rolls"/"Wager" wording is fixed.

**Game open (host, from `GameStart`):**
```
CrossGambling: A new game has been started! Type 1 to join! (-1 to withdraw)
```
CopyPasta matches the leading substring `CrossGambling: A new game has been started!`
and records the **sender as the host** for the rest of the game.

**Stake announcement (host, immediately after):**
```
Game Mode - Classic - Wager - 1,000g
```
or, with house cut enabled:
```
Game Mode - Classic - Wager - 1,000g - House Cut - 10%
```
The wager is comma-grouped by CrossGambling's `addCommas` (>3 digits). CopyPasta parses
`Wager %- ([%d,]+)g` and **strips commas** to get the stake. This is the only place the
stake appears in visible chat.

**Players join/leave:** the joiners literally type `1` (or `-1`) in party/raid/guild chat.
These are ordinary player chat lines, not host output. CopyPasta does **not** use these
(GambaRoster gets signups authoritatively via `ADD_PLAYER`).

**Last call (host, optional button):**
```
Last Call to Enter
```

**Entries closed / roll phase (host, from `START_ROLLS`):**
```
Entries have closed. Roll now!
```
CopyPasta gates roll counting on this line **from the host**. (On the addon-comm plane, the
equivalent signal is `Disable_Join`, which GambaRoster uses.)

**Roll results:** Blizzard system messages (`CHAT_MSG_SYSTEM`), one per `/roll`:
```
Playername rolls 47 (1-1000)
```
Parsed as `^(%S+) rolls (%d+) %((%d+)%-(%d+)%)$`. A roll only counts toward the game when
`min == 1` and `max == wager` (the stake). First roll per player counts; rerolls ignored.

**Tie-breaker (host):**
```
High tie breaker! Alice and Bob /roll 1000 now!
Low tie breaker! Carol and Dave /roll 1000 now!
```
Tied players re-roll; the same roll-counting rules apply until the tie resolves.

**Result (host, from `CloseGame`) — the pasta trigger:**
```
Loser owes Winner 953 g!
```
or with a house cut:
```
Loser owes Winner 858 g! plus 95 to the guild
```
`amountOwed = winnerRoll − loserRoll` (minus the floored house cut if enabled), comma-grouped.
CopyPasta matches `(%S+) owes ` **from the host** as the end-of-game / loser signal, echoes
the full line into the panel header, fires the pasta, and resets its game state. If nobody
qualifies:
```
No winners this round!
```

---

## 5. Classic roll rules (authoritative, from `ClassicMode`)

- A roll is valid only if it is exactly `(1-<wager>)` — i.e. `min == 1` **and** `max == wager`.
  Rolls at any other range are ignored (this is how a `/roll` for a different amount, or a
  default `/roll` of `1-100` when the stake isn't 100, gets filtered out).
- **First roll per player** is locked in; later rolls by the same player are ignored.
- When every signed-up player has a valid roll, the host computes the result:
  - **Winner** = highest roll, **loser** = lowest roll, `amountOwed = winner − loser`.
  - Multiple players sharing the high (or low) roll → a **tie-breaker** re-roll among just
    those players; repeats until unique.
  - House cut (if on) = `floor(amountOwed × houseCut/100)`, subtracted from the payout and
    credited to "guild".
- Then the host closes the game (state → START, roster cleared).

---

## 6. How CowMeme maps onto this

### CopyPasta ([CowMeme_CopyPasta.lua](CowMeme_CopyPasta.lua)) — visible-chat plane
Watches `CHAT_MSG_SAY/YELL/PARTY/RAID/GUILD/CHANNEL` and `CHAT_MSG_SYSTEM`:
1. **Start line** → `activeHost = sender`, reset stake/rolls/header.
2. **`Game Mode … Wager - Ng`** from `activeHost` → `gambaStake` (commas stripped).
3. **`Entries have closed. Roll now!`** from `activeHost` → `rollsOpen = true` (rolls now count).
4. **System `… rolls N (1-stake)`** while `rollsOpen`, `min==1`, `max==stake` → track top/bottom.
5. **`<name> owes …`** from `activeHost` → echo header, fire pasta on the matched player
   (or a default card if unregistered), then end the game (`activeHost=nil`, etc.).

Loose by design: rolls are fakeable and that's acceptable — this plane is for the memey
panel/pasta, not accounting.

### GambaRoster ([CowMeme_GambaRoster.lua](CowMeme_GambaRoster.lua)) — addon-comm plane
Listens on `CHAT_MSG_ADDON` prefix `CrossGambling`, plus `CHAT_MSG_SYSTEM` for roll matching:
- `New_Game` / `R_NewGame` → clear roster.
- `SET_WAGER:<n>` → stake.
- `ADD_PLAYER:<name>` → authoritative signup.
- `Remove_Player:<name>` → withdrawal.
- `Disable_Join` → entries closed → roll phase (start marking who has rolled).
- System `… rolls N (1-stake)` → mark that signup as rolled.

Authoritative by design: this is the real signup list, so CowMeme can tell exactly who
signed up but hasn't rolled yet and nudge them. It intentionally does **not** touch how
rolls are otherwise tracked/faked in CopyPasta.

---

## 7. Quick reference — string constants

| Purpose | Exact match CowMeme uses | Plane | Sender |
|---------|--------------------------|-------|--------|
| New game | `CrossGambling: A new game has been started!` (substring) | chat | host |
| Stake | `Wager %- ([%d,]+)g` (pattern) | chat | host |
| Entries closed | `Entries have closed. Roll now!` (substring) | chat | host |
| Result / loser | `(%S+) owes ` (pattern) | chat | host |
| Roll result | `^(%S+) rolls (%d+) %((%d+)%-(%d+)%)$` (pattern) | system | Blizzard |
| New game | `New_Game` / `R_NewGame` | addon comm | host |
| Stake | `SET_WAGER:<n>` | addon comm | host |
| Signup | `ADD_PLAYER:<name>` | addon comm | host |
| Withdraw | `Remove_Player:<name>` | addon comm | host |
| Entries closed | `Disable_Join` | addon comm | host |

Defaults: wager `1000`, house cut `10%`, channel `PARTY`, join/leave words `1`/`-1`,
mode `Classic`. Names on the wire may include a `-Realm` suffix; strip it (`^([^%-]+)`).
