# Confidential Game Design on Inco

> The games hub of this skill. Start here when designing a confidential / hidden-information game — casino/provably-fair, card, board, sealed-auction, social-deduction, fog-of-war, or word/code-guessing — to decide WHAT should be private, WHICH Inco feature goes where, and how to build it fast. The base API (encrypted types, `e.allow`, attestation, the JS SDK, `create-inco-app`) is on the [main skill page](../../SKILL.md) and the `references/*-reference.md` files. Not for perfect-information games with no hidden state, or a one-shot secret better served by plain commit-reveal.

## When to use this page

This is the **game-design layer** of this skill. The base API (encrypted types, `e.allow`, attestation, the JS SDK, `create-inco-app`) lives on the main [SKILL.md](../../SKILL.md) and the `references/*-reference.md` files; this file teaches confidential *game design* on top of it. The primary entry path is: **"I have a game idea → what should be private, which Inco features go where, and how do I build it fast?"** Use it for any confidential / hidden-information game whose on-chain state must stay secret with selective reveal. Inco is **TEE-based, not FHE**: "encrypted" means decrypt-in-TEE, never homomorphic. *Not* the right tool for perfect-information games with no hidden state (chess, Go), or a one-shot secret that opens once at the end — that's often better served by plain commit-reveal (see [choosing-your-approach.md](choosing-your-approach.md)).

## Step 1 — What's secret, and when does it reveal? (the decision tree)

Two questions decide everything. Answer them, then read off the archetype and its headline Inco primitive.

**Q1 — What must stay secret?** the bomb/tile map · the deck order + each hand · a sealed bid · a role/allegiance · unit/ship positions · an RNG outcome · a committed move · a hidden word/code/target.

**Q2 — When does the secret reveal?** **never** (you only ever open an aggregate) · **on query** (one element per move) · **selectively per-player** (persists, visible to a subset) · **at settlement** (everything opens simultaneously at the end).

(If the secret is *truly never* opened — not even an aggregate, you only ever *prove statements* about it — that's zk territory, not Inco's sweet spot; see [choosing-your-approach.md](choosing-your-approach.md).)

The *reveal timing* is the load-bearing axis — it's how [archetypes.md](archetypes.md) groups its eight playbooks (Group A / B / C). Find your row:

### Group A — revealed ON QUERY (mutable secret, one element opens per move) — *audience can be everyone or just the acting player*

| What's secret | Reveal | → Archetype | Headline Inco primitive |
|---|---|---|---|
| The bomb/tile map of a grid | one tile's result per pick, to everyone | [1. Encrypted board + progressive reveal](archetypes.md#1-encrypted-board--progressive-reveal) | elist `shuffle` + `getEbool` + sticky `e.or` |
| Unit/ship positions on a grid | hit/miss for the queried cell, per shot | [2. Hidden placement / fog-of-war](archetypes.md#2-hidden-placement--fog-of-war) | per-player encrypted board + `getEbool` |
| A hidden word / code / target value | per guess: match + where, to the guesser | [8. Hidden word / code: guess-and-match](archetypes.md#8-hidden-word--code-guess-and-match) | `e.eq` across slots + chained `e.select` + sticky `e.or` |

### Group B — revealed SELECTIVELY PER-PLAYER (persists, visible to a subset)

| What's secret | Reveal | → Archetype | Headline Inco primitive |
|---|---|---|---|
| Deck order + each player's hand | each card, to its owner only | [3. Hidden hand / shuffled deck](archetypes.md#3-hidden-hand--shuffled-deck) | `shuffle` deck + `e.allow(card, player)` |
| A role / allegiance | to an informed subset during play | [4. Hidden roles / social deduction](archetypes.md#4-hidden-roles--social-deduction) | `e.allow(role, eachTeammate)` |

### Group C — revealed AT SETTLEMENT (committed, opens simultaneously at the end)

| What's secret | Reveal | → Archetype | Headline Inco primitive |
|---|---|---|---|
| A sealed bid | winner + clearing price only, at close | [5. Sealed-bid auction](archetypes.md#5-sealed-bid-auction) | encrypted `euint256` + compare/`select` running max |
| A committed move | the outcome only, at resolution | [6. Commit & compare / simultaneous move](archetypes.md#6-commit--compare--simultaneous-move) | `e.eq`/compare ops + `select`, reveal verdict |
| An RNG outcome of a wager | at settlement | [7. RNG settlement / provably-fair casino](archetypes.md#7-rng-settlement--provably-fair-casino) | `e.randBounded(n)` / `e.rand`, reveal at settle |

If no archetype fits exactly, that's expected — recombine the closest one's moves from [patterns.md](patterns.md). The moves are the primitives; the archetypes are just common recipes.

## Step 2 — Which Inco feature do I use where? (the feature map)

This answers *which feature to reach for in a game*. Each "where" links to the pattern or archetype that demonstrates it.

| Inco feature | Where it's useful in games |
|--------------|----------------------------|
| `euint256` / `ebool` / `eaddress` (encrypted state) | any secret that must live on-chain: hidden scores, balances, roles, positions, board cells ([encrypted-list state](patterns.md#encrypted-list-state)) |
| `e.rand` / `e.randBounded(n)` | dice, crash, lottery, card draws — fair RNG that resists front-running, outcome encrypted until reveal ([archetype 7](archetypes.md#7-rng-settlement--provably-fair-casino)) |
| elist + `shuffle` | shuffled decks, randomized boards, mine/bag placement — unbiased in one op ([confidential randomness](patterns.md#confidential-randomness)) |
| elist `getEbool` / `getEuint256` (index) | O(1) lookup of a board cell / dealt card / position — no O(N) scan ([encrypted-list state](patterns.md#encrypted-list-state)) |
| `e.allow(handle, player)` | selective per-player visibility: your poker hand, your mafia role, your private board; also the read path for **Model B / Loop B** — the player decrypts privately with `attestedDecrypt`/voucher ([selective reveal](patterns.md#selective-reveal)) |
| `e.allowThis()` | keep secret state usable across turns — mandatory for any persisted handle ([sticky accumulator](patterns.md#sticky-accumulator)) |
| `e.or` (sticky accumulator) | collapse many secret events into one settlement bit (e.g. "ever hit a bomb") → verify once ([sticky accumulator](patterns.md#sticky-accumulator)) |
| `e.select(cond, a, b)` | branch on a secret without leaking it — never if/else/require on encrypted conditions ([silent-failure `.select()`](patterns.md#silent-failure-select)) |
| `e.eq` / `gt` / `ge` / `lt` / `le` / `min` / `max` | compare sealed values: auction high bid, RPS winner, guess-vs-secret ([sealed-bid](archetypes.md#5-sealed-bid-auction), [RPS](archetypes.md#6-commit--compare--simultaneous-move)) |
| `e.eq` + chained `e.select` (locate) | match a guess against a hidden word/code and encode which slot hit ([equality-match](patterns.md#equality-match), [archetype 8](archetypes.md#8-hidden-word--code-guess-and-match)) |
| pack into `euint256` + `e.shr` / `e.and` | store a short hidden word / fixed record compactly ([packing](patterns.md#encrypted-packing)) |
| `e.add` / `sub` / `mul` | update hidden scores / resources / pots without revealing them ([sticky accumulator](patterns.md#sticky-accumulator)) |
| `e.reveal` + frontend `attestedReveal` | progressive reveal (tile, hit/miss) and settlement; no wallet sig for public reveals — the **Model A / Loop A** public path ([reveal discipline](patterns.md#reveal-discipline)) |
| on-chain attestation verify | trustless settlement (**Model A**): prove the revealed value, check handle-match, prevent replay ([settlement](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback)) |

Base API details for each call live in the base references (`../elist-reference.md`, `../js-sdk-reference.md`) — this map is about *which to reach for in a game*, not how the call works.

## Build fast: from create-inco-app to your game

The scaffold step itself (`create-inco-app`, SDK setup, fee handling) is covered by the base API — don't restate it; reach for it on the [main skill page](../../SKILL.md). The game-specific fast path on top of that scaffold is four steps:

1. **Nail the secret.** Run Step 1's decision tree (Q1 + Q2) to land on an archetype.
2. **Drop in the contract sketch.** Take that archetype's *signature move* / contract sketch from [archetypes.md](archetypes.md) into the scaffold's `contracts/`.
3. **Wire the frontend loop.** Copy the encrypt → tx → reveal → paint loop from [frontend.md](frontend.md), swapping the Mines-typed names for yours.
4. **Iterate against both the base API and this layer.** Keep the base references and these games references both in context so API questions route to the base references and design questions stay here.

**Prompt recipe.** Describe your idea so the AI routes it correctly — answer four things:

> (a) what each player can see · (b) what must stay hidden, and from whom · (c) when the hidden thing becomes known · (d) how a winner/payout is decided.

Filled example (Texas Hold'em): *"(a) every player sees the community cards and all bets; (b) each player's two hole cards stay hidden from everyone else; (c) hole cards reveal only at showdown, to everyone, simultaneously; (d) best 5-card hand among non-folded players wins the pot."* → (b)+(c) point at **selective per-player** visibility that opens at settlement → archetype 3 (hidden hand) with a settlement reveal, `e.allow` per hand + reveal-at-showdown.

Note (a)–(d) map straight onto the decision tree: (a)+(b) are **Q1 (what's secret)**, (c) is **Q2 (when does it reveal)**, and (d) is the settlement path.

## Game jam: build a deck-shaped game fast

**Scope first.** This path is for games that reduce to the *deck shape*: a shuffle of hidden values that get dealt out. That is three families:

- **Card hands:** poker, blackjack, war, hearts, gin. Private cards, revealed on the game's schedule.
- **Hidden roles:** mafia, werewolf, secret-team assignment. One private value per player, usually never revealed on-chain.
- **Random draws:** raffle, lottery, gacha or pack opening. One (or a few) hidden winners pulled from a shuffle.

If your game is not one of these, do NOT fork the template; use the from-scratch path above and route by the list at the end of this section.

**Fork the starter.** The **[ConfidentialDeck template](https://github.com/Inco-fhevm/confidential-deck-template)** is a Hardhat + Next.js repo with four worked games (War, Blackjack, Raffle, Mafia) on one `ConfidentialDeck` base contract, plus a demo dApp. [Play it live](https://confidential-deck.vercel.app).

AI-first steps:

1. **Clone it and hand the repo to your AI.** It ships an `AGENTS.md` that briefs an assistant on the kit, the per-game privacy model, and the frontend, so a change lands with the right privacy boundary on the first try.
2. **Start from the closest of the four.** War (private hand, reveal at showdown), Blackjack (face-up hand, hidden dealer and shoe), Raffle (one hidden winner), Mafia (per-player secret role). Copy the nearest and change the rules.
3. **Inherit the kit.** `contract MyGame is ConfidentialDeck` gives the five moves (shuffle, draw, private deal, public reveal, attested settle), so you write only rules. Walkthrough: [docs.inco.org/games/confidential-deck](https://docs.inco.org/games/confidential-deck).
4. **Re-check the reveal timing.** The template fixes what is secret for *its* games; if yours opens the secret at a different moment, run Step 1 before you change it.

**Not deck-shaped? Route here instead:**

- Per-move RNG casino (dice, slots, coin flip, plinko) → the `e.rand()` play-then-settle pattern; see [Incasino](https://github.com/Inco-fhevm/incasino).
- An encrypted board opened one cell per move (minesweeper, battleship, fog of war) → the shuffle-a-board archetype in [archetypes.md](archetypes.md) and [scripts/games/mines/](../../scripts/games/mines/).
- A hidden word or code guessed over turns (hangman, wordle, mastermind) → encrypted input + `e.eq`; see [scripts/games/hangman/](../../scripts/games/hangman/IncoHangMan.sol).
- Anything else → the from-scratch path above, driven by [archetypes.md](archetypes.md).

## The core loop: encrypt → play → reveal → settle

Every confidential game on Inco — whatever the genre — is the same four-stage loop:

1. **Encrypt secret state.** Place the hidden board/deck/role with [confidential randomness](patterns.md#confidential-randomness) (or accept it as an encrypted input), and `allowThis()` so it survives across turns.
2. **Play on encrypted state.** Each move reads/updates handles in place — [encrypted-list state](patterns.md#encrypted-list-state) lookups, [silent-failure `.select()`](patterns.md#silent-failure-select) for hidden outcomes, a [sticky accumulator](patterns.md#sticky-accumulator) folding the running verdict.
3. **Reveal or decrypt only what's needed.** Public `e.reveal` / `attestedReveal` to everyone (Loop A), *or* `e.allow` + private `attestedDecrypt` to one player (Loop B) — pick by audience. Reveal the narrowest handle (this tile, this card, the high bid) under [reveal discipline](patterns.md#reveal-discipline); per-player facts never go via a public reveal. The frontend side of this is [frontend.md §1](frontend.md#1-the-core-loop-encrypt--tx--reveal--paint).
4. **Settle by the right model.** **Model A:** submit the covalidator attestation, the contract verifies the handle-match and acts — pay out, declare a winner, end the round (wager/contract-enforced outcomes). **Model B:** the client reads its private decrypt and enforces the rules — no on-chain settlement (single-player/non-stake). See [settlement-and-math.md](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback).

## Validation checklist

Game-specific checks, on top of this skill's base checklist (`allowThis` on every update, fee on every `newE*`, etc.). Each item links to where it's explained:

- [ ] Never `if/else`/`require` on encrypted conditions — use `.select()` ([patterns.md](patterns.md#silent-failure-select))
- [ ] `allowThis()` on every persisted handle (board, accumulator, running max) ([patterns.md](patterns.md#sticky-accumulator))
- [ ] `e.allow(handle, player)` for per-player secrets — hand, role, private board ([patterns.md](patterns.md#selective-reveal))
- [ ] At settlement, verify the attestation handle-match **and** reject stale handles (replay) ([settlement-and-math.md](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback))
- [ ] Reserve the *max* payout before accepting a bet (wager games) ([settlement-and-math.md](settlement-and-math.md#3-factory-liability-reservation))
- [ ] Reveal-discipline: reveal only what the UI needs, at the latest moment, to the smallest audience ([patterns.md](patterns.md#reveal-discipline))
- [ ] If a per-move result is for the **acting player only**, `e.allow` it and read with `attestedDecrypt`/voucher (Model B) — don't `e.reveal` it publicly ([frontend Loop B](frontend.md#loop-b--private-decrypt-only-the-acting-player-learns-the-result))
- [ ] Client-side enforcement is fine for **non-wager / self-adjudicated** games, but the contract doesn't know the outcome — never use it where funds or another party depend on the result ([settlement-and-math.md Model B](settlement-and-math.md#model-b--no-on-chain-settlement-client-side-enforcement))
- [ ] Frame "provably fair" honestly as **TEE attestation, not zk** ([choosing-your-approach.md §3](choosing-your-approach.md#3-honest-tee-framing))
- [ ] Decide **fee funding** — players pay per encrypted input (`payable` + `msg.value`), or pre-fund the contract to **sponsor** it (gasless moves; smoother UX for per-turn encrypted inputs like sealed bids / placements) ([Fee Payment](../solidity-reference.md#fee-payment))

## References

**Load only what the task needs — don't pull all five reference files.**

- *Routing a fresh game idea* → `archetypes.md` (+ `patterns.md` for the moves it cites). **Do NOT load** `settlement-and-math.md` or `frontend.md` yet.
- *Writing the contract* → `patterns.md` + your one archetype in `archetypes.md`; add `settlement-and-math.md` **only for wager/casino** games. **Do NOT load** `frontend.md`.
- *Wiring the UI* → `frontend.md`. **Do NOT load** `settlement-and-math.md` unless the UI shows payouts.
- *Unsure Inco even fits?* → `choosing-your-approach.md` first.

- [archetypes.md](archetypes.md) — read this when you have a game idea and want the closest playbook of the eight to build from.
- [patterns.md](patterns.md) — read this when you need the cross-cutting moves (randomness, elist state, accumulator, selective reveal, silent `.select()`, reveal discipline) the archetypes compose.
- [settlement-and-math.md](settlement-and-math.md) — read this when turning an encrypted outcome into a trustless on-chain result, or pricing/bankrolling a wager game.
- [frontend.md](frontend.md) — read this when wiring the UI: the encrypt → tx → reveal → paint loop, cached attestations, one-popup UX, the optional allowance voucher for popup-free private decryption (cards/roles), multiplier parity, reveal staging / async-phase UX, and the ship checklist.
- [choosing-your-approach.md](choosing-your-approach.md) — read this *first* if you're unsure Inco is even the right tool — it routes Inco vs commit-reveal vs zk vs trusted server, and gives the honest TEE framing.

**Worked examples** (`../../scripts/games/`) — two complete contracts spanning the two settlement models: [`mines/`](../../scripts/games/mines/) (Model A — wager, on-chain attestation settlement, factory bankroll; audited) and [`hangman/IncoHangMan.sol`](../../scripts/games/hangman/IncoHangMan.sol) (Model B — word-guess, private decrypt, client-side; POC, read the header caveats). The reference files above teach the *moves*; these show them assembled end-to-end.
