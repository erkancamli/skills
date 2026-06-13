/**
 * Confidential Token Interaction Example
 *
 * Demonstrates working with a deployed ConfidentialToken contract:
 * 1. Encrypted minting
 * 2. Encrypted transfer
 * 3. Encrypted approve + transferFrom
 * 4. Balance decryption
 *
 * Prerequisites:
 *   npm install @inco/lightning-js@latest viem
 *   Deploy ConfidentialToken.sol first
 */

import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes, type HexString } from "@inco/lightning-js";
import {
  createPublicClient,
  createWalletClient,
  http,
  pad,
  toHex,
  type Address,
} from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// ─── Configuration ──────────────────────────────────────────

const PRIVATE_KEY_ALICE = "0x..." as `0x${string}`;
const PRIVATE_KEY_BOB = "0x..." as `0x${string}`;
const TOKEN_ADDRESS = "0x..." as Address;

// Confidential tokens use 9 decimals (GWEI, not WAD)
const GWEI = 10n ** 9n;

const TOKEN_ABI = [
  {
    inputs: [{ name: "encryptedAmount", type: "bytes" }],
    name: "encryptedMint",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { name: "to", type: "address" },
      { name: "valueInput", type: "bytes" },
    ],
    name: "transfer",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { name: "spender", type: "address" },
      { name: "valueInput", type: "bytes" },
    ],
    name: "approve",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "valueInput", type: "bytes" },
    ],
    name: "transferFrom",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [{ name: "", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }],
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

// ─── Helpers ────────────────────────────────────────────────

let zap: Awaited<ReturnType<typeof Lightning.baseSepoliaTestnet>>;
let publicClient: ReturnType<typeof createPublicClient>;

async function getFee(): Promise<bigint> {
  return (await publicClient.readContract({
    address: zap.executorAddress as Address,
    abi: GET_FEE_ABI,
    functionName: "getFee",
  })) as bigint;
}

async function encrypt(amount: bigint, userAddress: Address): Promise<HexString> {
  return await zap.encrypt(amount, {
    accountAddress: userAddress,
    dappAddress: TOKEN_ADDRESS,
    handleType: handleTypes.euint256,
  });
}

async function decryptBalance(
  walletClient: ReturnType<typeof createWalletClient>,
  userAddress: Address
): Promise<bigint | null> {
  const handle = await publicClient.readContract({
    address: TOKEN_ADDRESS,
    abi: TOKEN_ABI,
    functionName: "balanceOf",
    args: [userAddress],
  });

  if (handle === 0n) {
    console.log("  No balance handle (0x0)");
    return null;
  }

  const handleHex = pad(toHex(handle), { size: 32 }) as HexString;

  // Built-in backoff handles covalidator latency — no hand-rolled loop.
  const results = await zap.attestedDecrypt(walletClient as any, [handleHex], {
    backoffConfig: { maxRetries: 12, baseDelayInMs: 350, backoffFactor: 1.4 },
  });
  return results[0].plaintext.value as bigint;
}

// ─── Main ───────────────────────────────────────────────────

async function main() {
  // Setup
  const alice = privateKeyToAccount(PRIVATE_KEY_ALICE);
  const bob = privateKeyToAccount(PRIVATE_KEY_BOB);

  publicClient = createPublicClient({ chain: baseSepolia, transport: http() });

  const aliceWallet = createWalletClient({
    account: alice,
    chain: baseSepolia,
    transport: http(),
  });

  const bobWallet = createWalletClient({
    account: bob,
    chain: baseSepolia,
    transport: http(),
  });

  zap = await Lightning.baseSepoliaTestnet();
  const fee = await getFee();

  // ─── 1. Encrypted Mint ────────────────────────────────────

  console.log("\n1. Minting 100 tokens to Alice...");
  const mintAmount = 100n * GWEI;
  const mintCt = await encrypt(mintAmount, alice.address);

  const mintTx = await aliceWallet.writeContract({
    address: TOKEN_ADDRESS,
    abi: TOKEN_ABI,
    functionName: "encryptedMint",
    args: [mintCt],
    value: fee,
  });
  await publicClient.waitForTransactionReceipt({ hash: mintTx });
  console.log("  Mint tx:", mintTx);

  // ─── 2. Check Alice's balance ─────────────────────────────

  console.log("\n2. Decrypting Alice's balance...");
  const aliceBalance = await decryptBalance(aliceWallet, alice.address);
  console.log("  Alice balance:", aliceBalance ? `${aliceBalance / GWEI} tokens` : "unknown");

  // ─── 3. Encrypted Transfer ────────────────────────────────

  console.log("\n3. Transferring 25 tokens from Alice to Bob...");
  const transferAmount = 25n * GWEI;
  const transferCt = await encrypt(transferAmount, alice.address);

  const transferTx = await aliceWallet.writeContract({
    address: TOKEN_ADDRESS,
    abi: TOKEN_ABI,
    functionName: "transfer",
    args: [bob.address, transferCt],
    value: fee,
  });
  await publicClient.waitForTransactionReceipt({ hash: transferTx });
  console.log("  Transfer tx:", transferTx);

  // ─── 4. Check both balances ───────────────────────────────

  console.log("\n4. Decrypting balances after transfer...");
  const aliceAfter = await decryptBalance(aliceWallet, alice.address);
  const bobAfter = await decryptBalance(bobWallet, bob.address);
  console.log("  Alice:", aliceAfter ? `${aliceAfter / GWEI} tokens` : "unknown");
  console.log("  Bob:", bobAfter ? `${bobAfter / GWEI} tokens` : "unknown");

  // ─── 5. Approve + TransferFrom ────────────────────────────

  console.log("\n5. Alice approves Bob for 10 tokens, Bob does transferFrom...");
  const approveAmount = 10n * GWEI;
  const approveCt = await encrypt(approveAmount, alice.address);

  const approveTx = await aliceWallet.writeContract({
    address: TOKEN_ADDRESS,
    abi: TOKEN_ABI,
    functionName: "approve",
    args: [bob.address, approveCt],
    value: fee,
  });
  await publicClient.waitForTransactionReceipt({ hash: approveTx });
  console.log("  Approve tx:", approveTx);

  // Bob transfers 10 tokens from Alice to himself
  const tfFromCt = await encrypt(10n * GWEI, bob.address);
  const tfFromTx = await bobWallet.writeContract({
    address: TOKEN_ADDRESS,
    abi: TOKEN_ABI,
    functionName: "transferFrom",
    args: [alice.address, bob.address, tfFromCt],
    value: fee,
  });
  await publicClient.waitForTransactionReceipt({ hash: tfFromTx });
  console.log("  TransferFrom tx:", tfFromTx);

  // ─── 6. Final balances ────────────────────────────────────

  console.log("\n6. Final balances...");
  const aliceFinal = await decryptBalance(aliceWallet, alice.address);
  const bobFinal = await decryptBalance(bobWallet, bob.address);
  console.log("  Alice:", aliceFinal ? `${aliceFinal / GWEI} tokens` : "unknown");
  console.log("  Bob:", bobFinal ? `${bobFinal / GWEI} tokens` : "unknown");
}

main().catch(console.error);
