/**
 * Inco Lightning SDK Helper Utilities
 *
 * Drop-in utility for frontend projects integrating with Inco confidential contracts.
 * Provides: encryption, decryption with retry, fee fetching, and attestation formatting.
 *
 * Dependencies: @inco/js, viem
 *
 * Usage:
 *   import { initInco, encryptValue, decryptValue, getFee, formatAttestation } from "./incoHelper";
 *   const zap = await initInco("testnet");
 *   const ciphertext = await encryptValue(zap, { value: 100n, ... });
 */

import { Lightning } from "@inco/js/lite";
import { handleTypes, type HexString } from "@inco/js";
import { type PublicClient, type WalletClient, pad, toHex, bytesToHex } from "viem";

// ─── Types ──────────────────────────────────────────────────

export type IncoInstance = Awaited<ReturnType<typeof Lightning.latest>>;

export interface EncryptParams {
  value: bigint | boolean;
  accountAddress: `0x${string}`;
  dappAddress: `0x${string}`;
  handleType: "euint256" | "ebool" | "eaddress";
}

export interface DecryptResult {
  handle: HexString;
  value: bigint | boolean;
  signatures: `0x${string}`[];
  attestation: { handle: HexString; value: `0x${string}` };
}

// ─── Initialization ─────────────────────────────────────────

/** Initialize Lightning SDK. Call once at app startup. */
export async function initInco(
  mode: "testnet" | "local",
  chainId: number = 84532
): Promise<IncoInstance> {
  if (mode === "local") {
    return await Lightning.localNode();
  }
  return await Lightning.latest("testnet", chainId);
}

// Singleton pattern for React hooks
let _zapPromise: Promise<IncoInstance> | null = null;

export function getZapSingleton(
  mode: "testnet" | "local" = "testnet",
  chainId: number = 84532
): Promise<IncoInstance> {
  if (!_zapPromise) {
    _zapPromise = initInco(mode, chainId);
  }
  return _zapPromise;
}

// ─── Encryption ─────────────────────────────────────────────

const HANDLE_TYPE_MAP = {
  euint256: handleTypes.euint256,
  ebool: handleTypes.ebool,
  eaddress: handleTypes.euint160,
} as const;

/** Encrypt a value for sending to a confidential contract. */
export async function encryptValue(
  zap: IncoInstance,
  params: EncryptParams
): Promise<HexString> {
  const inputValue =
    params.handleType === "eaddress"
      ? BigInt(params.value as bigint)
      : params.value;

  return await zap.encrypt(inputValue, {
    accountAddress: params.accountAddress,
    dappAddress: params.dappAddress,
    handleType: HANDLE_TYPE_MAP[params.handleType],
  });
}

// ─── Fee ────────────────────────────────────────────────────

const GET_FEE_ABI = [
  {
    inputs: [],
    name: "getFee",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
] as const;

/** Get current Inco executor fee. Multiply by ciphertext count if needed. */
export async function getFee(
  zap: IncoInstance,
  publicClient: PublicClient
): Promise<bigint> {
  return (await publicClient.readContract({
    address: zap.executorAddress as `0x${string}`,
    abi: GET_FEE_ABI,
    functionName: "getFee",
  })) as bigint;
}

// ─── Decryption ─────────────────────────────────────────────

/** Decrypt a handle with retry logic for covalidator latency. */
export async function decryptValue(
  zap: IncoInstance,
  walletClient: WalletClient,
  handles: HexString[],
  maxRetries: number = 10,
  retryDelayMs: number = 3000
): Promise<DecryptResult[]> {
  let lastError: Error | undefined;

  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const results = await zap.attestedDecrypt(walletClient, handles);

      return results.map((r: any) => ({
        handle: r.handle,
        value: r.plaintext.value,
        signatures: r.covalidatorSignatures.map((sig: Uint8Array) =>
          bytesToHex(sig)
        ),
        attestation: {
          handle: r.handle,
          value: pad(
            toHex(
              typeof r.plaintext.value === "boolean"
                ? r.plaintext.value
                  ? 1
                  : 0
                : r.plaintext.value
            ),
            { size: 32 }
          ),
        },
      }));
    } catch (e: any) {
      lastError = e;
      if (attempt < maxRetries - 1) {
        await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
      }
    }
  }

  throw lastError ?? new Error("Decryption failed after retries");
}

/** Decrypt publicly revealed handles (no wallet signature needed). */
export async function revealValue(
  zap: IncoInstance,
  handles: HexString[]
): Promise<DecryptResult[]> {
  const results = await zap.attestedReveal(handles);

  return results.map((r: any) => ({
    handle: r.handle,
    value: r.plaintext.value,
    signatures: r.covalidatorSignatures.map((sig: Uint8Array) =>
      bytesToHex(sig)
    ),
    attestation: {
      handle: r.handle,
      value: pad(toHex(r.plaintext.value), { size: 32 }),
    },
  }));
}

// ─── Attestation Formatting ─────────────────────────────────

/** Format a DecryptResult for submitting to a contract's attestation verification. */
export function formatAttestation(result: DecryptResult): {
  decryption: { handle: HexString; value: `0x${string}` };
  signatures: `0x${string}`[];
} {
  return {
    decryption: result.attestation,
    signatures: result.signatures,
  };
}
