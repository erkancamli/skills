---
name: lightning
description: >
  Build confidential smart contracts and dApps on EVM with Inco's TEE-based confidential computing:
  encrypted types (euint256/ebool/eaddress), encrypted ops (add/sub/mul/select/eq/rand), access control
  (e.allow), and attestation verification. Use for @inco/lightning Solidity + @inco/lightning-js SDK encrypt/decrypt,
  Foundry/Hardhat with a local covalidator or Base Sepolia, create-inco-app scaffolding, and confidential
  tokens, auctions, voting, or lottery dApps. Also covers confidential / hidden-information GAMES — deciding
  what stays private and which Inco feature goes where, then building fast: casino, cards, board,
  sealed auction, social deduction, fog-of-war, word/code-guessing.
  TRIGGER: imports "@inco/lightning" or "@inco/lightning-js" (or legacy "@inco/js"), mentions Inco, confidential EVM contracts, encrypted
  types, "what should be private in my game", on-chain poker/mafia/minesweeper/word-guessing, fog of war,
  provably fair.
  NOT for: ZK proofs, FHE/fhevm circuits.
---

# Inco EVM Development

Build confidential smart contracts on EVM chains. Inco uses TEE-based confidential computing to add encrypted data types, operations, and programmable access control to Solidity without modifying the underlying blockchain. This skill covers Inco on **EVM (Inco Lightning)**; Inco's Solana/SVM track is out of scope here.

**IMPORTANT: Inco is NOT FHE (Fully Homomorphic Encryption). It is TEE-based (Trusted Execution Environment). Never describe Inco as FHE to users.** While the developer-facing API uses "encrypted" terminology (euint256, ebool), the underlying cryptographic mechanism is encryption/decryption in TEE, not homomorphic encryption.

## CRITICAL: Three Rules That Break Every New Project

1. **Always call `allowThis()`** after storing an encrypted handle - the contract permanently loses access otherwise
2. **Always pay the fee** via `msg.value >= inco.getFee()` for every `newEuint256`/`newEbool`/`newEaddress` call or wherever consuming a bytes calldata ciphertext
3. **Never use `if/else` with encrypted conditions** - use `condition.select(ifTrue, ifFalse)` instead

### Red Flags — STOP if you catch yourself thinking:

| Thought | Reality |
|---------|---------|
| "I'll add `allowThis()` in a cleanup pass" | Access is lost **permanently** once the tx lands. Add it on the line after every encrypted store. |
| "This encrypted condition is simple — `if/else` is fine" | An `ebool` is a handle, not a bool. Branching on it is broken code. Use `.select()`, no exceptions. |
| "Fee handling can come later" | Every ciphertext ingest and `rand`/`shuffle` call reverts unfunded. Decide user-pays vs contract-sponsored before writing the function. |
| "The validation checklist is overkill for this small contract" | Small contracts lose handles too. Run the checklist before every deploy. |

## Architecture (30-second overview)

```
Frontend (@inco/lightning-js)     Smart Contract (@inco/lightning)     Covalidator (TEE)
─────────────────────────────     ───────────────────────────────      ──────────────────
zap.encrypt(value) ──────────> newEuint256(bytes, sender)
                                e.add / e.sub / e.select / ...
                                e.allow(handle, user)
zap.attestedDecrypt(handle) <──────────────────────────────────── decrypt + sign
submit attestation on-chain -> incoVerifier().isValidAttestation()
```

## Quick Start

### 1. Scaffold a project
```bash
npx create-inco-app my-app --chain evm --framework hardhat --wallet rainbowkit --yes
```

### 2. Minimal Solidity contract
```solidity
import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";

contract MyConfidentialContract {
    using e for *;
    mapping(address => euint256) public balanceOf;

    function deposit(bytes memory encryptedAmount) external payable {
        require(msg.value >= inco.getFee(), "Fee not paid");
        euint256 amount = encryptedAmount.newEuint256(msg.sender);
        euint256 newBal = balanceOf[msg.sender].add(amount);
        balanceOf[msg.sender] = newBal;
        newBal.allow(msg.sender);   // User can decrypt
        newBal.allowThis();          // CRITICAL: contract retains access
    }
}
```

### 3. Frontend encryption + decryption
```typescript
import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes } from "@inco/lightning-js";

const zap = await Lightning.baseSepoliaTestnet(); // Base Sepolia (chain 84532)

// Encrypt
const ct = await zap.encrypt(100n, {
  accountAddress: userAddress,
  dappAddress: contractAddress,
  handleType: handleTypes.euint256,
});

// Send to contract (with fee as msg.value)
writeContract({ address: contractAddr, abi, functionName: "deposit", args: [ct], value: fee });

// Decrypt (retry if covalidator hasn't processed yet)
const results = await zap.attestedDecrypt(walletClient, [handle]);
const plaintext = results[0].plaintext.value;
```

## Pick your path

`create-inco-app`'s `--template` maps to three ways to use this skill — load only the slice you need:

- **Full dApp** (`--template monorepo`, default) — the Quick Start above, then references as needed.
- **Contracts only** (`--template contracts`) — encrypted types, `allow`/`allowThis`, fee handling, and `.select` (never `if/else` on encrypted conditions); write and unit-test in Foundry/Hardhat with IncoTest. → [solidity-reference.md](references/solidity-reference.md), [deployment-testing.md](references/deployment-testing.md), [scripts/ConfidentialToken.sol](scripts/ConfidentialToken.sol).
- **Frontend only** (`--template frontend`, integrating an already-deployed confidential contract) — encrypt/decrypt against a contract you may not own. → [js-sdk-reference.md (integrating an existing contract)](references/js-sdk-reference.md#integrating-an-existing-contract), [examples/basic-encrypt-decrypt.ts](examples/basic-encrypt-decrypt.ts), [scripts/incoHelper.ts](scripts/incoHelper.ts).

## Building a confidential game?

Designing a hidden-information game (casino/provably-fair, cards, board, sealed auction, social deduction, fog-of-war, word/code guessing)? The base API on this page still applies — but start at **[references/games/overview.md](references/games/overview.md)**: it has the decision tree (what's secret, when does it reveal), the archetype catalog, the cross-cutting moves, the two settlement models, and the frontend loop. Load only the games references the task needs.

**Building a deck-shaped game (card hands, hidden roles, or a random draw)?** The [ConfidentialDeck template](https://github.com/Inco-fhevm/confidential-deck-template) is the fastest start: four worked games (War, Blackjack, Raffle, Mafia) on one base contract, an `AGENTS.md` that briefs your AI, and a [live demo](https://confidential-deck.vercel.app). It fits only that deck shape; see [Game jam: build a deck-shaped game fast](references/games/overview.md#game-jam-build-a-deck-shaped-game-fast) for what it covers and where to go otherwise.

**Design before code (RIGID):** do NOT write any Solidity until you have answered the decision tree — *what is secret, from whom, and when does it reveal*. Code written before those answers bakes in the wrong privacy boundary and gets rewritten. "The game is simple, I'll design as I go" is the red flag — simple games still leak through event logs, public state, and reveal timing.

## Core Concepts

### Encrypted Types
`euint256`, `ebool`, `eaddress` - all are `bytes32` handles pointing to encrypted data off-chain.

### Operations

With `using e for *;`, there are two equivalent calling styles:

```solidity
// Style 1: variable.operation(other) - method syntax on the encrypted variable
euint256 sum = a.add(b);
ebool isGreater = a.ge(b);
euint256 result = condition.select(ifTrue, ifFalse);

// Style 2: e.operation(a, b) - static call via the `e` library
euint256 sum = e.add(a, b);
ebool isGreater = e.ge(a, b);
euint256 result = e.select(condition, ifTrue, ifFalse);
```

Both are identical. Use whichever reads better in context.

**Static-only operations** (no variable to call on):
```solidity
e.rand()                  // Random euint256
e.randBounded(n)          // Random euint256 in [0, n)
e.asEuint256(42)          // Plaintext -> encrypted handle
e.asEbool(true)           // Plaintext -> encrypted handle
e.asEaddress(addr)        // Plaintext -> encrypted handle
```

**Available operations:**
Math: `add`, `sub`, `mul`, `div`, `rem`, `and`, `or`, `xor`, `shr`, `shl`
Compare: `eq`, `ne`, `ge`, `gt`, `le`, `lt`, `min`, `max`, `not`
Control: `select(ifTrue, ifFalse)` (first arg = value when condition is true) - NEVER use if/else with encrypted conditions

### CRITICAL: Access Control
```solidity
newValue.allow(userAddress);  // User can decrypt
newValue.allowThis();         // Contract can use in future txs
```
Forgetting `allowThis()` = contract loses access to the handle permanently.

### Fee Payment
Every `newEuint256`/`newEbool`/`newEaddress` call (and `rand`/`randBounded`/`shuffle`) charges `inco.getFee()`, drawn from the **contract's balance**. Either the user pays it (`payable` + `require(msg.value >= inco.getFee())`) or you **pre-fund the contract to sponsor it** (gasless for the caller). See [Fee Payment](references/solidity-reference.md#fee-payment).

### Attestation Verification
```solidity
require(inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures), "Invalid");
require(euint256.unwrap(myHandle) == decryption.handle, "Handle mismatch"); // ALWAYS check
```

## CRITICAL: Validation Checklist

Before deploying any Inco contract, verify:
- [ ] Every encrypted state update calls `.allowThis()`
- [ ] Every user-facing value calls `.allow(userAddress)`
- [ ] All functions accepting encrypted bytes are `payable` with fee check
- [ ] No `if/else` or `require` on encrypted conditions (use `.select()`)
- [ ] `using e for *;` is declared in the contract
- [ ] Frontend encrypts with correct `accountAddress` and `dappAddress`
- [ ] Attestation submissions verify handle matches on-chain

## Detailed References

- **Solidity API**: All types, operations, access control, attestation patterns - see [solidity-reference.md](references/solidity-reference.md)
- **JS SDK**: Encrypt, decrypt, attested compute, session keys, wagmi hooks - see [js-sdk-reference.md](references/js-sdk-reference.md)
- **Deployment & Testing**: Foundry/Hardhat setup, Docker local node, testnet deploy, IncoTest cheatcodes - see [deployment-testing.md](references/deployment-testing.md)
- **EList**: Encrypted dynamic lists (graduated into core `@inco/lightning` in v1) - see [elist-reference.md](references/elist-reference.md)
- **Confidential Games**: the game-design layer — start at [references/games/overview.md](references/games/overview.md)

## Ready-to-Use Templates

- [scripts/ConfidentialToken.sol](scripts/ConfidentialToken.sol) - Complete confidential ERC20 with mint, transfer, approve, transferFrom
- [scripts/ConfidentialWithAttestation.sol](scripts/ConfidentialWithAttestation.sol) - All 3 attestation patterns (decrypt, reveal, compute)
- [scripts/incoHelper.ts](scripts/incoHelper.ts) - Frontend utility: encrypt, decrypt with retry, fee fetching, attestation formatting
- [scripts/games/mines/](scripts/games/mines/) - **Confidential Mines** (Model A wager) — encrypted board shuffle, sticky accumulator, on-chain attestation settlement, factory bankroll/liability. Audited reference (`Mines.sol` + `MinesMath.sol` + `MinesFactory.sol`)
- [scripts/games/hangman/IncoHangMan.sol](scripts/games/hangman/IncoHangMan.sol) - **Confidential Hangman** (Model B word-guess) — packed word, `e.eq` match, private per-player decrypt, client-side settlement. POC — see header caveats

## Runnable Examples

- [examples/basic-encrypt-decrypt.ts](examples/basic-encrypt-decrypt.ts) - Core flow: init SDK, encrypt, send to contract, decrypt with retry
- [examples/confidential-token-interaction.ts](examples/confidential-token-interaction.ts) - Mint, transfer, approve, transferFrom with encrypted token
- [examples/attestation-flow.ts](examples/attestation-flow.ts) - All 3 attestation patterns end-to-end (decrypt, reveal, compute)
- [examples/session-key-decrypt.ts](examples/session-key-decrypt.ts) - Session keys for popup-free decryption and delegation

## Troubleshooting

Common issues and fixes: [docs/troubleshooting.md](docs/troubleshooting.md)
Covers: fee errors, missing allowThis, covalidator timeouts, handle formatting, Docker issues, Foundry test pitfalls.

## Common Patterns

### Multiplexer (Silent Failure)
```solidity
ebool canTransfer = balanceOf[sender].ge(amount);
euint256 transferred = canTransfer.select(amount, e.asEuint256(0));
// Transfers 0 instead of reverting - hides the failure reason
```

### Dual Function (EOA + Contract)
```solidity
// EOA: encrypted bytes input (requires fee)
function transfer(address to, bytes memory input) external payable { ... }
// Contract: existing handle (requires isAllowed check)
function transfer(address to, euint256 value) public { ... }
```

### Full Encrypt-Compute-Decrypt Flow
1. Frontend: `zap.encrypt(value)` -> ciphertext bytes
2. Contract: `newEuint256(bytes, sender)` -> handle, then encrypted operations
3. Contract: `e.allow(result, user)` -> grant decryption access
4. Frontend: `zap.attestedDecrypt(walletClient, [handle])` -> plaintext + signatures
5. (Optional) Frontend: submit attestation on-chain for verification

## Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `@inco/lightning` | latest (v1+) | Solidity library  — install `@latest` |
| `@inco/lightning-js` | latest (v1+) | JavaScript SDK (renamed from `@inco/js`) — install `@latest` |
| Solidity | 0.8.30 | Compiler version (0.8.29+ supported) |
| EVM | cancun | Target EVM version |
