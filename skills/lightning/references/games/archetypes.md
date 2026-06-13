# Game Archetypes

A catalog of confidential-game *archetypes* — the recurring shapes hidden-information games take — so you can find the one closest to your idea and build from it. The organizing axis is the same one the SKILL.md decision tree turns on: **what is secret, and *when* does the secret reveal?** That reveal-timing is what determines which moves you compose, so the playbooks are grouped by it:

- **Group A — revealed ON QUERY.** A mutable secret you keep encrypted and read one piece of at a time, each move (a tile pick, a shot). The secret lives across turns; only the touched element opens.
- **Group B — revealed SELECTIVELY PER-PLAYER.** A secret that *persists* but is visible to a subset — your own hand, your secret role, your fog-of-war vision — and stays opaque to everyone else.
- **Group C — revealed AT SETTLEMENT.** A committed secret that stays sealed until a simultaneous open at the end — sealed bids, simultaneous moves, an RNG draw.

Every archetype here is built by *composing the moves* in [patterns.md](patterns.md) — when a playbook says it "shuffles an encrypted deck" or "folds into a sticky bit", that's a link, not a fresh explanation. Base API → the [main skill page](../../SKILL.md) / base references; this file is the game-design layer. Inco is **TEE-based, not FHE**.

> **Loading** — routing a fresh idea: pair this with [patterns.md](patterns.md) (the moves these cite); add [settlement-and-math.md](settlement-and-math.md) only for **wager** games and [frontend.md](frontend.md) only when wiring the UI. Full per-task order: [overview.md](overview.md#references).

**If none of the eight fits exactly:** that's expected — these are reference points, not a closed set. Find the closest one (or two), read which patterns.md moves it composes, and recombine those moves for your shape. The moves are the primitives; the archetypes are just common recipes.

## How each playbook is laid out

Every playbook has the same five parts, kept deliberately tight:

- **One-line identity** — *Secret:* … · *Revealed:* … (when, and to whom).
- **What breaks if public** — the concrete cheat, MEV, or grief if this state lived in plaintext storage or the mempool. This is *why* the archetype needs confidentiality at all.
- **Prior art** — how the genre has been solved before (commit-reveal, zk, trusted server), so you can see what Inco changes.
- **Build it on Inco** — which patterns.md moves to compose (links), plus at most one short snippet showing the archetype's *signature* move.
- **Fit & alternatives** — where Inco is the best/strong fit, and when to reach for commit-reveal or zk instead (links [choosing-your-approach.md](choosing-your-approach.md)).

---

## Group A — revealed ON QUERY

The secret is **mutable live state** that persists across turns; each move reads exactly one element and reveals only that. The whole structure stays encrypted; the game is a sequence of narrow per-move reveals. The reveal **audience** varies: *public to everyone* (Mines, Battleship — a public `e.reveal`) or *private to the acting player* (a word-guesser — `e.allow` + private decrypt, [Model B](settlement-and-math.md#model-b--no-on-chain-settlement-client-side-enforcement)).

### 1. Encrypted board + progressive reveal

> *Secret:* the bomb/tile map of the board. · *Revealed:* one tile's safe/bomb result per pick, to everyone, at the moment it's opened.

⭐ This is the **canonical reference archetype** — the skill's worked Mines example, fully realized end-to-end in [`Mines.sol`](../../scripts/games/mines/Mines.sol) (with [`MinesMath.sol`](../../scripts/games/mines/MinesMath.sol) + [`MinesFactory.sol`](../../scripts/games/mines/MinesFactory.sol) alongside). If your idea is "a hidden grid the player opens cell by cell," start here and read the four sibling files; the others below are variations on its moves.

**What breaks if public.** If the bomb map sits in plaintext storage, anyone reads it and plays a perfect game — opening only safe tiles forever, never losing, draining the house. The entire tension (and the house edge) depends on the player *not* knowing where the bombs are.

**Prior art.** Minesweeper is the classic single-player form; Stake-style "Mines" is the casino wager form (open safe tiles, cash out before you hit a bomb, multiplier climbs each pick). Neither was on-chain-trustless before — a naïve on-chain port either leaks the board (plaintext storage) or trusts a server to adjudicate hits.

**Build it on Inco.** Composes four moves: place the board with [confidential randomness](patterns.md#confidential-randomness) (build an elist of plaintext `true`/`false` cells and `shuffle` once — the randomness is in the permutation); store it as [encrypted-list state](patterns.md#encrypted-list-state) and read each pick with `getEbool`; fold every pick into a [sticky accumulator](patterns.md#sticky-accumulator) (`everHitBomb = e.or(everHitBomb, hit)`) so settlement is one bit; and apply [reveal discipline](patterns.md#reveal-discipline) — reveal only *this* tile's `hit`, never the board, until a confirmed loss. Settlement is the Model A [attestation flow](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback) over that one accumulator handle; the wager math is the [hypergeometric multiplier](settlement-and-math.md#2-payout-math-casino-specific). Because it's fully built in the repo, **don't re-snippet it** — read patterns.md, settlement-and-math.md, and [frontend.md](frontend.md) for the worked code.

**Fit & alternatives.** The proven baseline — Inco's mutable encrypted state + per-move reveal + accumulator settlement is exactly this archetype's shape, with no second tx and no callback. A commit-reveal port would force a fresh commit per board and can't cheaply read one cell without opening the rest; see [choosing-your-approach.md](choosing-your-approach.md).

### 2. Hidden placement / fog-of-war

> *Secret:* the positions of your ships/units on a grid. · *Revealed:* only hit/miss (or proximity) for the cell an opponent queries, on each shot.

**What breaks if public.** If your positions live in plaintext storage, the opponent reads them and wins on the first shot — there is no game. Even leaking them in the mempool (an unencrypted "place ship at (3,4)" tx) is fatal: the opponent front-runs their targeting on your placement.

**Prior art.** Two well-known zk approaches frame the contrast:
- **Battleship — BattleZips.** The board is a private value; a *Pedersen commitment* to it is published on-chain. Each turn, only the shot coordinate and a hit/miss boolean become public, and a zk proof attests the boolean is consistent with the committed board. The raw board is never revealed mid-game.
- **Dark Forest.** A zkSNARK "cryptographic fog of war": players submit *hash-commitments* to planet coordinates plus zk proofs that the moves are valid; raw coordinates are **never** submitted on-chain. (Caveat the genre is honest about: small coordinate spaces are brute-forceable from the hash, so the privacy is only as strong as the space is large.)

Both pin the hidden board as a **static commitment** and prove statements about it with zk.

**Build it on Inco.** The Inco inversion: positions are *mutable encrypted state*, not a frozen commitment. Hold the board as [encrypted-list state](patterns.md#encrypted-list-state) (an elist of `ebool`, or a mapping of `ebool`/`euint`); a shot reads that one cell with `getEbool` and you reveal only its hit/miss under [reveal discipline](patterns.md#reveal-discipline). If the *result* of a shot must stay hidden from some observers (proximity hints that only the shooter should see), grant it with [selective reveal](patterns.md#selective-reveal) instead of a public `e.reveal`. The signature move is identical to archetype 1's per-cell read — `ebool hit = e.getEbool(board, cellIndex)` — so don't re-snippet; the *difference* from Mines is whose grid it is and that placement may itself be a per-player encrypted input.

> Note: keeping placement itself secret from the contract means accepting each player's board as an encrypted input (`newEbool`/`newEList(..., msg.sender)`) rather than shuffling a known one. A plaintext cell index still reveals *which* cell was shot at (that's usually fine — the shot is public); if even *where* a player aimed must be secret, use the hidden-index elist ops (`getOr`, `sliceLen`) — see [patterns.md](patterns.md#encrypted-list-state) and the base [elist reference](../elist-reference.md).

**Fit & alternatives.** Strong fit. The design call is the trust model: zk gives hardware-free mathematical privacy of a *fixed* board (BattleZips, Dark Forest) but strains when state mutates a lot per turn; Inco gives live, mutable, per-player-visible state at a TEE trust cost. If your fog-of-war board is essentially static and you want trustless math, prefer zk; if it evolves and you accept the enclave trust model, Inco is simpler. See [choosing-your-approach.md](choosing-your-approach.md).

### 8. Hidden word / code: guess-and-match

> *Secret:* a hidden word / code / target value (stored encrypted, packed or per-slot). · *Revealed:* per guess — whether and *where* it matched — to the guesser (Model B); or only the final verdict at settlement (Model A) for a stake duel.

**What breaks if public.** If the target sits in plaintext storage anyone reads it and the game is over — every guess is "correct" on the first try. The whole game is the gap between the guesser and a value they can't see.

**Prior art.** Hangman, Mastermind, Wordle, "guess the number/code". On-chain, a **commit-reveal** of the word works for a *one-shot* open but can't give *per-guess* feedback without revealing the whole word; a **trusted server** that holds the word and adjudicates guesses is the Web2 default (you trust it not to move the word). Neither gives trustless, encrypted *per-guess* matching. **Worked example:** [`scripts/games/hangman/IncoHangMan.sol`](../../scripts/games/hangman/IncoHangMan.sol) — a POC; read its header caveats (block-entropy word pick, client-side settlement).

**Build it on Inco.** Store the target with [encrypted packing](patterns.md#encrypted-packing) (a short word in one `euint256`) or as per-slot `euint256`s. Each guess is an [equality-match / locate](patterns.md#equality-match): `e.eq` the guess against each slot, chain `e.select` to encode which slot matched (or a sentinel). Track progress with a [sticky accumulator](patterns.md#sticky-accumulator) — a reveal bit per slot folded with `e.or`, win by `e.and`-reduce, lives by a conditional `e.select`. **Reveal via Model B** (private-decrypt the per-guess result to the guesser — [frontend Loop B](frontend.md#loop-b--private-decrypt-only-the-acting-player-learns-the-result)) for a single-player game; use **Model A** (on-chain verify) only if it's a wager/competitive duel the contract settles. Signature move — locate the matched position without branching:

```solidity
// `slots[i]` are the encrypted target chars; `guess` is a plaintext code point.
euint256 result = e.asEuint256(100);                  // sentinel: not found
for (uint8 i = 0; i < N; i++) {
    ebool isMatch = e.eq(slots[i], e.asEuint256(guess));
    result = e.select(e.and(isMatch, e.eq(result, e.asEuint256(100))), e.asEuint256(i + 1), result);
}
// e.allow(result, player) → player decrypts privately (Model B); never e.reveal for single-player.
```

> Honest note: a casual word-guesser may pick its secret with block entropy — that's the [randomness anti-pattern](patterns.md#confidential-randomness) (`block.timestamp`/`blockhash` are predictable). For a competitive or wager version, pick the target with `e.randBounded(n)` so neither player nor deployer can predict it.

**Fit & alternatives.** Strong fit: Inco gives *live per-guess feedback* on a hidden value that commit-reveal can't (it would have to open the whole word) and a trusted server only fakes. zk could prove "the letter at position i is X" but needs a fresh circuit/proof per guess; Inco's encrypted equality is a single op. See [choosing-your-approach.md](choosing-your-approach.md).

---

## Group B — revealed SELECTIVELY PER-PLAYER

The secret **persists** and is meant to be visible to a *subset* — its owner, or an informed minority — while staying opaque to everyone else and to chain observers. The defining move here is [selective reveal via `e.allow`](patterns.md#selective-reveal): visibility is an on-chain grant per handle, not a public reveal.

### 3. Hidden hand / shuffled deck

> *Secret:* the deck order and each player's hand. · *Revealed:* selectively, each card to its owner only.

**What breaks if public.** If the deck order or any hand sits in plaintext, every player reads it: they know the next card off the top and exactly what everyone holds. Poker, and every trick-taking or draw-based card game, is unplayable the instant hands are readable.

**Prior art.** The classic decentralized solution is **mental poker** — how to deal a fair, secret game with no trusted dealer and mutually distrusting players. It's solved with *n-out-of-n threshold encryption*: every player encrypts/shuffles, and a card is unmasked only when **all** players publish their reveal tokens for it. Strong trust-minimization, but heavy — lots of per-card cryptography and rounds, and it's **liveness-sensitive**: one player who stalls (won't publish a reveal token) blocks the whole table.

**Build it on Inco.** Far simpler. [Shuffle an encrypted deck](patterns.md#confidential-randomness) in one op — `e.shuffledRange(1, 53, ETypes.Uint256)` gives a shuffled 52-card deck — and hold it as [encrypted-list state](patterns.md#encrypted-list-state). To *deal*, take the next deck element and grant it to its owner with [selective reveal](patterns.md#selective-reveal); only that player can run an attested decrypt on it, and the contract never emits the card. The signature move — dealing a card *is* a per-handle `e.allow` to the recipient:

```solidity
// `deck` is the shuffled elist; `topIndex` is the public draw position.
// Reading the element doesn't reveal it — the grant is what makes it visible,
// and only to `player`. No e.reveal: the card stays opaque to everyone else.
euint256 card = e.getEuint256(deck, uint16(topIndex));   // index is uint16
e.allow(card, player);   // selective reveal: ONLY this player can decrypt it
```

The player decrypts client-side via the SDK's attested-*decrypt* flow (a private handle for an authorized address — needs the wallet to sign, unlike a public reveal); see this skill's JS SDK reference. Note the grant is **per handle** and **one-way**: re-`allow` any new handle you derive, and never `allow` a card to the wrong address — that's a one-line leak. *(Nice-to-have UX: a once-per-session [allowance voucher](frontend.md#4-private-per-player-decryption-the-allowance-voucher) makes peeking your hand popup-free instead of a wallet prompt per look.)*

**Fit & alternatives.** Strong fit, and dramatically simpler than mental poker — no n-out-of-n round, no last-staller liveness trap — at the cost of trusting the TEE instead of threshold cryptography. If your game's whole premise is *trustless* dealing with no trusted hardware, mental poker / zk is the trade you'd make; otherwise Inco's per-player `e.allow` is the natural home for live, mutating hands. See [choosing-your-approach.md](choosing-your-approach.md).

### 4. Hidden roles / social deduction

> *Secret:* each player's secret role/allegiance. · *Revealed:* to an informed subset during play (e.g. the mafia know each other), otherwise only at death or endgame.

**What breaks if public.** If roles are readable from storage, the deduction game is pointless — everyone simply reads who the mafia are. The genre *is* the asymmetry of information; expose it and there's nothing left to play.

**Prior art.** **Mafia/Werewolf** is the canonical mechanic: an *informed minority* (the mafia, who know their teammates) versus an *uninformed majority* (the town, who must deduce). On-chain attempts include **zkwitches** (each player's hand is committed as `HASH(salt + hand)` and never fully revealed, even at the end — statements are proven in zk over the commitment). High-signal for this skill: **Inco's own fully-on-chain Mafia game, built at ETHGlobal NYC** — social deduction is a flagship Inco fit precisely because the secret is per-player, persistent, and selectively shared.

**Build it on Inco.** Model a role as a small encrypted int (`euint256`) or an `eaddress`, assigned via [confidential randomness](patterns.md#confidential-randomness) (shuffle a list of role values, or draw with `e.randBounded`). Give the informed subset visibility with [selective reveal](patterns.md#selective-reveal) — `e.allow(role, eachMafiaMember)` so the mafia can read each other while the town cannot. Resolve night actions (kill, save, investigate) with [silent-failure `.select()`](patterns.md#silent-failure-select) so the *outcome* doesn't leak through control flow — no revert, no divergent log that betrays who was targeted or whether a save landed. Reveal a role publicly (at death, or at endgame) only as a deliberate [reveal-discipline](patterns.md#reveal-discipline) step. *(Nice-to-have UX: the informed subset reads teammates' roles with `attestedDecrypt`; a once-per-session [allowance voucher](frontend.md#4-private-per-player-decryption-the-allowance-voucher) keeps that popup-free.)*

```solidity
// Grant the informed minority sight of each other's role; the town gets nothing.
// `e.allow` is the privacy boundary — no public reveal here.
for (uint256 i = 0; i < mafia.length; i++) {
    for (uint256 j = 0; j < mafia.length; j++) {
        e.allow(roleOf[mafia[i]], mafia[j]);  // every mafioso can decrypt every teammate's role
    }
}
```

**Fit & alternatives.** **The best-fit selective-visibility archetype.** Per-player, persistent, subset-visible secret state is exactly the lane where Inco beats both commit-reveal (which can't do *live, per-player* visibility — a commitment is all-or-nothing) and zk (which proves statements but doesn't natively give one player live read access to another's state). zkwitches shows the zk-commitment route if you need trustless math; for live informed-minority play, Inco's `e.allow` is the cleanest. See [choosing-your-approach.md](choosing-your-approach.md).

---

## Group C — revealed AT SETTLEMENT

The secret is **committed and held sealed** until a single simultaneous open at the end. Nobody reads anybody's value mid-game; settlement reveals only the *result*. This is commit-reveal's home turf — and the group where Inco's main win is removing commit-reveal's second tx and its last-revealer abort.

### 5. Sealed-bid auction

> *Secret:* each participant's bid. · *Revealed:* simultaneously at settlement — only the winner (and clearing price), not the losing bids.

**What breaks if public.** Bid sniping and front-running. If your bid sits in the mempool or in plaintext storage, a rival reads it and outbids by the minimum increment, or times their bid to just edge yours. The sealed-bid mechanic exists specifically so no one can react to anyone else's number.

**Prior art.** The canonical "Auction: Sealed Bid" mechanic — all bids concealed until a simultaneous reveal, high bidder wins. On-chain, this is usually a **commit-reveal auction**: bidders commit `hash(bid + salt)` in phase one and reveal in phase two. It works, but inherits commit-reveal's flaws — a second transaction per bidder, the need for everyone to come back online to reveal, and the **last-revealer abort**: whoever reveals last has seen the others and can withhold their own reveal if they don't like the outcome (mitigated only by bonding/slashing).

**Build it on Inco.** Each bid is an encrypted `euint256` accepted as an input (`newEuint256(bytes, msg.sender)`). Find the winner *without branching on plaintext* using [silent-failure `.select()`](patterns.md#silent-failure-select) and compare ops — fold bids into a running max and a running winner address:

```solidity
// Fold each new bid into the running winner — no plaintext branch, no leak.
ebool isHigher       = newBid.gt(highestBid);
highestBid           = isHigher.select(newBid, highestBid);
encryptedWinner      = isHigher.select(e.asEaddress(bidder), encryptedWinner);
e.allow(highestBid, address(this));       // keep both handles across txs (patterns.md: cross-tx allow)
e.allow(encryptedWinner, address(this));  // reveal only at settlement, never the running max
```

Then [reveal](patterns.md#reveal-discipline) **only the result** at settlement — the winner and the clearing price — never the losing bids, and settle over it with the Model A [attestation flow](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback). Keeping a *continuously updated* highest bid in the clear would leak the running high (the base reference flags exactly this), so the running max stays encrypted until the end.

**Fit & alternatives.** Strong fit — Inco removes commit-reveal's two-phase ceremony and, crucially, the **last-revealer abort**: there's no second reveal tx for anyone to withhold, because the bids were encrypted live and only the *outcome* is opened, once, by the settlement call. If a single bid that opens exactly once is all you need and a second tx is acceptable, commit-reveal is a cheaper start; the moment you want no-abort sealed bidding, Inco wins. See [choosing-your-approach.md](choosing-your-approach.md).

### 6. Commit & compare / simultaneous move

> *Secret:* each player's committed move. · *Revealed:* simultaneously, only the outcome (who won), at resolution.

**What breaks if public.** Whoever sees the other's move first wins for free. Rock-paper-scissors is unplayable if moves are visible — read your opponent's rock, play paper. Any simultaneous-move game (RPS, simultaneous-reveal card flips, blind voting) collapses the instant one move is readable before the other commits.

**Prior art.** Commit-reveal is **the** textbook solution: each player posts `hash(move + salt)`, then reveals the preimage; the contract re-hashes to check. It's what makes RPS (and much of on-chain poker) playable on a transparent chain — but it doubles transactions (commit + reveal) and carries the **last-revealer problem**: the second revealer already knows the first move and can abort by not revealing if they're about to lose.

**Build it on Inco.** Encrypt each move as a `euint256` input, compare with `e.eq` / the compare ops to derive an encrypted outcome, and resolve the payoff with [silent-failure `.select()`](patterns.md#silent-failure-select) so neither move nor result leaks through control flow. Reveal **only the outcome** at the end under [reveal discipline](patterns.md#reveal-discipline):

```solidity
// RPS outcome from two encrypted moves (0=rock,1=paper,2=scissors), no plaintext branch.
// p1 wins iff (p1 - p2) mod 3 == 1; encode the result, reveal only it.
ebool tie   = move1.eq(move2);
// Add 3 before subtracting so the unsigned euint never underflows ({0,1,2}+3-{0,1,2} is always ≥ 1);
// +3 is a no-op mod 3, so this is exactly (p1 - p2) mod 3.
ebool p1Win = move1.add(e.asEuint256(3)).sub(move2).rem(e.asEuint256(3)).eq(e.asEuint256(1));
// settle over `p1Win` / `tie` — never reveal the raw moves.
```

There's no second reveal tx and no abort window — both moves are encrypted on-chain from the start, and the settlement call opens only the verdict via the [attestation flow](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback).

**Fit & alternatives.** Strong fit — this is the textbook *"encrypted state replaces commit-reveal"* case. Inco removes both commit-reveal pain points (the second tx and the last-revealer abort) at the TEE trust cost. If the move opens exactly once and a two-tx flow is fine, commit-reveal remains the simplest classic solution; choose Inco when you want single-tx, abort-free simultaneous moves. See [choosing-your-approach.md](choosing-your-approach.md).

### 7. RNG settlement / provably-fair casino

> *Secret:* the RNG outcome of a wager (the dice roll, the wheel, the card). · *Revealed:* at settlement.

**What breaks if public.** A player who can *predict or read* the outcome before committing drains the house — they only play the winning rolls. Predictable on-chain RNG (`blockhash`, `block.timestamp`) is the classic exploit: a contract or searcher computes the outcome and only transacts when it's favorable, or front-runs on it. The draw must be unknowable to the player at the moment they decide to play.

**Prior art.** Stake-style **"provably fair"**: a server seed (hash published up front) combined with a client seed; after the round the server reveals its seed and players verify the outcome was determined before they bet. It's the genre standard — but it's an **operator-trust** model: you trust the house not to swap an unrevealed seed or cherry-pick outcomes.

**Build it on Inco.** Draw the outcome with [confidential randomness](patterns.md#confidential-randomness): `e.randBounded(n)` returns an encrypted index in `[0, n)` (a die, a wheel slot, a card), and `e.rand()` a full-width encrypted draw. The result is an encrypted handle on-chain — opaque to the player, the deployer, and observers — until an explicit reveal. Settle over it with the Model A [attestation flow](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback) and price the wager with the [payout math](settlement-and-math.md#2-payout-math-casino-specific).

**Safe ordering — the bet must commit *before* the draw is revealed.** This is a funds-touching sequence, so don't improvise it; the skeleton:

```solidity
// tx A — take the bet AND draw, but do NOT reveal the draw here:
function play(uint256 n) external payable {
    require(msg.value >= betAmount + inco.getFee(), "bet + fee");
    bets[msg.sender]    = betAmount;          // bet is locked in first
    outcome[msg.sender] = e.randBounded(n);   // encrypted draw — opaque to player, deployer, mempool
    e.allowThis(outcome[msg.sender]);         // persist across txs
}

// tx B (settlement) — only now reveal, verify, and pay by the result:
//   e.reveal(outcome[player]); → fetch attestation off-chain → in settle():
//   verify isValidDecryptionAttestation + handle-match, then pay out by the decrypted value.
```

**NEVER** draw-and-reveal in a step that still lets the player choose whether to bet — that hands them the outcome before they commit, which is the whole exploit.

> **Honest framing — read carefully.** The anti-front-running property rests on one thing: the drawn value is **encrypted on-chain until an explicit `e.reveal`**, so a player can't read it from storage or the mempool to decide whether to play — which is *why* the bet-before-reveal ordering above is load-bearing. That exact sequencing is a contract-design decision (the docs confirm `e.rand`/`e.randBounded` produce an *encrypted* handle and that `e.reveal` is the explicit, irreversible public-decryption step, but don't prescribe the bet-vs-draw ordering) — so design that ordering deliberately and don't over-claim. **And be honest about the trust model:** this is *"provably fair via TEE attestation, not zk"* — players trust the Intel TDX enclave and the covalidator signature, not a piece of zero-knowledge math (see [choosing-your-approach.md §3](choosing-your-approach.md#3-honest-tee-framing)). It is a real, strong claim, but it is **not** zk-grade.

**Fit & alternatives.** Strong fit for casino RNG, with the honest-trust caveat front and center. Inco's edge over the classic server-seed model is that the draw is **protocol-encrypted on-chain**, not an operator's promise — there's no unrevealed seed for the house to swap. If a server-seed/client-seed operator is acceptable to your players, that's cheaper and simpler; if you want the RNG's confidentiality enforced by the chain (at the TEE trust cost) rather than by an operator, Inco is the move. See [choosing-your-approach.md](choosing-your-approach.md).
