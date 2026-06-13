/**
 * Basic Encrypt & Decrypt Example
 *
 * Demonstrates the core Inco flow:
 * 1. Initialize Lightning SDK
 * 2. Encrypt a value client-side
 * 3. Send encrypted value to a contract
 * 4. Read an encrypted handle from a contract
 * 5. Decrypt with attestation
 *
 * Prerequisites:
 *   npm install @inco/lightning-js@latest viem
 */

import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes, type HexString } from "@inco/lightning-js";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  pad,
  toHex,
  type Address,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// ─── Configuration ──────────────────────────────────────────

const PRIVATE_KEY = "0x..." as `0x${string}`; // Your private key
const CONTRACT_ADDRESS = "0x..." as Address;   // Your deployed contract

const CONTRACT_ABI = [
  {
    inputs: [{ name: "encryptedAmount", type: "bytes" }],
    name: "deposit",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [{ name: "account", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }], // Returns euint256 handle
    stateMutability: "view",
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

// ─── Main ───────────────────────────────────────────────────

async function main() {
  // 1. Initialize clients
  const account = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(),
  });

  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(),
  });

  // 2. Initialize Inco Lightning SDK (Base Sepolia network factory)
  const zap = await Lightning.baseSepoliaTestnet();
  console.log("Lightning SDK initialized");
  console.log("Executor address:", zap.executorAddress);

  // 3. Get the current fee
  const fee = (await publicClient.readContract({
    address: zap.executorAddress as Address,
    abi: GET_FEE_ABI,
    functionName: "getFee",
  })) as bigint;
  console.log("Current fee:", fee, "wei");

  // 4. Encrypt a value
  const amount = parseEther("0.001"); // Amount to deposit
  const ciphertext = await zap.encrypt(amount, {
    accountAddress: account.address,
    dappAddress: CONTRACT_ADDRESS,
    handleType: handleTypes.euint256,
  });
  console.log("Encrypted ciphertext:", ciphertext.slice(0, 20) + "...");

  // 5. Send encrypted value to contract
  const depositTxHash = await walletClient.writeContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "deposit",
    args: [ciphertext],
    value: fee, // Pay the Inco fee
  });
  console.log("Deposit tx:", depositTxHash);

  // Wait for confirmation
  await publicClient.waitForTransactionReceipt({ hash: depositTxHash });
  console.log("Deposit confirmed");

  // 6. Read encrypted handle from contract
  const balanceHandle = await publicClient.readContract({
    address: CONTRACT_ADDRESS,
    abi: CONTRACT_ABI,
    functionName: "balanceOf",
    args: [account.address],
  });
  console.log("Balance handle (encrypted):", balanceHandle);

  // 7. Decrypt with attestation
  // Note: The contract must have called e.allow(balance, userAddress)
  const handleHex = pad(toHex(balanceHandle), { size: 32 }) as HexString;

  console.log("Requesting decryption (may take a few seconds for covalidator)...");

  // The covalidator processes asynchronously — use the SDK's built-in backoff
  // rather than a hand-rolled retry loop.
  const results = await zap.attestedDecrypt(walletClient, [handleHex], {
    backoffConfig: { maxRetries: 12, baseDelayInMs: 350, backoffFactor: 1.4 },
  });
  const plaintext = results[0].plaintext.value as bigint;
  console.log("Decrypted balance:", plaintext.toString());
}

main().catch(console.error);
