/**
 * Session Key Decryption Example
 *
 * Demonstrates using session keys for decryption without requiring
 * the user to sign each request. Useful for:
 * - Background polling of encrypted values
 * - Better UX (fewer wallet popups)
 * - Delegated decryption
 *
 * Prerequisites:
 *   npm install @inco/js viem
 */

import { Lightning, generateSecp256k1Keypair } from "@inco/js/lite";
import { supportedChains, type HexString } from "@inco/js";
import { createWalletClient, http, pad, toHex } from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// ─── Configuration ──────────────────────────────────────────

const PRIVATE_KEY = "0x..." as `0x${string}`;
const ENCRYPTED_HANDLE = "0x..." as HexString; // An encrypted handle you have access to

const DEFAULT_SESSION_VERIFIER = "0xc34569efc25901bdd6b652164a2c8a7228b23005";

// ─── Main ───────────────────────────────────────────────────

async function main() {
  const account = privateKeyToAccount(PRIVATE_KEY);
  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(),
  });

  const zap = await Lightning.latest("testnet", supportedChains.baseSepolia);

  // ─── Step 1: Generate Ephemeral Keypair ───────────────────

  const ephemeralKeypair = generateSecp256k1Keypair();
  console.log("Generated ephemeral keypair for session");

  // ─── Step 2: Grant Session Key (one-time, requires wallet signature) ─

  const expiresAt = new Date(Date.now() + 3600000); // 1 hour from now
  console.log("Granting session key (expires:", expiresAt.toISOString(), ")");

  const voucher = await zap.grantSessionKeyAllowanceVoucher(
    walletClient,
    ephemeralKeypair.encodePublicKey(),
    expiresAt,
    DEFAULT_SESSION_VERIFIER
  );
  console.log("Session key granted!");

  // ─── Step 3: Decrypt WITHOUT Wallet Signature ─────────────

  // From this point on, no wallet popup is needed
  console.log("\nDecrypting with session key (no wallet signature needed)...");

  const results = await zap.attestedDecryptWithVoucher(
    ephemeralKeypair,
    voucher,
    [ENCRYPTED_HANDLE]
  );

  console.log("Decrypted value:", results[0].plaintext.value);

  // ─── Step 4: Multiple Decryptions (no popups) ────────────

  console.log("\nDecrypting multiple handles in sequence (no popups)...");

  const handles: HexString[] = [
    ENCRYPTED_HANDLE,
    // Add more handles here
  ];

  for (const handle of handles) {
    const result = await zap.attestedDecryptWithVoucher(
      ephemeralKeypair,
      voucher,
      [handle]
    );
    console.log(`  Handle ${handle.slice(0, 10)}... = ${result[0].plaintext.value}`);
  }

  // ─── Step 5: Reencryption with Session Key ────────────────

  console.log("\nReencrypting for a delegate...");

  const delegateKeypair = generateSecp256k1Keypair();

  const encryptedResults = await zap.attestedDecryptWithVoucher(
    ephemeralKeypair,
    voucher,
    [ENCRYPTED_HANDLE],
    delegateKeypair.encodePublicKey()
  );

  console.log("Reencrypted attestation created for delegate");
  console.log("  Encrypted plaintext:", encryptedResults[0].encryptedPlaintext ? "yes" : "no");

  // The delegate would decrypt this with their private key
  // This is useful for sharing decrypted data without exposing plaintext in transit

  console.log("\nSession key flow complete!");
}

main().catch(console.error);
