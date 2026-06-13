# Frontend: the confidential-game UI loop

How a confidential game's UI drives play **without trusting a server** to tell it what's hidden. The frontend sends the move, pulls the result straight from the chain, and paints it — running one of **two** core loops, public-reveal (Loop A) or private-decrypt (Loop B), chosen by who is allowed to see the result (section 1 covers both). Sections 2–4 (cached attestation, one-popup UX, and the allowance voucher for private per-player decrypts) apply to games with hidden state; section 5 (multiplier parity) is wager-flavored, but the *parity principle* — never show a number the contract won't honor — is general. Sections 7–8 are the experience layer (staging the reveal, naming the async phases); §9 collects everything into a ship checklist.

Base SDK setup, `zap.encrypt`, and the `attestedReveal` vs `attestedDecrypt` distinction live in the [JS SDK reference](../js-sdk-reference.md). Inco is **TEE-based, not FHE** — a public `e.reveal()` value is pulled with a covalidator **attestation**, not a zk proof. The contract side is [settlement-and-math.md](settlement-and-math.md).

> **Loading** — this is the UI file: you don't need [settlement-and-math.md](settlement-and-math.md) unless the UI shows payouts. Full per-task order: [overview.md](overview.md#references).

---

## 1. The core loop: encrypt → tx → reveal → paint

There are **two** core loops, and you pick by who is allowed to learn the result. **Loop A — public reveal:** the move publicly reveals the outcome handle, the frontend pulls a covalidator attestation for it (no signature), and the contract can settle over it (Mines). **Loop B — private decrypt:** the move grants the outcome to the acting player with `e.allow`, the client decrypts it off-chain, and there is no public reveal and no on-chain settlement (a single-player word-guesser). The two share the encrypt → tx → … → paint shape; they differ only in the reveal step and who reads it.

### Loop A — public reveal (the contract/everyone learns the result)

**Goal.** Drive a confidential game UI from on-chain truth alone. The player makes a move; the UI must learn the (encrypted) outcome and paint it — without a backend that could lie about what's hidden.

**Naïve approach & why it breaks.** Ask a server "did the player hit a bomb?" and render its answer. Now the server *is* the game: it knows the hidden board, it can lie, and "provably fair" is gone. The whole point of putting the secret in a TEE on-chain is that nobody — not even your own backend — gets to be the oracle. A second tempting shortcut is to read the encrypted handle and try to decrypt it client-side; you can't, the plaintext only exists inside the enclave, and the only trustless way out is an attested reveal.

**The move.** Each move is one signed tx that calls `e.reveal()` on the handle(s) you need; you wait the receipt, decode the revealed handle(s) from the event, pull a covalidator-signed value for them off-chain with `attestedReveal`, and paint. In Mines (`interface/components/MinesGame.tsx`), a tile click is exactly this:

```tsx
// MinesGame.tsx — handleTileClick (trimmed)
const hash = await pickTile(index);              // 1. one signed tx (the move)
const receipt = await waitForReceipt(hash);      // 2. wait for it to land
const { hitHandle, accumHandle } = decodePickRevealed(receipt); // 3. decode revealed handles from the event

// 4. ONE covalidator round-trip for BOTH handles (attestedReveal takes an array)
const [hitResult, accumResult] = await retryReveal([hitHandle, accumHandle]);
lastAccumAttestationRef.current = accumResult;   // cache for cash-out (§2)

const bomb = isBomb(hitResult);                  // 5. paint
setRevealedResults(prev => ({ ...prev, [index]: bomb }));
setGameState(bomb ? 'lost' : 'playing');
```

`decodePickRevealed` just walks the receipt logs for the `PickRevealed` event and returns its `hitHandle` / `accumHandle` args. `retryReveal` (in `interface/lib/inco-attestation.ts`) is a thin wrapper over `zap.attestedReveal(handles, { backoffConfig: REVEAL_BACKOFF })` — see [§6](#6-retry--backoff).

**Why it works.** The move tx is the *only* thing the player signs. The reveal is a public decryption: the handle was made public on-chain via `e.reveal()`, so `attestedReveal` needs **no wallet signature** — anyone can fetch the attestation (this is what separates it from `attestedDecrypt`, which decrypts a private handle *for an authorized address* and therefore needs the wallet to sign; see the [JS SDK reference](../js-sdk-reference.md#attested-reveal)). That no-signature property is the entire UX crux of the next two sections: the reveal can run in the background with no popup. The covalidator's signature is what makes the painted result trustworthy — the UI isn't taking a server's word, it's holding a TEE attestation it could (and the contract will) verify.

**This loop is the same in any game — only the names change.** The move tx reveals whatever handle encodes *this action's* outcome (`hit` here; a card game reveals the drawn card, a sealed auction reveals the new high bid, a Battleship shot reveals hit/miss), plus an optional accumulator handle carrying the running settlement state. Swap the mines-typed identifiers (`pickTile`, `PickRevealed`, `hitHandle`/`accumHandle`, `isBomb`) for your game's and the encrypt→tx→reveal→paint shape is unchanged.

**Pitfalls.**
- **Batch the reveal.** Mines reveals two handles per pick (`hit` for win/lose, the `accum` accumulator for settlement). Pass them as one array — `retryReveal([hitHandle, accumHandle])` — so it's a single covalidator round-trip, not two sequential ones. The code comment flags this as the fix for what used to be two calls.
- **Decode from the receipt/event, not from a guessed handle.** The revealed handle is whatever the contract emitted this tx; read it out of the `PickRevealed` log rather than reconstructing it client-side, or you'll reveal a stale handle.
- **Pre-warm the SDK.** `Lightning.baseSepoliaTestnet()` cold-init costs hundreds of ms. Mines calls `getZap()` once on mount (`useEffect(() => { getZap().catch(console.error); }, [])`) so the first reveal after a pick feels instant.

### Loop B — private decrypt (only the acting player learns the result)

When a move's result is for the acting player alone (a single-player guess, your own card peek), don't `e.reveal` it publicly — grant it and decrypt it privately. The move tx writes encrypted state and `e.allow(resultHandle, player)`; the client reads the granted handle and decrypts it off-chain. No public reveal, no attestation submitted on-chain.

```tsx
// Loop B (e.g. a word-guesser): tx → read granted handle → private decrypt → paint
const hash = await guess(letter);                  // 1. one signed tx (the move)
await waitForReceipt(hash);                         // 2. wait for it to land
const handle = await readResultHandle();            // 3. read the e.allow-ed handle (e.g. getTile())

// 4. private decrypt — popup-free via a once-per-session voucher (no per-read signature)
const [result] = await attestedDecryptWithVoucher(sessionKey, voucher, [handle]);

paint(Number(result));                              // 5. client enforces the rule and paints
```

The wallet signs the move tx; the decrypt is popup-free because the player minted a **session-key allowance voucher** once at session start (§4) — `attestedDecryptWithVoucher` then needs no per-read signature. Unlike Loop A, there is no public reveal and no on-chain settlement: the client decides win/lose (this is [Model B](settlement-and-math.md#model-b--no-on-chain-settlement-client-side-enforcement)). Swap the example's names (`guess`, `getTile`, the 1–4/sentinel result) for your game's.

**Pick the loop by audience:** result visible to everyone / the contract acts on it → Loop A. Result for the acting player only → Loop B.

---

## 2. Cached attestation

*Scope: this is a Loop A / Model A optimization (settling over an accumulator). Loop B / non-wager games have no on-chain settlement to cache for — skip this section.*

**Goal.** Settle (cash out, declare a winner, end the round) with **no extra reveal round-trip** at the moment the player commits.

**Naïve approach & why it breaks.** At cash-out, fetch a fresh attestation for the current accumulator handle, then submit it. That adds covalidator latency to the one click users are most impatient about (taking their money), and it opens a race: the on-chain `latestAccumHandle` can move between your fetch and your submit, so the attestation you just paid for can already be stale and revert against the contract's handle-match check (see [settlement-and-math.md §1](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback)).

**The move.** You already revealed the accumulator on every pick (§1). Cache that latest attestation; cash-out just submits the cached value — zero new round-trips.

```tsx
// MinesGame.tsx — cache on each pick…
const [hitResult, accumResult] = await retryReveal([hitHandle, accumHandle]);
lastAccumAttestationRef.current = accumResult;   // refreshed every pick

// …and spend the cached one at settlement (no new reveal):
async function handleCashOut() {
  if (gameState !== 'playing' || !lastAccumAttestationRef.current) return;
  setGameState('settling');
  const hash = await cashOut(lastAccumAttestationRef.current);
  await waitForReceipt(hash);
  setGameState('won');
}
```

`cashOut` (in `interface/hooks/use-mines.tsx`) takes the cached `AttestationResult` and hands the contract its two parts — `args: [accum.attestation, accum.signatures]` — which the contract verifies and checks against `latestAccumHandle`.

**Why it works.** Each pick advances the accumulator and re-reveals it, so the cached ref is *always* the attestation for the current on-chain handle by the time the player can cash out — the work was already done as a side effect of playing. Settlement is then a single signed tx with a value you already hold, so it's fast and can't lose a race to its own just-fetched attestation. (The same cached `accumResult` drives auto-cash-out inside `handleTileClick`, and the loss path is symmetric: `concedeLoss` would submit the same attestation with the contract checking the opposite direction — see [settlement-and-math.md §1](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback).)

**Pitfalls.**
- **Reset the cache between games.** `resetGame()` (and `startGame()`) sets `lastAccumAttestationRef.current = null` so a new game can't settle on a previous game's accumulator.
- **Gate settlement on a present cache.** `handleCashOut` bails if the ref is null — there's nothing to submit before the first pick reveals an accumulator.
- **Don't cache the `hit` handle for settlement.** Only the accumulator is the sticky, settle-over handle; `hit` is per-pick and transient.

---

## 3. One popup per action

**Goal.** Each user action is **one** wallet popup — the signed move tx — and nothing else. No second confirmation to "reveal" or to "settle the move."

The one-popup property is reached two ways: a **public** reveal needs no signature (Loop A — `attestedReveal` over a `e.reveal`-ed handle), and a **once-per-session voucher** makes private decrypts popup-free (Loop B — `attestedDecryptWithVoucher`, §4). Either way the signature budget stays at "the move only." The rest of this section walks the Loop A (public-reveal) case in Mines.

**Naïve approach & why it breaks.** The old gateway/callback model is two popups per move: the player signs the move, then signs (or waits on a privileged callback for) a second on-chain decryption step before the UI can advance. That's a confirmation tax on every click, and on a bomb it's offensive — you'd be asking the player to sign a tx that records their own loss, which they have no economic reason to confirm.

**The move.** The move is the only signature. The reveal that learns the outcome is a no-signature `attestedReveal` running in the background (§1), and settlement spends a *cached* attestation (§2) — so the *next* signature only ever appears when the player chooses to cash out.

Concretely in Mines:
- **Pick** → one signed `pickTile` tx; the reveal is background, no popup.
- **Bomb hit** → **no** popup. The frontend already knows the loss from the off-chain `hit` reveal; Mines deliberately does *not* auto-prompt `concedeLoss` (it would be a pointless second popup right after a paid-for losing pick). The factory's 15-min timeout settles on-chain instead — anyone can call `expireGame` (see [settlement-and-math.md §4](settlement-and-math.md#4-settlement-safety)).
- **Cash out** → one signed `cashOut` tx submitting the cached attestation.

**Why it works.** Public reveal = no wallet signature, so the "learn the outcome" step costs the player nothing and can be invisible. The signature budget is spent only where the player has a real decision (move, cash out), never on bookkeeping. This is the direct UX payoff of attestation-based settlement — one revealed handle drives both the win and loss paths off-chain, so the contract never needs a callback and the user never needs a second confirm. The settlement mechanics behind this are in [settlement-and-math.md §1](settlement-and-math.md#1-attestation-based-settlement-no-on-chain-callback).

**Pitfalls.**
- **Block concurrent picks while a reveal is in flight.** `handleTileClick` early-returns if `Object.keys(waitingForDecryption).length > 0`, so the player can't fire a second move (and a second popup) before the first reveal resolves.
- **Optimistic paint, then reconcile.** Mark the tile clicked immediately, but on a reveal/tx error roll it back (`setRevealedTiles(... = false)`, clear `waitingForDecryption`, show the error) so a failed move doesn't leave a phantom-opened tile.

---

## 4. Private per-player decryption: the allowance voucher

*For a **Loop A** game it's an optional layer on top of selective-reveal peeks — your game works without it, just with a wallet popup on each private read; reach for it when that gets annoying. For a **[Loop B](#loop-b--private-decrypt-only-the-acting-player-learns-the-result)** game it's the natural read path — it's how every private per-move decrypt stays popup-free.*

**Goal.** Keep *private, per-player* reads — your poker hand, your secret role, your fog-of-war vision — popup-free, so a player who peeks at hidden state every turn isn't signing a wallet prompt each time.

**Naïve approach & why it breaks.** Section 3's no-popup story relies on **public** reveals (`e.reveal` → `attestedReveal`), which need no signature because the value is already public. But a per-player secret *can't* be revealed publicly — it's granted to one address with `e.allow(handle, player)` (see [selective reveal](patterns.md#selective-reveal)) and read with **`attestedDecrypt`**, which decrypts a *private* handle for an authorized wallet and therefore **needs that wallet to sign every call**. In a card game where the player re-checks their hand each turn, that's a MetaMask popup per peek — it works, but it's clunky.

**The move.** Have the player sign **once** at the start of the session to mint a **session-key allowance voucher**: generate an ephemeral keypair and call `grantSessionKeyAllowanceVoucher(...)`, which authorizes that key to decrypt the player's handles until an expiry you set. Every later peek then uses **`attestedDecryptWithVoucher(...)`** — no wallet popup. Revoke all outstanding vouchers (e.g. on logout) with `updateActiveVouchersSessionNonce(...)`.

```typescript
// Once per session — the ONLY wallet signature for reading private state.
const sessionKey = privateKeyToAccount(generatePrivateKey()); // ephemeral signing account
const voucher = await zap.grantSessionKeyAllowanceVoucher(
  walletClient,
  sessionKey.address,
  new Date(Date.now() + 60 * 60 * 1000), // 1h expiry — scope it deliberately
  defaultSessionVerifier,
);

// Every private peek after that — popup-free. v1: (account, voucher, handles) — no publicClient.
const [hand] = await zap.attestedDecryptWithVoucher(sessionKey, voucher, [handHandle]);
```

*(Exact signatures, the verifier address, and the full flow live in the base API — see the [Session Keys section](../js-sdk-reference.md#session-keys) and the `session-key-decrypt.ts` example. This file is about **when** a game needs it.)*

**Why it works.** The one-time grant delegates decryption to a short-lived key for a bounded window, so the covalidator will attest decryptions for that key without the wallet in the loop. The wallet signs once (set up the session), not once per read — the same "one popup per action" property as Section 3, now extended to the *private* reads `attestedReveal` can't cover. Pure public-reveal games (Mines, Loop A) don't need it at all; **a [Loop B](#loop-b--private-decrypt-only-the-acting-player-learns-the-result) game reads every per-move result through this voucher** (it has no public reveal), and **selective-reveal games — poker hands, mafia roles (archetypes 3 & 4) — benefit most among Loop A games**: they work without it, but a once-per-session grant turns a popup-per-peek into a smooth table.

**Pitfalls.**
- **The voucher does not replace `e.allow`.** You still `e.allow(handle, player)` on-chain so the handle is decryptable at all; the voucher only removes the per-read *signature*. No `e.allow`, nothing to decrypt.
- **Scope and expiry.** The default verifier grants the key *all* of that user's handles for the window — set a sensible expiry, and use a custom session verifier if you need to scope it or add conditions (e.g. payment). Treat the voucher + ephemeral key as a session secret on the client.
- **Revoke on session end.** `updateActiveVouchersSessionNonce` invalidates outstanding vouchers in one tx — wire it to logout / "leave table".

---

## 5. Multiplier / state parity

**Goal.** The UI never shows a number the contract won't honor. A displayed multiplier, payout, or score must equal what settlement will compute on-chain — to the integer.

**Naïve approach & why it breaks.** Compute the displayed multiplier with "close enough" floating-point JS while the contract uses fixed-point integer math. They diverge: per-step integer truncation, a basis-point house edge, and `bigint` scaling all round differently from `Number`. The player sees `2.00×`, settles, and the contract pays `1.97×` — now your UI lied, even if no one cheated.

**The move.** Recompute derived values in TypeScript that is **byte-identical in algorithm** to the contract, using `bigint` and the same `SCALE`, and pin them together with a cross-implementation test.

```ts
// interface/lib/contracts.ts — mirrors MinesMath.sol::calculateMultiplier exactly.
export const MULTIPLIER_SCALE = 1_000_000n; // on-chain SCALE (1e6)

export function calculateMultiplier(safeCount: number, mines: number, total: number): bigint {
  if (safeCount === 0) return MULTIPLIER_SCALE;
  if (safeCount + mines > total) return MULTIPLIER_SCALE;
  let num = MULTIPLIER_SCALE;
  for (let i = 0; i < safeCount; i++) {
    num = (num * BigInt(total - i)) / BigInt(total - mines - i);
  }
  return (num * 9900n) / 10000n; // ×0.99 (HOUSE_EDGE_BPS = 100 → 9900/10000)
}
```

Same loop, same `bigint` truncation per step, same `9900/10000` edge as the Solidity in [settlement-and-math.md §2](settlement-and-math.md#the-hypergeometric-multiplier--house-edge). The UI then prefers the live on-chain read and falls back to this local mirror only when it isn't loaded yet:

```tsx
// MinesGame.tsx — on-chain read first, identical local mirror as fallback
const currentMultiplier =
  (getCurrentMultiplier.data as bigint | undefined) ??
  calculateMultiplier(safeCount, mineCount, TOTAL_TILES);
```

**Why it works.** Because the TS mirrors the Solidity instruction-for-instruction, the fallback value and the on-chain value agree, and the repo's `Mines.multiplier.test.ts` deploys the real contract and asserts fixed reference points — e.g. `calculateMultiplier(1, 3, 25) ≈ 1_125_000` (`25/22 × 0.99`) and `calculateMultiplier(3, 3, 25) ≈ 1_478_569` — so any drift between the two implementations is a failing test, not a silently mispriced cash-out.

**Pitfalls.**
- **Drift is the enemy.** If you change the contract formula, change the TS mirror *and* the cross-implementation test in the same PR. The two are a unit; never edit one alone.
- **Mirror the *shipped* math, not an unmerged design.** The frontend rule is simply: mirror whatever `MinesMath.calculateMultiplier` actually ships today (currently the unbounded 1%-edge curve), and pin it with the cross-impl test — never pull in a not-yet-merged formula, or the UI prices cash-outs the contract won't honor. The unbounded-vs-bounded rationale lives in [settlement-and-math.md §2](settlement-and-math.md#the-bounded--hyperbolic-payout-curve-a-design-upgrade).

---

## 6. Retry / backoff

**Goal.** Survive the gap between "the reveal landed on-chain" and "the covalidator has processed it." Right after the move tx confirms, the covalidator may not have the attestation ready yet — the first fetch can 404.

**Naïve approach & why it breaks.** Hand-roll a `while` loop with a fixed `setTimeout(500)` and a counter. A fixed delay is wrong in both directions: too slow on the common fast path (you make every reveal feel laggy) and too short-lived on the rare slow path (you give up before a backed-up covalidator catches up). You also re-implement, and subtly mis-tune, retry logic the SDK already does.

**The move.** Use the SDK's built-in backoff — pass one config to `attestedReveal`, no manual loop. Mines centralizes it as `REVEAL_BACKOFF` in `interface/lib/inco-attestation.ts`:

```ts
// inco-attestation.ts — bounded exponential backoff: quick early retries, growing tail.
export const REVEAL_BACKOFF = {
  maxRetries: 12,
  baseDelayInMs: 350,
  backoffFactor: 1.4,
};

// retryReveal: the SDK polls the covalidator with this policy — no manual retry loop.
// v1: the backoff goes in the `backoffConfig` field of the opts object.
const results = await zap.attestedReveal(handles, { backoffConfig: REVEAL_BACKOFF });
```

The delay sequence is `350, 490, 686, 960, …` ms (×1.4 each step), so a fast covalidator response feels instant while the tail grows to ~50 s total to cover the rare slow path.

**Why it works.** Exponential backoff is fast where it matters (first attempt at 350 ms) and patient where it must be (12 retries with a growing delay), and it lives in the SDK so you don't re-tune it per call site. Centralizing the config in one exported constant means every Inco-touching path in the app retries with the same policy. See the [retry configuration](../js-sdk-reference.md#retry-configuration) in the base API for the underlying SDK knobs.

**Pitfalls.**
- **Don't hand-roll polling.** Pass the backoff config to the SDK call; a bespoke loop will be both laggier and more fragile than the SDK's.
- **Don't set the first delay to zero or the retry count to a handful.** A 0 ms first attempt hammers the covalidator on the cold path; too few retries gives up before a backed-up covalidator recovers. The shipped values (`350 ms` base, `1.4×`, `12` retries) are tuned for "instant when ready, patient when not."
- **Share one policy.** Import the same `REVEAL_BACKOFF` everywhere rather than sprinkling ad-hoc configs, so reveal behavior is uniform across the app.

---

## 7. Design the reveal

**Goal.** The covalidator round-trip after each move (§6: ~350 ms fast path, seconds on the slow one) feels like part of the game, not lag — and the game looks like *its genre*, not a generic dApp.

**Naïve approach & why it breaks.** Treat the reveal latency as a purely technical problem: a spinner on the board, a "Loading…" toast, all styled with the default-font, purple-gradient dashboard kit every dApp ships. The wait reads as jank, the game reads as a form — and the one moment players actually stare at ("did I hit the bomb?") gets the least design attention in the app.

**The move.** Spend the animation budget on the reveal window, and commit to one aesthetic direction drawn from the game's genre.

- **Time anticipation to the backoff.** The first attestation attempt lands at ~350 ms (§6). Play an anticipation animation that covers that window — the tile trembles, the card starts its flip, the wheel spins — and resolve it into the result the moment `attestedReveal` returns. The fast path feels seamless; the slow path stays *in fiction* (keep looping the anticipation, never degrade to a spinner).
- **Stage multi-handle reveals.** `retryReveal([hitHandle, accumHandle])` returns both handles together (§1), but nothing forces you to paint them together: land the hit first, beat, then count the accumulator/multiplier up. Sequencing one round-trip into beats is free drama.
- **Genre-true aesthetics.** Casino → felt, neon, brass; fog-of-war → darkness and lantern light; social deduction → dossiers and redaction bars. Pick one direction and execute it everywhere; avoid the generic-dApp look (default font stack, purple-on-white gradients, emoji as icons).

**Why it works.** The latency exists either way; animation is the one tool that converts it from perceived jank into perceived suspense — and suspense *is the product* in a hidden-information game. The reveal is also the only moment the player is guaranteed to be watching, so polish concentrated there beats polish spread across the chrome.

**Pitfalls.**
- **Animation may outlast the data, but never the input lock.** Unlock the next move when the attestation lands (§3's in-flight gate), not when the animation finishes — polish must not add real latency.
- **Respect `prefers-reduced-motion`.** Resolve straight to the result state for players who ask for it — a static change, not a spinner.

---

## 8. Async-phase UX

**Goal.** The player always knows *which* stage their move is in. One click crosses up to four async phases — local encrypt, wallet confirm, tx mining, covalidator reveal — with wildly different wait profiles and failure modes.

**Naïve approach & why it breaks.** One `isLoading` boolean and a generic "Processing…" label. The player can't tell a 2-second covalidator poll from a wallet popup stuck behind a window, so they refresh mid-move; and a generic error toast for a fee revert tells them nothing they can act on.

**The move.** Model the move as a phase enum, not a boolean, and bind every piece of feedback to it.

```tsx
type MovePhase = 'idle' | 'encrypting' | 'confirm-in-wallet' | 'mining' | 'revealing';
// per-phase status copy: "Encrypting locally…" / "Confirm in wallet" / "Submitting move…" / "Revealing…"
```

- **Disable the action surface for the whole pipeline** (§3's in-flight gate) and show the phase *on* the disabled control, not in a far-away toast.
- **Reserve layout space for the result.** The revealed value (multiplier, card, hit/miss) pops in when the attestation lands — give it a fixed-size slot from the start so the board never reflows under the player's cursor.
- **Errors land next to the action, named by phase.** Fee revert → on the move button ("Fee not covered — top up"); reveal timeout after §6's backoff is exhausted → on the affected tile with a retry affordance; wallet rejection → reset quietly to `idle` (the player chose it; it's not an error).
- **Roll back optimistic paint on failure in any phase** (§3 pitfall) — the board returns to its pre-move state, never a half-painted one.

**Why it works.** The phases differ by orders of magnitude (encrypt: ms; wallet: human-speed; mining: chain-speed; reveal: §6's backoff) — one spinner averages them into "is it broken?", while named phases keep every wait legible. Reserved slots and adjacent errors are the standard async-UI rules (no content jumping, feedback near the problem) applied to the one pipeline every Inco game has.

**Pitfalls.**
- **Don't surface "revealing" as an error too early.** The §6 backoff deliberately tolerates a slow covalidator for minutes; only an *exhausted* backoff is a failure.
- **`confirm-in-wallet` is the only phase needing the player's action** — make it visually distinct and point at the wallet, or the player stares at a frozen board while the popup waits behind it.

---

## 9. Ship checklist

Before shipping a confidential-game frontend, verify every line (for a real release, create a todo per item):

- [ ] **One popup per action** — the move tx is the only signature; reveals run in the background (`attestedReveal`, §3) or through a session voucher (`attestedDecryptWithVoucher`, §4)
- [ ] Loop matches audience: result is public / the contract settles on it → Loop A; acting player only → Loop B (§1)
- [ ] All handles from one move revealed in **one** `retryReveal([...])` call (§1)
- [ ] Revealed handles decoded from the receipt's event logs, never reconstructed client-side (§1)
- [ ] SDK pre-warmed on mount (`getZap()` in a mount effect) (§1)
- [ ] Attestation cache refreshed on every move, **reset between games**, settlement gated on a present cache (§2)
- [ ] Concurrent moves blocked while a reveal is in flight (§3)
- [ ] Optimistic paint rolls back on tx/reveal failure (§3, §8)
- [ ] Voucher has a deliberate expiry and is revoked on logout / leave-table (`updateActiveVouchersSessionNonce`) (§4)
- [ ] Every displayed number mirrors on-chain math — `bigint`, same `SCALE`, pinned by a cross-implementation test (§5)
- [ ] One shared backoff policy imported everywhere (§6)
- [ ] Reveal animation covers the backoff window; `prefers-reduced-motion` respected (§7)
- [ ] Genre-true direction; no emoji icons; `cursor-pointer` + hover feedback on actionable tiles; ≥44 px touch targets (§7)
- [ ] Move phases named in the UI; errors adjacent to the action; result slots pre-reserved (§8)
