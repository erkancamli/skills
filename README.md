# Inco for AI coding agents

[Inco](https://inco.org) is **full-stack, programmable privacy for blockchains** — protecting address and transaction details to unlock payments, DeFi, onchain finance, gaming, and governance. This repo ships **two agent skills** that work in **Claude Code, Codex, Cursor, and 70+ agents**:

- **`lightning`** — build **confidential smart contracts, dApps, and games** on **Inco Lightning**: encrypted types, programmable access control, and attestation across the `@inco/lightning` Solidity lib + `@inco/lightning-js` SDK. Brings *game-design sense* — deciding **what must stay private**, **which Inco feature to reach for**, and **how to wire it end-to-end**.
- **`ctoken`** — integrate **Inco's Confidential Token (cToken)**: wrap any ERC-20 into private balances and private transfer amounts with the `@inco/ctoken` SDK (core client, React hooks, drop-in UI kit), sessions for silent balance reads, Safe / smart-account support, and the public indexer REST API. Try it live in the [playground](https://ctoken-tze4f72wfa-ew.a.run.app/).

**Download:** [inco-lightning.zip](https://github.com/Inco-fhevm/skills/raw/main/assets/inco-lightning.zip) · [inco-ctoken.zip](https://github.com/Inco-fhevm/skills/raw/main/assets/inco-ctoken.zip)

---

## What the lightning skill does

- **Decides what to hide.** Answer two questions — *what's secret, and when does it reveal?* — and it routes you to the right pattern.
- **Knows the genres.** A catalog of 8 confidential-game archetypes: encrypted board (Mines), fog-of-war (Battleship), hidden hand (poker), hidden roles (mafia), sealed-bid auction, simultaneous-move (RPS), RNG/provably-fair casino, and word/code guessing.
- **Picks the settlement model.** Model A (on-chain attestation — for wagers) vs Model B (private decrypt + client-side — for single-player), with an honest line on when each is safe to use.
- **Writes the contract *and* the frontend.** The encrypt → tx → reveal/decrypt → paint loop, fee handling, attestation verification, the lot.

## What's inside

- **Inco Lightning reference** — Solidity API (encrypted types, `e.allow`, attestation), the `@inco/lightning-js` SDK, encrypted lists, and Foundry/Hardhat + local-covalidator setup.
- **Game-design layer** — the decision tree, archetype catalog, cross-cutting patterns (confidential randomness, sticky accumulator, equality-match, encrypted packing…), the two settlement models, and the frontend loop.
- **Worked contracts to learn from** — a full Stake-style **Mines** (wager, on-chain settlement), a **Hangman** word-guesser (non-wager, client-side), and a **confidential ERC-20** token.

## What the ctoken skill does

- **Ships the v1 facts.** Networks (Base + Base Sepolia), contract addresses, indexer base URLs — so the agent never hardcodes stale ones.
- **Knows all three SDK layers.** Core `CTokenClient` (browser + Node), React hooks on wagmi/react-query, and the drop-in UI kit (`ConfidentialWallet` and friends).
- **Gets sessions right.** Sign-once silent reads, the scoped `CTokenSessionVerifier`, and the smart-account rule (Safe / ERC-1271 users must go through sessions).
- **Covers the indexer API.** Endpoints for tokens, wallets, history, prices; pagination; `Retry-After` semantics; and the production origin-whitelist form.

## Install

**Any agent — [Vercel `skills`](https://github.com/vercel-labs/skills) CLI (recommended).** Works with Claude Code, Codex, Cursor, Cline + 70 more:

```bash
npx skills add Inco-fhevm/skills            # discovers & installs both skills
npx skills add Inco-fhevm/skills -a codex   # …or target a specific agent
```

**Claude Code — native plugin** (gives the namespaced `/inco:lightning` and `/inco:ctoken`):

```bash
/plugin marketplace add Inco-fhevm/skills
/plugin install inco@inco
```

**Manual** — download the zip above, unzip, and copy the skill folder into your agent's skills directory:

```bash
mkdir -p ~/.claude/skills
cp -R lightning ~/.claude/skills/lightning
cp -R ctoken ~/.claude/skills/ctoken
```

The skills auto-activate from their descriptions, so they kick in whenever you describe Inco work.

## Use

Invoke **`/lightning`** or **`/ctoken`** (namespaced `/inco:lightning` / `/inco:ctoken` via the Claude plugin) — or just describe what you want and the right skill activates on its own:

> *"build a confidential sealed-bid auction on Inco"*
> *"what should be private in my on-chain poker game?"*
> *"add a hidden-roles mafia mechanic to my game"*
> *"add a confidential USDC balance to my app with @inco/ctoken"*
> *"wire up the ConfidentialWallet widget on Base Sepolia"*

Start a fresh project with `npx create-inco-app`, or ask the skill to scaffold the Inco starter for you.

## Good to know

- **Inco is TEE-based, not FHE.** "Encrypted" means decrypt-in-TEE; "provably fair" means a covalidator attestation, not a zk proof. The skill is honest about this throughout.
- Pairs with the Inco toolchain: `@inco/lightning` (Solidity) + `@inco/lightning-js` (frontend), both at v1, scaffolded via `create-inco-app` — and `@inco/ctoken` for the Confidential Token SDK.
