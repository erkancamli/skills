# Choosing Your Approach

Inco encrypted state is one way to hide game information — not the only one, and not always the right one. This is a routing reference: pick the privacy mechanism that fits your game's *reveal shape*, then build. Base API → the [main skill page](../../SKILL.md) / base references. Inco is **TEE-based, not FHE** (see [§3](#3-honest-tee-framing)).

---

## 1. The comparison — Inco vs commit-reveal vs zk vs trusted server

Four ways to keep a value hidden until it should not be. They differ less in "how private" and more in **what kind of secret** they fit and **when the secret comes out**.

| Approach | Good for | Failure modes / cost | Reveal timing it suits |
|---|---|---|---|
| **Commit-reveal** — `hash(value + salt)` on-chain now, reveal the preimage later, contract re-hashes to verify | One-shot secrets that all open *simultaneously* at settlement (sealed-bid auction, rock-paper-scissors) | **Last-revealer problem**: the final party to reveal sees everyone else's values first and can **abort by withholding** their reveal if the outcome is bad — needs collateral/slashing to deter. **Two transactions** by construction: commit tx + reveal tx — extra gas and a second round-trip. **Forces the user back online** to reveal. | Commit once, reveal once, all at the end |
| **zk (SNARK proofs + commitments)** — commit to a hidden value, then either prove statements about it *without revealing it* (SNARK) or open it at the end (commitment); the secret stays client-side (Dark Forest SNARK fog-of-war, BattleZips Pedersen-commitment Battleship, zkwitches social deduction) | Hidden state you **never reveal** but prove things about (you moved legally; your ship is/ isn't here) | **Static commitments**: ideal for a *fixed* hidden value, awkward for **mutable, long-lived, per-player live state**. **Circuit complexity / proving cost / tooling burden**, and some SNARKs need a **trusted setup** (transparent systems like STARKs/Bulletproofs avoid it). Small state spaces can be **brute-forced** (the Dark Forest position caveat). | Never (you prove, you don't reveal), or reveal at the very end |
| **Trusted off-chain server** — classic "provably fair" casino: server seed + client seed, server-seed hash published up front, revealed after the round | Familiar, cheap, flexible house-vs-player games where players accept an operator | **You trust the operator** not to swap unrevealed seeds or pick favorable outcomes. Not on-chain-native; reveal is **operator-driven**, not protocol-enforced. | Operator reveals the server seed after the bet |
| **Inco encrypted state (TEE)** — `euint`/`ebool`/`eaddress` as **mutable live on-chain state**, **selectively visible per player** via [`e.allow`](../../SKILL.md) | **Mutable secret state updated across turns** that must be **selectively visible per player** (live poker hands, evolving fog-of-war, hidden roles) | **TEE trust model**: privacy rests on Intel TDX enclave + attestation, **not** zero-knowledge math (see [§3](#3-honest-tee-framing)). | Any time — per-player now via `e.allow`, or aggregate at settlement; no second tx, no last-revealer abort |

The axis that decides it is **the secret's lifecycle**. Commit-reveal and zk commitments are built around a *fixed* value: you lock it once and either open it once (commit-reveal) or never (zk). They strain the moment the secret must **mutate across turns** or be **read by different players at different times** — commit-reveal would need a fresh commit per change (and a fresh reveal tx), and zk would need a fresh proof per statement. Inco's model is the inverse: the secret stays live and encrypted on-chain, mutates in place with encrypted ops, and visibility is an on-chain grant you re-issue per handle — at the cost of trusting the enclave instead of math. The trusted server is the pragmatic outlier: cheapest and most flexible, but its "fairness" is a promise, not a protocol guarantee.

---

## 2. The decision rule

> If the secret is **mutable live state** that must be **selectively visible per player** and updated across turns → **Inco encrypted state**. If it's a **one-shot commitment revealed simultaneously** → **commit-reveal** may be enough. If you need **trustless mathematical** privacy of a fixed hidden value with no trusted hardware → **zk**.

Worked routings:

- **Live poker hands** (each player reads only their own cards, hands change every deal) → Inco `e.allow` per player. Mutable + per-player visibility is exactly its lane.
- **A single sealed bid opened once** at auction close → commit-reveal is fine. One value, one simultaneous reveal — don't reach for encrypted state.
- **Fog-of-war you never reveal** and want trustless → **zk** if you need hardware-free mathematical privacy; **Inco** if the state mutates a lot per turn or must be selectively visible and you accept the TEE trust model.
- **Classic casino with an operator the players already trust** → server-seed / client-seed "provably fair". On-chain encrypted state is overkill if an off-chain operator is acceptable.

Two-transaction acceptable and the secret opens once? Commit-reveal is the cheaper start. Secret never opens at all? That's zk's home turf. Secret lives, mutates, and is read by different players across a match? That's what Inco encrypted state is for.

**Once you've chosen Inco, choose the settlement model too.** If the *contract* must act on the secret (pay out, declare a winner, anything touching funds or shared authority) → **Model A**: public `e.reveal` + on-chain `isValidDecryptionAttestation`. If only the *acting player* needs their own result and no stakes ride on it (single-player guessers, practice modes) → **Model B**: `e.allow` + private `attestedDecrypt`, with the client enforcing the rules and no on-chain settlement. Details and the honest boundary are in [settlement-and-math.md (Model B)](settlement-and-math.md#model-b--no-on-chain-settlement-client-side-enforcement).

---

## 3. Honest TEE framing

Inco's **shipped** product is **TEE-based (Intel TDX), not FHE**. The FHE/MPC layer is on the roadmap, not in production — so do not pitch or design as if homomorphic or threshold cryptography is doing the work today. This matches the base skill's standing note: *"Inco is NOT FHE… the underlying cryptographic mechanism is encryption/decryption in TEE, not homomorphic encryption"* (see the [main skill page](../../SKILL.md)).

What this means for "provably fair" on Inco: a reveal is backed by an **attestation** — a covalidator-signed decryption proof verified on-chain via `incoVerifier().isValidDecryptionAttestation(...)` — **not** a zero-knowledge mathematical proof. The trust assumption is **the enclave plus its attestation**: players are trusting that Intel TDX kept the data confidential and that the covalidator signed honestly, not trusting a piece of math that holds regardless of hardware.

Communicate that to players honestly. "Provably fair via TEE attestation" is a real and strong claim — but it is **not** zk-grade trustlessness, and implying otherwise misrepresents the threat model. If your game's selling point *must* be hardware-free mathematical privacy, that's the signal to use **zk** instead of Inco; if a TEE trust model is acceptable (and for most live, mutable, per-player game state it is), Inco buys you live encrypted state and per-player reveal that zk and commit-reveal cannot.
