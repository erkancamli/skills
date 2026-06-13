/**
 * Attestation Flow Example
 *
 * Demonstrates all three Inco attestation patterns:
 * 1. Attested Decrypt - authorized user decrypts their data
 * 2. Attested Reveal - anyone decrypts publicly revealed data
 * 3. Attested Compute - off-chain computation with on-chain proof
 *
 * Prerequisites:
 *   npm install @inco/lightning-js@latest viem
 *   Deploy ConfidentialWithAttestation.sol first
 */

import { Lightning } from "@inco/lightning-js/lite";
import {
  handleTypes,
  type HexString,
} from "@inco/lightning-js";
import { AttestedComputeSupportedOps } from "@inco/lightning-js/lite";
import {
  createPublicClient,
  createWalletClient,
  http,
  pad,
  toHex,
  bytesToHex,
  type Address,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// ─── Configuration ──────────────────────────────────────────

const PRIVATE_KEY = "0x..." as `0x${string}`;
const CONTRACT_ADDRESS = "0x..." as Address;

const CONTRACT_ABI = [
  // setScore
  {
    inputs: [{ name: "encryptedScore", type: "bytes" }],
    name: "setScore",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  // getMyScore
  {
    inputs: [],
    name: "getMyScore",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  // revealedRandom
  {
    inputs: [],
    name: "revealedRandom",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  // decryptedRandom
  {
    inputs: [],
    name: "decryptedRandom",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  // submitMyScore (attested decrypt)
  {
    inputs: [
      {
        components: [
          { name: "handle", type: "bytes32" },
          { name: "value", type: "bytes32" },
        ],
        name: "decryption",
        type: "tuple",
      },
      { name: "signatures", type: "bytes[]" },
    ],
    name: "submitMyScore",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  // submitRevealedRandom (attested reveal)
  {
    inputs: [
      {
        components: [
          { name: "handle", type: "bytes32" },
          { name: "value", type: "bytes32" },
        ],
        name: "decryption",
        type: "tuple",
      },
      { name: "signatures", type: "bytes[]" },
    ],
    name: "submitRevealedRandom",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  // submitScoreCheck (attested compute)
  {
    inputs: [
      { name: "threshold", type: "uint256" },
      {
        components: [
          { name: "handle", type: "bytes32" },
          { name: "value", type: "bytes32" },
        ],
        name: "decryption",
        type: "tuple",
      },
      { name: "signatures", type: "bytes[]" },
    ],
    name: "submitScoreCheck",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

const GET_FEE_ABI = [
  {
    inputs: [],
    name: "getFee",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "pure",
    type: "function",
  },
] as const;

// ─── Helpers ────────────────────────────────────────────────

async function waitAndRetry<T>(fn: () => Promise<T>, retries = 10, delayMs = 3000): Promise<T> {
  for (let i = 0; i < retries; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i === retries - 1) throw e;
      console.log(`  Retry ${i + 1}/${retries}...`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw new Error("unreachable");
}

// ─── Main ───────────────────────────────────────────────────

async function main() {
  const account = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http() });
  const walletClient = createWalletClient({ account, chain: baseSepolia, transport: http() });

  const zap = await Lightning.baseSepoliaTestnet();
  const fee = (await publicClient.readContract({
    address: zap.executorAddress as Address,
    abi: GET_FEE_ABI,
    functionName: "getFee",
  })) as bigint;

  // ─── Setup: Set a score ───────────────────────────────────

  console.log("Setting encrypted score (800)...");
  const scoreCt = await zap.encrypt(800n, {
    accountAddress: account.address,
    dappAddress: CONTRACT_ADDRESS,
    handleType: handleTypes.euint256,
  });

  const setTx = await walletClient.writeContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "setScore",
    args: [scoreCt],
    value: fee,
  });
  await publicClient.waitForTransactionReceipt({ hash: setTx });
  console.log("Score set. Tx:", setTx);

  // ═══════════════════════════════════════════════════════════
  // Pattern 1: ATTESTED DECRYPT
  // User decrypts their own score and submits proof on-chain
  // ═══════════════════════════════════════════════════════════

  console.log("\n--- Pattern 1: Attested Decrypt ---");

  // Read the encrypted handle
  const scoreHandle = await publicClient.readContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "getMyScore",
    account: account.address,
  });
  const scoreHandleHex = pad(toHex(scoreHandle), { size: 32 }) as HexString;
  console.log("Score handle:", scoreHandleHex.slice(0, 20) + "...");

  // Decrypt with attestation (includes covalidator signatures)
  const decryptResult = await waitAndRetry(async () => {
    const results = await zap.attestedDecrypt(walletClient, [scoreHandleHex]);
    return results[0];
  });

  console.log("Decrypted score:", decryptResult.plaintext.value);

  // Format for on-chain submission
  const signatures = decryptResult.covalidatorSignatures.map(
    (sig: Uint8Array) => bytesToHex(sig) as `0x${string}`
  );
  const encodedValue = pad(toHex(decryptResult.plaintext.value as bigint), {
    size: 32,
  }) as `0x${string}`;

  // Submit attestation on-chain
  const submitTx = await walletClient.writeContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "submitMyScore",
    args: [
      { handle: decryptResult.handle as `0x${string}`, value: encodedValue },
      signatures,
    ],
  });
  await publicClient.waitForTransactionReceipt({ hash: submitTx });
  console.log("Attestation submitted on-chain. Tx:", submitTx);

  // ═══════════════════════════════════════════════════════════
  // Pattern 2: ATTESTED REVEAL
  // Anyone can decrypt publicly revealed data
  // ═══════════════════════════════════════════════════════════

  console.log("\n--- Pattern 2: Attested Reveal ---");

  // Read the revealed random number handle
  const randomHandle = await publicClient.readContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "revealedRandom",
  });
  const randomHandleHex = pad(toHex(randomHandle), { size: 32 }) as HexString;
  console.log("Revealed random handle:", randomHandleHex.slice(0, 20) + "...");

  // Anyone can call attestedReveal (no wallet signature needed for the data itself)
  const revealResult = await waitAndRetry(async () => {
    const results = await zap.attestedReveal([randomHandleHex]);
    return results[0];
  });

  console.log("Revealed random number:", revealResult.plaintext.value);

  // Submit on-chain
  const revealSigs = revealResult.covalidatorSignatures.map(
    (sig: Uint8Array) => bytesToHex(sig) as `0x${string}`
  );
  const revealValue = pad(toHex(revealResult.plaintext.value as bigint), {
    size: 32,
  }) as `0x${string}`;

  const revealTx = await walletClient.writeContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "submitRevealedRandom",
    args: [
      { handle: revealResult.handle as `0x${string}`, value: revealValue },
      revealSigs,
    ],
  });
  await publicClient.waitForTransactionReceipt({ hash: revealTx });
  console.log("Reveal submitted on-chain. Tx:", revealTx);

  // Verify it was stored
  const stored = await publicClient.readContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "decryptedRandom",
  });
  console.log("Stored decrypted random:", stored);

  // ═══════════════════════════════════════════════════════════
  // Pattern 3: ATTESTED COMPUTE
  // Off-chain: check if score >= 700, submit proof on-chain
  // ═══════════════════════════════════════════════════════════

  console.log("\n--- Pattern 3: Attested Compute ---");

  const threshold = 700n;

  // Compute off-chain: score >= 700?
  const computeResult = await waitAndRetry(async () => {
    return await zap.attestedCompute(
      walletClient,
      scoreHandleHex,
      AttestedComputeSupportedOps.Ge,
      threshold
    );
  });

  console.log(`Score >= ${threshold}?`, computeResult.plaintext.value); // true

  // Submit the compute attestation on-chain
  const computeSigs = computeResult.covalidatorSignatures.map(
    (sig: Uint8Array) => bytesToHex(sig) as `0x${string}`
  );
  const computeValue = pad(
    toHex(computeResult.plaintext.value ? 1 : 0),
    { size: 32 }
  ) as `0x${string}`;

  const computeTx = await walletClient.writeContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "submitScoreCheck",
    args: [
      threshold,
      { handle: computeResult.handle as `0x${string}`, value: computeValue },
      computeSigs,
    ],
  });
  await publicClient.waitForTransactionReceipt({ hash: computeTx });
  console.log("Compute attestation verified on-chain. Tx:", computeTx);

  console.log("\nAll three attestation patterns demonstrated successfully!");
}

main().catch(console.error);
