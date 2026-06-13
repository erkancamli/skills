# Inco for Claude Code

The **`inco`** [Claude Code](https://claude.com/claude-code) plugin for building **confidential smart contracts, dApps, and games on Inco** — the TEE-based confidential layer for EVM. Its **Inco Lightning** skill (`/inco:lightning`) knows the Solidity lib + `@inco/lightning-js` SDK (v1) cold, and brings *game-design sense*: it helps you decide **what must stay private**, **which Inco feature to reach for**, and **how to wire it end-to-end**. Future Inco skills ship under the same plugin.

**[Download the skill (zip)](https://github.com/Inco-fhevm/skills/raw/main/assets/inco-lightning.zip)**

---

## What it does

- **Decides what to hide.** Answer two questions — *what's secret, and when does it reveal?* — and it routes you to the right pattern.
- **Knows the genres.** A catalog of 8 confidential-game archetypes: encrypted board (Mines), fog-of-war (Battleship), hidden hand (poker), hidden roles (mafia), sealed-bid auction, simultaneous-move (RPS), RNG/provably-fair casino, and word/code guessing.
- **Picks the settlement model.** Model A (on-chain attestation — for wagers) vs Model B (private decrypt + client-side — for single-player), with an honest line on when each is safe to use.
- **Writes the contract *and* the frontend.** The encrypt → tx → reveal/decrypt → paint loop, fee handling, attestation verification, the lot.

## What's inside

- **Inco Lightning reference** — Solidity API (encrypted types, `e.allow`, attestation), the `@inco/lightning-js` SDK, encrypted lists, and Foundry/Hardhat + local-covalidator setup.
- **Game-design layer** — the decision tree, archetype catalog, cross-cutting patterns (confidential randomness, sticky accumulator, equality-match, encrypted packing…), the two settlement models, and the frontend loop.
- **Worked contracts to learn from** — a full Stake-style **Mines** (wager, on-chain settlement), a **Hangman** word-guesser (non-wager, client-side), and a **confidential ERC-20** token.

## Install

**Plugin marketplace (recommended):**

```bash
/plugin marketplace add Inco-fhevm/skills
/plugin install inco@inco
```

The skill is then available as **`/inco:lightning`** and auto-activates from its description.

**Manual (no marketplace):** download the zip above, unzip, and copy the skill folder into your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills
cp -R lightning ~/.claude/skills/lightning
```

_(Or place it in a project's `.claude/skills/` to scope it to one repo. Installed manually it's invoked as `/lightning`.)_

## Use

Open Claude Code and type **`/inco:lightning`** — or just describe what you want and it activates on its own:

> *"build a confidential sealed-bid auction on Inco"*
> *"what should be private in my on-chain poker game?"*
> *"add a hidden-roles mafia mechanic to my game"*

Start a fresh project with `npx create-inco-app`, or ask the skill to scaffold the Inco starter for you.

## Good to know

- **Inco is TEE-based, not FHE.** "Encrypted" means decrypt-in-TEE; "provably fair" means a covalidator attestation, not a zk proof. The skill is honest about this throughout.
- Pairs with the Inco toolchain: `@inco/lightning` (Solidity) + `@inco/lightning-js` (frontend), both at v1, scaffolded via `create-inco-app`.
