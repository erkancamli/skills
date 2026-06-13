# inco-skill

A [Claude Code](https://claude.com/claude-code) skill for building **confidential games and dApps on Inco** — the TEE-based confidential layer for EVM. It knows Inco Lightning (the Solidity lib + `@inco/lightning-js` SDK, v1) cold, and it brings *game-design sense*: it helps you decide **what must stay private**, **which Inco feature to reach for**, and **how to wire it end-to-end**.

**[Download inco-skill.zip](https://github.com/Inco-fhevm/skills/raw/main/assets/inco-skill.zip)**

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

Unzip, then drop the folder into your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills
cp -R inco-skill ~/.claude/skills/inco-skill
```

_(Or place `inco-skill/` in a project's `.claude/skills/` to scope it to a single repo.)_

## Use

Open Claude Code and type **`/inco-skill`** — or just describe what you want and it activates on its own:

> *"build a confidential sealed-bid auction on Inco"*
> *"what should be private in my on-chain poker game?"*
> *"add a hidden-roles mafia mechanic to my game"*

Start a fresh project with `npx create-inco-app`, or ask the skill to scaffold the Inco starter for you.

## Good to know

- **Inco is TEE-based, not FHE.** "Encrypted" means decrypt-in-TEE; "provably fair" means a covalidator attestation, not a zk proof. The skill is honest about this throughout.
- Pairs with the Inco toolchain: `@inco/lightning` (Solidity) + `@inco/lightning-js` (frontend), both at v1, scaffolded via `create-inco-app`.
