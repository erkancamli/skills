# Inco JavaScript SDK Reference

## Table of Contents
- [Installation](#installation)
- [Initialization](#initialization)
- [Encrypting Values](#encrypting-values)
- [Attested Decrypt](#attested-decrypt)
- [Attested Reveal](#attested-reveal)
- [Attested Compute](#attested-compute)
- [Session Keys](#session-keys)
- [Reencryption](#reencryption)
- [Fee Payment](#fee-payment)
- [Retry Configuration](#retry-configuration)
- [Wagmi Integration Pattern](#wagmi-integration-pattern)

---

## Installation

```bash
npm install @inco/js
# or
yarn add @inco/js
# or
bun add @inco/js
```

Currently tested with Webpack and Next.js.

---

## Initialization

```typescript
import { Lightning } from "@inco/js/lite";
import { handleTypes, getViemChain, supportedChains } from "@inco/js";

// Testnet (Base Sepolia)
const zap = await Lightning.latest("testnet", supportedChains.baseSepolia);
// or with chain ID directly:
const zap = await Lightning.latest("testnet", 84532);

// Local development node
const zap = await Lightning.localNode();
```

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

## Attested Decrypt

Decrypt a handle for an authorized user. Requires `e.allow()` on-chain for the requesting address.

```typescript
import { type HexString } from "@inco/js";

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
import { AttestedComputeSupportedOps } from "@inco/js/lite";

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

Decrypt without user signing each request. Useful for background polling.

```typescript
import { generateSecp256k1Keypair } from "@inco/js/lite";

// 1. Generate ephemeral keypair
const ephemeralKeypair = generateSecp256k1Keypair();
const defaultSessionVerifier = "0xc34569efc25901bdd6b652164a2c8a7228b23005";

// 2. Grant session key (one-time, user signs)
const expiresAt = new Date(Date.now() + 3600000); // 1 hour
const voucher = await zap.grantSessionKeyAllowanceVoucher(
  walletClient,
  ephemeralKeypair.encodePublicKey(),
  expiresAt,
  defaultSessionVerifier,
);

// 3. Decrypt without wallet signature
const results = await zap.attestedDecryptWithVoucher(
  ephemeralKeypair,
  voucher,
  publicClient,               // viem PublicClient (or WalletClient) — REQUIRED 3rd arg
  ["0x<handle>" as HexString]
);
```

---

## Reencryption

Decrypt and re-encrypt for a different recipient (delegate).

```typescript
import { generateSecp256k1Keypair } from "@inco/js/lite";

// For delegate (they decrypt with their private key)
const delegateKeypair = generateSecp256k1Keypair();
const encryptedResults = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString],
  delegateKeypair.encodePublicKey()
);
const encryptedAttestation = encryptedResults[0].encryptedPlaintext;

// Reencrypt and decrypt locally
const keypair = generateSecp256k1Keypair();
const results = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString],
  keypair.encodePublicKey(),
  keypair  // auto-decrypts locally
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
    stateMutability: "view",
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

All decryption methods support retry config for covalidator latency:

```typescript
const backoffConfig = {
  maxRetries: 5,
  initialDelay: 1000,
  maxDelay: 10000,
};

const results = await zap.attestedDecrypt(
  walletClient,
  ["0x<handle>" as HexString],
  backoffConfig
);
```

---

## Wagmi Integration Pattern

Complete hook pattern for React + wagmi:

```typescript
import { Lightning } from "@inco/js/lite";
import { handleTypes } from "@inco/js";
import { useAccount, useWalletClient, usePublicClient, useWriteContract } from "wagmi";
import { parseEther, pad, toHex, bytesToHex } from "viem";

// Singleton Lightning instance
let zapPromise: Promise<any> | null = null;
async function getZap() {
  if (!zapPromise) {
    zapPromise = Lightning.latest("testnet", 84532);
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
    const paddedHandle = pad(toHex(handle), { size: 32 });
    const results = await zap.attestedDecrypt(walletClient!, [paddedHandle]);
    return results[0];
  };

  return { deposit, decryptHandle };
}
```
