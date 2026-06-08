# Settlement and Payout Math

How a confidential game turns an *encrypted* outcome into a *trustless* result. There are **two settlement/reveal models**, and most of this file is about the first:

- **Model A — public reveal + on-chain verify** (this section). The *contract* must act on the secret trustlessly — pay out, declare a winner, end a round. Use it whenever funds, a pot, or contract-/shared-authority depend on the outcome. **Section 1 below is Model A.**
- **Model B — private decrypt + client-side enforcement.** Only the *acting player* needs their own result; the contract grants `e.allow(handle, player)` and the player reads it off-chain with `attestedDecrypt` / a session voucher (see [frontend.md Loop B](frontend.md#loop-b--private-decrypt-only-the-acting-player-learns-the-result)), then the **client enforces the rules**. The contract never verifies an attestation. This is how a single-player word-guesser or any non-stake game settles — see the callout at the end of this section.

**Decision rule:** does the contract / another player / a pot need to trust and act on the outcome? → **Model A**. Does only the acting player need to see their own result, with no stakes the contract must guard? → **Model B**. Games often mix: Model B for per-turn feedback, Model A at final cash-out.

**Sections 2–4 are for wager/casino games** (payout math, factory liability, settlement safety); skip them for a card, social-deduction, or single-player game with no bankroll.

Base Inco API — encrypted types, `e.allow`/`e.reveal`, fees, and the attestation-verify boilerplate — lives in the base skill's `references/*-reference.md` files; this file links to it rather than re-teaching it. Inco is **TEE-based, not FHE**: "encrypted" means decrypt-in-TEE, and "provably fair" here means an **attestation**, not a zero-knowledge proof (see [choosing-your-approach.md §3](choosing-your-approach.md#3-honest-tee-framing) for the honest framing).

---

## 1. Attestation-based settlement (no on-chain callback)

**Goal.** Turn an encrypted result (the accumulator bit "did the player ever hit a bomb?", a hidden score, a winner flag) into a settlement the contract can act on trustlessly — pay out, declare a winner, end the round — without an oracle calling back into your contract.

**Naïve approach & why it breaks.** Decrypt synchronously per move via a gateway callback: each move queues a decryption request, an off-chain decryptor calls back into the contract with the plaintext, and the contract advances. Three failures. (1) **Cost & latency scale with moves** — one async round-trip per move is O(N) request/callback overhead for an N-move game. (2) **Single point of failure** — the callback caller is a privileged, special-cased address; if the gateway stalls or is censored, the game is stuck mid-state with funds trapped. (3) **Mid-game state inconsistency** — between "request decrypt" and "callback arrives" the contract sits in a half-decided state, and you must defend every other entrypoint against acting on it.

**The move.** Reveal on-chain, pull the attested value off-chain, verify it at settlement. No callback ever enters your contract.

1. During play, `e.reveal(...)` the handle you'll settle over (queues it for public decryption — **no wallet signature needed for a public reveal**).
2. The frontend pulls a **covalidator-signed decryption attestation** for that handle off-chain via the JS SDK's attested-reveal flow (see [the base JS SDK reference](../js-sdk-reference.md)).
3. At settlement, the player submits the attestation; the contract verifies the signature, **checks the attested handle matches the on-chain handle**, and reads the value.

```solidity
// Mines.sol — cashOut(): settle over the accumulator, no callback.
require(openedTiles.length > 0, "need a pick");
require(accumAttestation.handle == latestAccumHandle, "stale attestation"); // ← handle-match
require(
    inco.incoVerifier().isValidDecryptionAttestation(accumAttestation, signatures),
    "bad sig"
);
require(asBool(accumAttestation.value) == false, "hit a bomb"); // read the decrypted bit
```

**Why it works.** The reveal is public and the verify is pull-based: the *player* brings the proof at the moment they want to settle, so there is no privileged callback caller to censor or to trust, and no half-decided window — the game is in exactly one state before the call and another after. The covalidator signature is what makes it trustless (this is the "provably fair via TEE attestation" claim, not zk — see [choosing-your-approach.md §3](choosing-your-approach.md#3-honest-tee-framing)). Crucially, the contract chooses the *direction* of the check at settlement (`== false` to cash out vs `== true` to concede in `concedeLoss`, the loss-path twin of `cashOut`), so one revealed handle drives both the win and the loss path.

**Pitfalls.**
- **Always check the handle matches** (`accumAttestation.handle == latestAccumHandle`). The signature only proves "the TEE decrypted *some* handle to *this* value" — without the handle-match a player could submit a validly-signed attestation for a *different* handle (an earlier, still-safe accumulator, or a trivially-`false` one) and settle on a value that was never the live state.
- **Reject stale handles.** The accumulator handle changes on every move; track `latestAccumHandle` and require the attestation targets it, so an attestation captured earlier in the game can't be replayed.
- **Settle over a [sticky accumulator](patterns.md#sticky-accumulator), not per-move attestations.** Folding every move into one persistent handle (`e.or` for "ever happened", `e.add`/`e.min`/`e.max` for totals) means settlement verifies **one** attestation regardless of move count — O(1) instead of O(N) round-trips. The per-move `hit` handle is transient (memory-only, auto-granted access); only the accumulator is stored across txs and needs `e.allow(…, address(this))` + `e.reveal`. See [patterns.md](patterns.md#sticky-accumulator) for the fold.

### Model B — no on-chain settlement (client-side enforcement)

When no pot or contract-authority rides on the outcome, you don't need any of the above. The contract keeps the secret as encrypted state and grants the acting player read access (`e.allow(resultHandle, player)`); the player decrypts their own per-move result off-chain (`attestedDecrypt` / `attestedDecryptWithVoucher`) and the **client** decides win/lose and what to render. No `e.reveal`, no `isValidDecryptionAttestation`, no attestation submitted on-chain. A single-player word-guesser is the canonical case: the contract never learns whether you won.

**Honest boundary.** A client-enforced outcome is *asserted by the client* — the contract cannot trust it. Use Model B only where nothing the contract must guard depends on the result (single-player, practice, non-stake). The moment money, a leaderboard the contract pays, or another player depends on the outcome, you need Model A's on-chain verify.

---

## 2. Payout math (casino-specific)

> This entire section is for **wager games** that pay a multiple of a bet. Non-casino games (poker, mafia, board games with no bankroll) have no payout curve — skip to [section 4](#4-settlement-safety) for the parts that still apply, or skip this and section 3 entirely.

### The hypergeometric multiplier + house edge

**Goal.** Price a cash-out fairly: a player who has opened `safeCount` safe tiles on a board of `total` tiles with `mines` mines should be paid the inverse of the probability they got that far, minus the house's cut.

The probability of opening `k` consecutive safe tiles is `∏ (safe_remaining / tiles_remaining)`; the fair multiplier is its reciprocal. `MinesMath.sol` computes that product directly and applies a flat house edge in basis points:

```solidity
// MinesMath.sol — canonical hypergeometric multiplier, ×SCALE (1e6).
uint256 internal constant SCALE = 1_000_000;
uint256 internal constant HOUSE_EDGE_BPS = 100; // 1.00 %

function calculateMultiplier(uint256 safeCount, uint256 mines, uint256 total)
    internal pure returns (uint256)
{
    if (safeCount == 0) return SCALE;                 // safeCount=0 → 1.0×, principal returned
    require(safeCount + mines <= total, "invalid args");
    uint256 num = SCALE;
    for (uint256 i = 0; i < safeCount; i++) {
        num = (num * (total - i)) / (total - mines - i);   // ∏ (n−i)/(n−m−i)
    }
    return (num * (10_000 - HOUSE_EDGE_BPS)) / 10_000;      // subtract the edge
}
```

Winnings are `betAmount × multiplier / SCALE` (`calculateWinnings`); the maximum possible payout for a game is the multiplier at `safeCount = total − mines`, i.e. every safe tile opened (`calculateMaxPayout`). All three live in one library so the cash-out math and the factory's reservation math (section 3) can never drift apart — the comment in `MinesMath.sol` calls this out as protecting the solvency invariant `winnings ≤ maxPayout`.

### The bounded / hyperbolic payout curve (a design upgrade)

**The problem the curve solves.** The canonical multiplier above is **unbounded**: on a 5×5 board with 3 mines, opening all 22 safe tiles pays ~2,300× the bet. That wrecks factory solvency — because the factory must reserve the *max* payout per game (section 3), a 10 ETH bankroll backing a ~2,300× tail can only accept bets of ~0.004 ETH. The genre's appeal (a huge top multiplier) is exactly what makes it un-bankrollable at small treasury sizes.

**The fix (design doc, not yet in the live `MinesMath.sol`).** The bounded-payout-curve design doc specifies a hyperbolic-asymptote curve applied to the *gain* portion of the multiplier so payout **asymptotically caps** at a bankroll-derived `M_max` (e.g. 100×) while staying strictly monotonic — every safe pick still has positive marginal value, and `safeCount = 0` still returns exactly the bet:

```
M_final = 1 + g / (1 + g / (M_max − 1))      where g = (canonical − 1) × (1 − edge)
```

As `canonical → ∞`, `M_final → M_max` but never reaches it; for small `canonical` it's ≈ canonical-fair-with-edge. So the ~2,300× tail compresses toward ~96× (capturing more edge precisely where the canonical tail was unaffordable) while low-multiplier games pay almost canonical. It stays deterministically recomputable, so provably-fair players can still verify it. See the design doc for the exact Solidity, the numerical reference table, and the mandatory Solidity↔TypeScript cross-implementation test that prevents silent payout drift.

> **Accuracy note:** the *currently committed* `MinesMath.calculateMultiplier` is the **unbounded** canonical version with a **1%** edge (the snippet above and its test, `Mines.multiplier.test.ts`, assert `25/22 × 0.99 = 1.125×`). The bounded curve (and the move to a 3% edge) is an approved design spec, not yet merged. Treat the curve as the recommended *pattern* for any factory-backed wager game; treat the loop above as the *shipped* math.

---

## 3. Factory liability reservation

> Wager-games only. This is how a factory that holds bets and pays winners stays solvent.

**Goal.** Never accept a bet you cannot pay out, even in the worst case where every active player wins their maximum.

**Naïve approach & why it breaks.** Accept bets and pay winners as they come, checking only `address(this).balance >= thisWinning` at cash-out time. With many concurrent games, several players can each be *individually* affordable yet *collectively* exceed the balance — the factory is fractional-reserve by accident, and a cluster of simultaneous max-payout wins drains it, leaving the last winners unpaid.

**The move.** Compute the worst-case payout up front, reserve it, and gate new games on a cumulative solvency check.

```solidity
// MinesFactory.sol — reserve the worst case, gate on the cumulative invariant.
uint256 public totalActiveLiability;

function canAffordMaxPayout(uint256 size, uint256 bombs, uint256 betAmount)
    public view returns (bool)
{
    uint256 maxPayout = calculateMaxPayout(size, bombs, betAmount); // same MinesMath lib as cashout
    return address(this).balance >= totalActiveLiability + maxPayout;
}
// On create: require balance covers all active games' max payouts, then
totalActiveLiability += maxPayout;   // reserve
// On settle (payout / loss / expiry):
totalActiveLiability -= gameInfo.maxPayout;  // release
```

`payoutPlayer` adds defense-in-depth: `require(amount <= gameInfo.maxPayout)` — the actual cash-out can never exceed what was reserved, which holds *because* the reservation and the cash-out both call the same `MinesMath` library.

**Permissionless capped cleanup.** Reserved liability is only freed when a game settles or expires, so expired-but-unsettled games would pin liability forever and eventually block new games. The factory sweeps them — but **bounded**:

```solidity
// Sweep up to a cap per create; anyone can also call the paginated version.
uint256 public constant CLEANUP_CAP_DEFAULT = 16;
_cleanupExpiredGames(CLEANUP_CAP_DEFAULT);          // inside createMinesContract
// cleanupExpiredGames(uint256 maxIterations) is public & paginated — amortize across callers.
```

**Pitfalls.**
- **Never run an unbounded cleanup loop inside a user-facing call.** Iterating the full active-games array on every create is an O(N) (worst-case O(N²) over a session) gas-DoS vector — a backlog of stale games makes new games progressively more expensive until they revert. Cap the sweep and expose a separate paginated, permissionless `cleanupExpiredGames` so cleanup cost is amortized, not borne by the next player. (This is audit fix F-4.)
- **Reserve cumulative, not per-game.** The invariant is `balance ≥ Σ maxPayout` over *all* active games, not `balance ≥ thisGame.maxPayout`. Track one running `totalActiveLiability` and check against it on every create.
- **Reserve the *max* payout, not the current one.** A player can keep opening tiles after the game is created; reserve the full-board payout at create time so a later run-up can always be honored.

---

## 4. Settlement safety

A short checklist for the payout/settlement path. Each item maps to a fix in the repo's README audit table; reentrancy-guard *mechanics* live in the base references and standard Solidity references — here it's the game-settlement-specific list.

- **Pay with `.call{value:}`, not `.transfer` — and keep `nonReentrant`** (F-1). `.transfer` forwards only a 2300-gas stipend, which silently bricks payouts to smart-contract beneficiaries (Safe, AA wallets, EIP-7702). Use `(bool ok, ) = payable(beneficiary).call{value: amount}(""); require(ok);` and guard the function so `.call` re-entry is safe.
- **Provide a timeout / `expireGame` refund path** (F-3). Attested settlement is *asynchronous* — the player fetches the attestation off-chain and submits it. If the game has a timeout (Mines: 15 min), a slow attestation could otherwise let a *winning* player's bet be trapped or confiscated. `expireGame` permissionlessly refunds the bet on timeout so a slow reveal never costs the player. (Known trade-off: a pure timeout refund can't tell "winner who was slow" from "loser who walked away"; a real-money build should gate the refund on an attestation that no bomb was hit — see the README's known-economic-edge-case note.)
- **Withdraw must not drain reserves backing active games** (F-2). Owner withdrawal is capped to `getAvailableBalance()` (`balance − totalActiveLiability`); funds reserved for live games are not withdrawable, closing the rug-active-players path.
- **Make functions non-payable when no op charges a fee** (F-5). `pickTile` is *not* payable — none of the encrypted ops it runs (`getEbool`, `e.or`, `e.reveal`) charge an Inco fee (only the randomness/shuffle ops at board setup do; see [patterns.md](patterns.md#confidential-randomness) on fee-charging calls). A payable function with no fee to charge just strands user funds. Only mark a function payable where it actually forwards a fee (e.g. `initBoard` forwarding `inco.getFee()`).
