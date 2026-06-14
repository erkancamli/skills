# Inco JavaScript SDK Reference

## Table of Contents
- [Installation](#installation)
- [Initialization](#initialization)
- [Encrypting Values](#encrypting-values)
- [Integrating an existing contract](#integrating-an-existing-contract)
- [Attested Decrypt](#attested-decrypt)
- [Attested Reveal](#attested-reveal)
- [Attested Compute](#attested-compute)
- [Session Keys](#session-keys)
- [Reencryption](#reencryption)
- [Fee Payment](#fee-payment)
- [Retry Configuration](#retry-configuration)
- [Wagmi Integration Pattern](#wagmi-integration-pattern)

---

> **v1 (`@inco/lightning-js`).** The JS SDK was renamed from `@inco/js` → **`@inco/lightning-js`** at v1.0.0. Key API changes in this reference:
> - **Init:** prefer the explicit network factories `Lightning.baseSepoliaTestnet()` / `Lightning.baseMainnet()` (Inco's two live networks) over `Lightning.latest("testnet", chainId)` (which still works); `Lightning.localNode()` → `Lightning.localNode("mainnet")` (pass the network "pepper").
> - **Session keys:** `generateSecp256k1Keypair()` → **`await generateXwingKeypair()`** (now async, post-quantum X‑Wing).
> - **Attested methods:** reencryption args moved from positional into an options object `{ reencryptPubKey, reencryptKeypair }`.
> - **Backoff:** `{ maxRetries, initialDelay, maxDelay }` → `{ backoffConfig: { maxRetries, baseDelayInMs, backoffFactor } }`.
>
> Migrating an `@inco/js` project? See <https://docs.inco.org/js-sdk/migration-v1>.

## Installation

```bash
npm install @inco/lightning-js@latest
# or
yarn add @inco/lightning-js@latest
# or
bun add @inco/lightning-js@latest
```

Currently tested with Webpack and Next.js.

---

## Initialization

```typescript
import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes } from "@inco/lightning-js";

// Base Sepolia testnet (chain 84532) — explicit network factory
const zap = await Lightning.baseSepoliaTestnet();

// Base mainnet (real ETH)
const zap = await Lightning.baseMainnet();

// Optionally pass your own RPC endpoint(s) — multiple gives automatic fallback
const zap = await Lightning.baseSepoliaTestnet({
  hostChainRpcUrls: ["https://primary.rpc", "https://fallback.rpc"],
});

// Local development node (anvil + covalidator docker) — pass the network "pepper"
const zap = await Lightning.localNode("mainnet");
```

Pick the factory by chain id: `31337` → `localNode("mainnet")`, `84532` → `baseSepoliaTestnet()` (Base Sepolia), `8453` → `baseMainnet()` (Base mainnet) — Inco's two live networks.

---

## Encrypting Values

Three supported types: `euint256`, `ebool`, `euint160` (eaddress).

### euint256
```typescript
const ciphertext = await zap.encrypt(42n, {
  accountAddress: userAddress,      // Who can decrypt
  dappAddress: contractAddress,     // Which contract it's for
  handleType: handleTypes.euint256,
});
```

### ebool
```typescript
const ciphertext = await zap.encrypt(true, {
  accountAddress: userAddress,
  dappAddress: contractAddress,
  handleType: handleTypes.ebool,
});
```

### eaddress (euint160)
```typescript
const ciphertext = await zap.encrypt(BigInt(address), {
  accountAddress: userAddress,
  dappAddress: contractAddress,
  handleType: handleTypes.euint160,
});
```

The returned `ciphertext` is a `HexString` passed directly to contract functions that accept `bytes memory`.

---

## Integrating an existing contract

Building a frontend against a confidential contract you didn't deploy (a separate team's, or an already-live one)? The rules that bite:

- **`dappAddress`** = the deployed contract's address; **`accountAddress`** = your on-chain identity (must match the `msg.sender` the contract will see). The ciphertext is bound to both — a mismatch yields a handle the contract can't use.
- **You can only `attestedDecrypt` a handle the contract has `e.allow`-ed to your address.** If a decrypt fails or returns nothing, the contract likely never granted you access — that's a contract-side `e.allow(handle, you)`, not a frontend fix.
- **`handleType` must match the Solidity type** the contract stored (`euint256` / `ebool` / `euint160`); the wrong type produces a ciphertext the contract rejects.
- **Fees** still come from `zap.executorAddress` (`getFee`) — read it the same way and pay it as `msg.value` on functions that ingest ciphertext, even though you don't control the contract.
- **Public** values the contract `e.reveal`-ed are readable by anyone via `attestedReveal` — no `e.allow` and no wallet signature needed.

---

## Attested Decrypt

Decrypt a handle for an authorized user. Requires `e.allow()` on-chain for the requesting address.

```typescript
import { type HexString } from "@inco/lightning-js";

// Single handle
const results = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString]
);
const plaintext = results[0].plaintext.value;

// Multiple handles
const results = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle1>" as HexString, "0x<handle2>" as HexString]
);
```

### Result Structure
```typescript
{
  handle: "0x...",              // The handle that was decrypted
  plaintext: {
    value: bigint | boolean,    // The decrypted value
  },
  covalidatorSignatures: Uint8Array[], // Signatures for on-chain verification
}
```

### Submitting Attestation On-Chain
```typescript
const result = results[0];
const signatures = result.covalidatorSignatures.map(sig => bytesToHex(sig));
const encodedValue = pad(toHex(result.plaintext.value), { size: 32 });

await writeContract({
  address: contractAddress,
  abi: contractAbi,
  functionName: "submitDecryption",
  args: [
    { handle: result.handle, value: encodedValue },
    signatures,
  ],
});
```

---

## Attested Reveal

Decrypt handles that were made public via `e.reveal()`. No wallet signature needed - anyone can call.

```typescript
const results = await zap.attestedReveal(
  ["0x<revealed_handle>" as HexString]
);
const plaintext = results[0].plaintext.value;
```

---

## Attested Compute

Perform computation off-chain on an encrypted handle and get a signed result. Avoids unnecessary transactions.

```typescript
import { AttestedComputeSupportedOps } from "@inco/lightning-js/lite";

// creditScore >= 700 ?
const result = await zap.attestedCompute(
  walletClient,
  "0x<creditScoreHandle>" as HexString,
  AttestedComputeSupportedOps.Ge,
  700n,
);

const isEligible = result.plaintext.value; // boolean
```

### Supported Operations

| Operation | Enum | Returns |
|-----------|------|---------|
| Equal | `AttestedComputeSupportedOps.Eq` | `boolean` |
| Not equal | `AttestedComputeSupportedOps.Ne` | `boolean` |
| Greater or equal | `AttestedComputeSupportedOps.Ge` | `boolean` |
| Greater than | `AttestedComputeSupportedOps.Gt` | `boolean` |
| Less or equal | `AttestedComputeSupportedOps.Le` | `boolean` |
| Less than | `AttestedComputeSupportedOps.Lt` | `boolean` |

All are scalar binary: one handle operand + one plaintext operand.

---

## Session Keys

Decrypt without the user signing each request. Useful for background polling and popup-free per-player reads.

```typescript
import { generateXwingKeypair } from "@inco/lightning-js/lite";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

// 1. Ephemeral signing account (the "session key") + an X-Wing reencryption
//    keypair (post-quantum; generation is async in v1).
const ephemeralAccount = privateKeyToAccount(generatePrivateKey());
const reencryptKeypair = await generateXwingKeypair();
const reencryptPubKey = reencryptKeypair.encodePublicKey();

const defaultSessionVerifier = "0xc34569efc25901bdd6b652164a2c8a7228b23005";

// 2. Grant the voucher (one-time, user signs). Grantee is the session key ADDRESS.
const expiresAt = new Date(Date.now() + 3600000); // 1 hour
const voucher = await zap.grantSessionKeyAllowanceVoucher(
  walletClient,
  ephemeralAccount.address,
  expiresAt,
  defaultSessionVerifier,
);

// 3. Decrypt without a wallet signature. v1 signature: (account, voucher, handles, options?)
//    — no publicClient arg; reencryption goes in the options object.
const results = await zap.attestedDecryptWithVoucher(
  ephemeralAccount,
  voucher,
  ["0x<handle>" as HexString],
  { reencryptPubKey, reencryptKeypair },
);
const plaintext = results[0].plaintext.value;

// Revoke all outstanding vouchers (e.g. on logout):
// await zap.updateActiveVouchersSessionNonce(walletClient);
```

---

## Reencryption

Decrypt and re-encrypt for a different recipient (delegate). In v1 the reencryption keypair is post-quantum X-Wing (`generateXwingKeypair`, async) and is passed inside the options object.

```typescript
import { generateXwingKeypair } from "@inco/lightning-js/lite";

// For a delegate (they decrypt with their own private key)
const delegateKeypair = await generateXwingKeypair();
const encryptedResults = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString],
  { reencryptPubKey: delegateKeypair.encodePublicKey() }
);
const encryptedAttestation = encryptedResults[0].encryptedPlaintext;

// Reencrypt AND decrypt locally — pass both the pubkey and the keypair
const keypair = await generateXwingKeypair();
const results = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString],
  { reencryptPubKey: keypair.encodePublicKey(), reencryptKeypair: keypair }
);
const plaintext = results[0].plaintext.value;
```

---

## Fee Payment

Get the current fee from the Inco executor contract:

```typescript
const getFeeAbi = [
  {
    inputs: [],
    name: "getFee",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "pure",
    type: "function",
  },
] as const;

const fee = await publicClient.readContract({
  address: zap.executorAddress,
  abi: getFeeAbi,
  functionName: "getFee",
});

// Pass fee as msg.value
await writeContract({
  address: contractAddress,
  abi: contractAbi,
  functionName: "deposit",
  args: [ciphertext],
  value: fee, // or fee * BigInt(ciphertextCount)
});
```

---

## Retry Configuration

All decryption methods support retry config for covalidator latency. In v1 the config is nested under `backoffConfig` and the fields changed:

```typescript
const results = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString],
  {
    backoffConfig: {
      maxRetries: 12,
      baseDelayInMs: 350,   // was `initialDelay`
      backoffFactor: 1.4,   // retry multiplier; replaces `maxDelay`
    },
  }
);
```

The delay before retry `n` is `baseDelayInMs * backoffFactor^n`. Put `backoffConfig` and `reencryptPubKey`/`reencryptKeypair` in the **same** options object when you need both.

---

## Wagmi Integration Pattern

Complete hook pattern for React + wagmi:

```typescript
import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes } from "@inco/lightning-js";
import { useAccount, useWalletClient, usePublicClient, useWriteContract } from "wagmi";
import { parseEther, pad, toHex, bytesToHex } from "viem";

// Singleton Lightning instance
let zapPromise: Promise<any> | null = null;
async function getZap() {
  if (!zapPromise) {
    zapPromise = Lightning.baseSepoliaTestnet();
  }
  return zapPromise;
}

export function useMyContract() {
  const { address } = useAccount();
  const { data: walletClient } = useWalletClient();
  const publicClient = usePublicClient();
  const { writeContract } = useWriteContract();

  // Encrypt and send to contract
  const deposit = async (amount: string) => {
    const zap = await getZap();
    const ciphertext = await zap.encrypt(parseEther(amount), {
      accountAddress: address!,
      dappAddress: CONTRACT_ADDRESS,
      handleType: handleTypes.euint256,
    });

    const fee = await publicClient!.readContract({
      address: zap.executorAddress,
      abi: getFeeAbi,
      functionName: "getFee",
    });

    writeContract({
      address: CONTRACT_ADDRESS,
      abi: contractAbi,
      functionName: "deposit",
      args: [ciphertext],
      value: fee as bigint,
    });
  };

  // Decrypt with attestation
  const decryptHandle = async (handle: `0x${string}`) => {
    const zap = await getZap();
    // `handle` is ALREADY a hex string (e.g. from an event log) — pad as-is.
    // Wrapping it in toHex() re-encodes the string and throws InvalidBytesLengthError.
    const paddedHandle = pad(handle, { size: 32 });
    const results = await zap.attestedDecrypt(walletClient!, [paddedHandle]);
    return results[0];
  };

  return { deposit, decryptHandle };
}
```
