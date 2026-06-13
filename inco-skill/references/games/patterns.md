# Confidential Game Patterns

These are the reusable *moves* of confidential game design on Inco — cross-cutting techniques you compose to keep hidden information hidden until it should not be; the [archetypes](archetypes.md) are mostly recombinations of them. This file is the **game-design decision**, not API mechanics: for the base Inco API (encrypted types, `e.select`/`e.allow`, fees, attestation, elist, the JS SDK) follow the links to the [main skill page](../../SKILL.md) / base references. Inco is **TEE-based, not FHE**.

> **Loading** — you're here to write contract logic: pair these moves with your one [archetype](archetypes.md); add [settlement-and-math.md](settlement-and-math.md) only for **wager** games, and leave [frontend.md](frontend.md) until you wire the UI. Full per-task order: [overview.md](overview.md#references).

The eight moves:

1. [Confidential randomness](#confidential-randomness)
2. [Encrypted-list state](#encrypted-list-state)
3. [Sticky accumulator](#sticky-accumulator)
4. [Selective reveal via `e.allow`](#selective-reveal)
5. [Silent-failure `.select()`](#silent-failure-select)
6. [Encrypted equality-match / locate](#equality-match)
7. [Encrypted packing (compact fixed records)](#encrypted-packing)
8. [Reveal discipline (minimal disclosure)](#reveal-discipline)

---

## Confidential randomness

**Goal.** Place hidden game elements (bombs, the deck order, a hidden role assignment) so that *no one* — not the player, not the contract deployer, not an on-chain observer — can predict where they landed, while keeping the distribution provably uniform.

**Naïve approach & why it breaks.** The tempting move is to draw randomness one cell at a time: for each bomb, sample an encrypted index and mark that cell, sequentially. This breaks three ways. (1) **Bias** — "sample a position, retry if already taken" is rejection sampling that is hard to do uniformly over encrypted state, and ad-hoc schemes skew placement. (2) **Cost** — you pay for an encrypted random draw and an encrypted write *per bomb*, an O(N) pile of fee-charging Inco ops at board setup. (3) **Packing limits** — devs reach for an 8-bit-packed position to keep it cheap, which silently caps boards at 16×16.

**The move.** Build the board as an **elist** of plaintext-known cell *values* (e.g. `true` for a bomb, `false` for safe), then shuffle the whole list in **one** operation. The randomness is in the *permutation*, not in N separate draws.

```solidity
import {ebool, e, inco, elist, ETypes} from "@inco/lightning/src/Lib.sol";

// Build N bomb cells + M safe cells (values are public; their *positions* will be secret).
bytes32 trueHandle  = ebool.unwrap(e.asEbool(true));
bytes32 falseHandle = ebool.unwrap(e.asEbool(false));
bytes32[] memory bombHandles = new bytes32[](totalBombs);
bytes32[] memory safeHandles = new bytes32[](safeTiles);
for (uint256 i = 0; i < totalBombs; i++) bombHandles[i] = trueHandle;
for (uint256 i = 0; i < safeTiles;  i++) safeHandles[i] = falseHandle;

elist bombs    = e.newEList(bombHandles, ETypes.Bool);
elist safes    = e.newEList(safeHandles, ETypes.Bool);
elist combined = e.concat(bombs, safes);
board = e.shuffle(combined);          // ONE op assigns every position
inco.allow(elist.unwrap(board), address(this));
```

For a card game, `e.shuffledRange(1, 53, ETypes.Uint256)` gives you a shuffled 52-card deck in one call. For a single hidden index (which chest holds the prize), `e.randBounded(n)` returns an encrypted index in `[0, n)`; `e.rand()` returns a full-width encrypted draw.

**Why it works.** A `shuffle` is one uniform permutation over the list, so the marginal distribution of every position is correct *by construction* — there is no rejection loop to bias. The TEE produces the permutation; the resulting `board` handle is opaque to everyone until a specific element is revealed. Cost collapses from O(N) fee-charging draws to a single `shuffle` (the randomness and elist-construction ops — `shuffle`, `shuffledRange`, `rand`/`randBounded`, and ciphertext/element creation — charge a fee; budget `msg.value >= inco.getFee()` for the setup call, and see the base references for the full list of fee-charging calls). And because each cell is a real list element rather than a bit-packed field, board size is bounded by the list, not by 8 bits.

**Pitfalls.**
- **List length is public.** The *number* of bombs and total cells is encoded in the handle and is readable by anyone. Hide *which* cells are bombs, never expect the count to be secret. If the count must be secret, pad the list to a fixed length with decoy values.
- Don't seed randomness from `block.timestamp`/`blockhash` — that's predictable/manipulable; use the TEE's `shuffle`/`rand` family.
- The shuffle output needs `inco.allow(elist.unwrap(board), address(this))` or the contract loses access to its own board next tx (see the base API on `allowThis`).

---

## Encrypted-list state

**Goal.** Store the whole hidden board/deck/hand as a single encrypted structure and read exactly the one element a move touches — in O(1), without revealing the rest.

**Naïve approach & why it breaks.** Modeling hidden state as N separate encrypted variables (`ebool cell0; ebool cell1; …`) and, on each move, scanning them — `e.eq`-ing every cell against the target index and `e.select`-ing the match — costs O(N) encrypted ops *per move*. On a 10×10 board that's 100 encrypted comparisons for a single click. It also makes "the deck" an awkward, ever-growing set of storage slots rather than one object you can shuffle/slice/concat.

**The move.** Keep state in **one `elist`** and look up the touched element by index with `getEbool` / `getEuint256`.

```solidity
// `board` is the shuffled elist from the randomness move.
// Reading position `pos` is a single op — the other cells are untouched and stay hidden.
ebool hit = e.getEbool(board, uint16(pos));
```

The returned `hit` handle is a transient, memory-only handle valid within this transaction — Inco grants it transient access automatically, so no `e.allow` is needed *unless* you persist it across transactions (see [sticky accumulator](#sticky-accumulator), which does persist its accumulator).

**Why it works.** The elist is the secret; indexing it is a direct retrieval, not a search, so per-move cost is constant and independent of board size. You reveal only the element you read, leaving the rest of the structure encrypted. Because it's one object, the same state composes with `concat`, `slice`, `shuffle`, `set`, and `append` (see the base [elist-reference](../elist-reference.md)) — exactly the operations card and board games need.

**Pitfalls.**
- A plaintext index (`pos`) reveals *which* cell was touched — that's usually fine (the player is publicly opening a known square). If *where* a player looked must itself be secret, use the hidden-index variants (`getOr`, `sliceLen`) instead; see the elist reference.
- `getEbool` at a known index does **not** reveal the value — it returns an encrypted handle. Don't conflate "I read the cell" with "I revealed the cell"; revealing is a separate, deliberate step (see [reveal discipline](#reveal-discipline)).
- elist handles are immutable: `set`/`append` return a *new* handle you must store and re-`allow`.

---

## Sticky accumulator

**Goal.** Collapse many secret per-move outcomes into **one** settlement bit (or number) — "did the player ever hit a bomb?", "is the running total still under 21?" — so that final settlement decrypts a single handle instead of replaying the whole game.

**Naïve approach & why it breaks.** At cash-out, re-examine every move: produce a decryption attestation for *each* opened cell and have the contract check them all. That's one attestation round-trip per move (latency and cost that scale with game length), a coordination headache (the client must marshal N handles and N signature sets), and a wider replay/skip surface — miss or reorder one and the settlement check is wrong.

**The move.** Maintain one persistent encrypted accumulator and fold each move into it with a cheap encrypted op (`e.or` for a "did it ever happen" bit, `e.add`/`e.min`/`e.max` for running totals). Update it on **every** move; at settlement, verify exactly **one** attestation over the latest accumulator handle.

```solidity
// Each pick folds this tile's secret outcome into the running bit.
ebool hit = e.getEbool(board, uint16(pos));
everHitBomb = e.or(everHitBomb, hit);   // sticky: once true, stays true
e.allow(everHitBomb, address(this));    // persists across txs — needs cross-tx allow
e.reveal(everHitBomb);                  // queue the post-fold handle for attestation
latestAccumHandle = ebool.unwrap(everHitBomb);
```

```solidity
// Settlement verifies ONE attestation over that single accumulated handle.
require(accumAttestation.handle == latestAccumHandle, "stale attestation");
require(
    inco.incoVerifier().isValidDecryptionAttestation(accumAttestation, signatures),
    "bad sig"
);
require(asBool(accumAttestation.value) == false, "hit a bomb");  // safe to cash out
```

**Why it works.** `e.or` is monotonic: once `everHitBomb` is true it can never go back to false, so the single bit faithfully summarizes the entire history regardless of move order or count. Settlement cost is O(1) in game length — one handle, one attestation, one signature check — and the only fact disclosed is the aggregate verdict, not the per-move trail. Because the accumulator is *stored across transactions* it needs `e.allow(…, address(this))` (unlike the transient per-move `hit` handle); always update `latestAccumHandle` so settlement attests against the freshest value and stale attestations are rejected.

**Scales past a single bit.** The same fold works on a *vector* and on counters. A word-guesser keeps one reveal bit per position — `revealed[i] = e.or(revealed[i], matchedHere[i])` — and derives the win by AND-reducing them: `ebool won = revealed[0]; for (i in 1..N) won = e.and(won, revealed[i]);`. A life counter folds the *opposite* way with a conditional: `lives = e.select(won, lives, e.sub(lives, e.asEuint256(1)))` — decrement unless this move won. Same principle (monotone fold into persisted handles), whether the accumulator is a scalar bit, a vector of bits, or a counter.

**Pitfalls.**
- **Attest the latest handle only.** Each fold produces a new handle; if the client signs an older one, the `handle == latestAccumHandle` guard must reject it. Track and compare the latest handle explicitly.
- Don't reveal the accumulator before settlement needs it — a mid-game "are you still alive?" reveal can leak information the opponent shouldn't have (see [reveal discipline](#reveal-discipline)). Reveal the accumulator and choose the *direction* of the settlement check (`== false` to win vs `== true` to concede) at the settlement call.
- Pick the right fold op for the invariant: `e.or` for "ever happened", `e.and` for "always held", `e.add` for totals, `e.min`/`e.max` for bounds.

---

<a id="selective-reveal"></a>

## Selective reveal via `e.allow`

**Goal.** Make a secret readable to exactly **one** participant — their own hand, their secret role, their fog-of-war vision — while it stays opaque to every other player and to chain observers.

**Naïve approach & why it breaks.** Two tempting wrong turns. (1) Reveal the value on-chain (decrypt-and-emit) "just for that player" — but an on-chain reveal is public, so everyone sees the hand. (2) Encrypt per-player off-chain with a shared password / a key you hand the client — now key distribution and rotation are your problem, and any leak exposes everything with no on-chain access boundary.

**The move.** Keep the value encrypted on-chain and grant **decryption permission** to one address. Only that address can run an attested decrypt on the handle; to everyone else it stays an opaque handle.

```solidity
// `secretRole` is an encrypted scalar handle (e.g. an euint256 / ebool).
// Grant decrypt access to just this player; nobody else can read it.
e.allow(secretRole, player);
// For a hand held as an elist, scope the whole list to its owner:
inco.allow(elist.unwrap(playerHand), player);
```

The player then decrypts client-side via the JS SDK's attested-decrypt flow (see the base [JS SDK reference](../js-sdk-reference.md)) — the contract never emits the plaintext, so the grant *is* the privacy boundary.

**Why it works.** Access control lives at the protocol layer: the TEE will only produce a decryption attestation for an address that was `allow`-ed on that handle. So "who can see this" is an on-chain authorization you set per handle, not a key you have to ship and protect. Reads stay scoped per-recipient — you control visibility by choosing which address to grant — and the secret never touches a public log. Note the boundary is **one-way**: a grant, once made, cannot be revoked (the recipient could even decrypt it publicly), so withhold access you're unsure about rather than planning to claw it back.

**Contrast (and when to reach for something else).** Other hidden-information stacks solve this differently: **mental poker** uses *n-out-of-n* threshold encryption where every player must cooperate to decrypt any card (strong trust-minimization, but heavy protocol and liveness requirements — one player stalling blocks the table). **zk commitments** publish a static commitment to a hidden value and later prove statements about it (great for one-shot sealed values, but awkward for long-lived, mutating, per-player state like an evolving hand). Inco's `e.allow` gives you live, mutable, per-recipient reads with a TEE trust assumption and no per-move proof. Which trust model fits your game is a design call — see [choosing-your-approach.md](choosing-your-approach.md).

**Pitfalls.**
- A grant is **per handle**. The moment you derive a new handle (deal a card, mutate the hand), you must `e.allow` the *new* handle to the player or they lose visibility.
- Granting to `address(this)` (contract access) and granting to a player (read access) are different intents — see the base API on `allow` vs `allowThis`. Granting one does not grant the other.
- Don't accidentally `allow` a secret to an opponent or to `tx.origin`/`msg.sender` in a shared call path — that's a one-line information leak.
- **Reading a per-player grant needs a wallet signature.** Unlike a public `e.reveal`, the granted handle is read client-side with `attestedDecrypt`, which signs per call. It works fine as-is; but for state a player peeks at repeatedly (a hand, a role), a **session-key allowance voucher** is a nice UX upgrade — sign once, then reads are popup-free. Optional, see [frontend.md §4](frontend.md#4-private-per-player-decryption-the-allowance-voucher).

---

## Silent-failure `.select()`

**Goal.** Resolve a move whose *outcome* must stay hidden without letting the control flow leak it — a revert, a different gas trace, or an emitted error all betray the secret.

**Naïve approach & why it breaks.** `if (encryptedCondition) { … } else { … }` or `require(encryptedCondition)`. You can't branch on an encrypted condition (it's an opaque handle, not a bool), and even if you could, a revert-on-loss publicly announces "this player lost" — the failure path *is* the leak.

**The move.** Compute both branches and multiplex with `cond.select(ifTrue, ifFalse)` so the same code path always runs and only the *value* differs. The base mechanic lives in the base API (see the [`e.select` / multiplexer section](../../SKILL.md)); the *game* point is to make the losing and winning outcomes **indistinguishable**.

```solidity
// Pay out the bet on a win, but on a loss transfer 0 instead of reverting.
// On-chain it looks identical either way — the loss is hidden, not announced.
ebool won = /* encrypted game outcome */;
euint256 payout = won.select(betPayout, e.asEuint256(0));
```

**Why it works.** Both outcomes execute the identical instruction sequence; the TEE selects the result without revealing which branch "won". No revert, no divergent log, no branch-dependent gas tell — so an observer can't infer the secret from the transaction's shape. Transferring 0 is the game-design idiom for "fail silently": the move always succeeds mechanically, only the encrypted amount encodes win vs loss.

**Pitfalls.**
- Don't reintroduce the leak downstream by `require`-ing or revealing the selected value mid-game — that undoes the whole point. Defer any reveal to settlement under [reveal discipline](#reveal-discipline).
- Both branches always run, so both must be valid/affordable to compute — there's no short-circuit.
- `.select()` also does **format normalization without branching**: case-folding an encrypted byte — `slot = e.select(e.le(slot, e.asEuint256(90)), e.add(slot, e.asEuint256(32)), slot)` (ASCII A–Z → a–z) — runs the identical path for upper- and lower-case inputs, leaking neither which case was supplied nor the byte itself. This is the canonical way to normalize a guess before an [equality-match](#equality-match) so case/format can't cause a silent mismatch.

---

<a id="equality-match"></a>

## Encrypted equality-match / locate

**Goal.** Test a guess/candidate against one or more *hidden* values and encode the result (matched? which slot?) without branching on ciphertext.

**Naïve approach & why it breaks.** `if (guess == secret) { ... }` — you can't branch on an encrypted condition, and a revert/divergent log on a miss announces the answer. Scanning the slots and revealing each comparison leaks the secret piece by piece.

**The move.** Compare with `e.eq` against each hidden slot, and fold the per-slot match bits into an encrypted *result* with chained `e.select` — e.g. encode *which* slot matched (1..N) or a sentinel (none) — all in-TEE, revealing nothing until you deliberately reveal/allow the result.

```solidity
// Hidden target held as per-slot encrypted chars; `guess` is a plaintext code point.
// Encode the matched position (1..N) or a sentinel (100 = no match) — no plaintext branch.
euint256 result = e.asEuint256(100);                 // sentinel: "not found"
for (uint8 i = 0; i < N; i++) {
    ebool isMatch = e.eq(slots[i], e.asEuint256(guess));
    // first match wins: set result to i+1 only while it's still the sentinel
    result = e.select(e.and(isMatch, e.eq(result, e.asEuint256(100))), e.asEuint256(i + 1), result);
}
```

**Why it works.** Equality and the multiplexed encode run entirely in-TEE; the located position is itself an encrypted handle, so nothing leaks until a chosen reveal (public `e.reveal`) or per-player grant (`e.allow`, [selective reveal](#selective-reveal)). This is the engine of guess-and-match games (Hangman, Mastermind, "guess the code") — see [archetype 8](archetypes.md#8-hidden-word--code-guess-and-match).

**Pitfalls.**
- **Normalize *inside* encrypted compute**, not in plaintext, so case/format can't leak or cause silent mismatches. The case-fold idiom is `select`-based: `ebool isUpper = e.le(slot, e.asEuint256(90)); slot = e.select(isUpper, e.add(slot, e.asEuint256(32)), slot);` (ASCII A–Z → a–z).
- The **number of slots is public** (loop bound) — hide the values, not the arity.
- Pick a **sentinel outside the valid range** (here 100 for a 1..N position) so "no match" is unambiguous.

---

<a id="encrypted-packing"></a>

## Encrypted packing (compact fixed records)

**Goal.** Store a small, fixed set of secret fields in **one** encrypted handle cheaply — a short word, a hand summary, a flags bitset.

**The move.** Pack the fields into a single `euint256` and unpack on demand with `e.shr` + `e.and(mask)`:

```solidity
// Unpack 4 bytes from one packed euint256 word into 4 encrypted slots.
euint256 mask = e.asEuint256(0xff);
for (uint8 i = 0; i < 4; i++) {
    euint256 slot = e.and(e.shr(packedWord, e.asEuint256(i * 8)), mask);
    e.allowThis(slot);           // persist the derived handle
}
```

**When to use it — and when NOT to.** Packing is right for **fixed-width, small records** (a 4-letter word, a few flags). It is the **wrong** tool for board *positions*: [confidential randomness](#confidential-randomness) warns that an 8-bit-packed position silently caps boards at 16×16 and can't be `shuffle`d or read with `getEbool`. Rule of thumb: pack a *record*; use an [elist](#encrypted-list-state) for a *collection you shuffle or index*.

**Pitfalls.**
- Field widths are fixed at pack time — size them for the worst case.
- Unpacking is encrypted compute (each `e.and`/`e.shr` is an op) — keep records small.
- `allowThis` every derived handle you persist, same as any stored encrypted value.

---

<a id="reveal-discipline"></a>

## Reveal discipline (minimal disclosure)

**Goal.** Reveal only what the UI strictly needs, only when it needs it — and consciously decide, per piece of state, what stays encrypted versus what you `e.reveal`. Privacy is the default; every reveal is a deliberate, justified exception.

**Naïve approach & why it breaks.** "Reveal everything so the frontend is easy." Revealing the full board on the first move, decrypting an opponent's hand to render a scoreboard, or attesting every cell at settlement all hand away exactly the hidden information the game's tension depends on. Over-revealing is irreversible: once a handle is revealed, it's public forever, and you can't un-leak it next turn.

**The move.** This is a judgment move, not an API call. For each secret, ask:
- **What does the UI *actually* need right now?** In Mines, opening a tile needs *that tile's* result — `e.reveal(hit)` — not the board. The board is only revealed when the game is already over (on a confirmed loss), never before.
- **Who is the audience?** If only one player should see it, that's a [selective reveal](#selective-reveal) (`e.allow` to that address), not a public `e.reveal`.
- **Public vs private is itself a reveal decision.** Choosing `e.reveal` (public, Model A) vs `e.allow`-then-decrypt (one player, Model B — see [settlement-and-math.md](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback)) is part of minimal disclosure: if only the acting player needs a per-move result, prefer a private decrypt over a permanent public reveal.
- **Can an aggregate stand in for the detail?** Settlement needs "did you ever hit a bomb?", not the per-move trail — reveal the one [sticky accumulator](#sticky-accumulator) bit, not the history.
- **When is the latest safe moment to reveal?** Defer to the last possible point (the pick, the settlement) so information isn't available earlier than the rules require.
- **Is this reveal reversible?** It isn't. Treat each `e.reveal` as a permanent public disclosure and confirm the game's design *wants* that fact public from here on.

```solidity
// Open one tile: reveal THIS pick's outcome only — the rest of the board stays sealed.
ebool hit = e.getEbool(board, uint16(pos));
e.reveal(hit);

// Full board: only after the game has ended (confirmed loss), never mid-game.
inco.reveal(elist.unwrap(board));
```

**Why it works.** Minimal disclosure keeps the strategic surface intact: opponents and observers learn only the facts the rules force into the open, when the rules force them. Because reveals are one-way, a discipline of "reveal the narrowest thing, at the latest moment, to the smallest audience" is the only way to avoid slow, accidental information leaks that accumulate over a match.

**Pitfalls.**
- A reveal queued during a transaction becomes attestable/public — there's no "reveal just to my contract privately"; for contract-only access use `e.allow(…, address(this))`, and for one player use [selective reveal](#selective-reveal).
- Revealing a *derived* handle can leak its inputs (revealing a sum can pin down addends in a small space). Reveal the coarsest aggregate that satisfies the UI.
- Beware convenience reveals added "just for debugging" — they ship to production and leak. Audit every `e.reveal` / `inco.reveal` against "does the game design intend this to be public forever?"
