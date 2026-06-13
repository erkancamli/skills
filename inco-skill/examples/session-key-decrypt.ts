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
 *   npm install @inco/lightning-js@latest viem
 */

import { Lightning, generateXwingKeypair } from "@inco/lightning-js/lite";
import { type HexString } from "@inco/lightning-js";
import { createWalletClient, http } from "viem";
import { baseSepolia } from "viem/chains";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

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

  const zap = await Lightning.baseSepoliaTestnet();

  // ─── Step 1: Create an Ephemeral Session Account ──────────

  // The session key is a throwaway signing account. The voucher (Step 2)
  // authorizes it to decrypt the user's handles until expiry — no wallet
  // popup per read.
  const ephemeralAccount = privateKeyToAccount(generatePrivateKey());
  console.log("Created ephemeral session account:", ephemeralAccount.address);

  // ─── Step 2: Grant Session Key (one-time, requires wallet signature) ─

  const expiresAt = new Date(Date.now() + 3600000); // 1 hour from now
  console.log("Granting session key (expires:", expiresAt.toISOString(), ")");

  const voucher = await zap.grantSessionKeyAllowanceVoucher(
    walletClient,
    ephemeralAccount.address,
    expiresAt,
    DEFAULT_SESSION_VERIFIER
  );
  console.log("Session key granted!");

  // ─── Step 3: Decrypt WITHOUT Wallet Signature ─────────────

  // From this point on, no wallet popup is needed
  console.log("\nDecrypting with session key (no wallet signature needed)...");

  // v1 signature: (account, voucher, handles, options?) — no publicClient arg.
  const results = await zap.attestedDecryptWithVoucher(
    ephemeralAccount,
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
      ephemeralAccount,
      voucher,
      [handle]
    );
    console.log(`  Handle ${handle.slice(0, 10)}... = ${result[0].plaintext.value}`);
  }

  // ─── Step 5: Reencryption with Session Key ────────────────

  console.log("\nReencrypting for a delegate...");

  // Post-quantum X-Wing keypair for the delegate (generation is async in v1).
  const delegateKeypair = await generateXwingKeypair();

  const encryptedResults = await zap.attestedDecryptWithVoucher(
    ephemeralAccount,
    voucher,
    [ENCRYPTED_HANDLE],
    { reencryptPubKey: delegateKeypair.encodePublicKey() }
  );

  console.log("Reencrypted attestation created for delegate");
  console.log("  Encrypted plaintext:", encryptedResults[0].encryptedPlaintext ? "yes" : "no");

  // The delegate would decrypt this with their private key
  // This is useful for sharing decrypted data without exposing plaintext in transit

  console.log("\nSession key flow complete!");
}

main().catch(console.error);
