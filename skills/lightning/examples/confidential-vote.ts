/**
 * Confidential Vote Example
 *
 * End-to-end flow against scripts/governance/ConfidentialBallot.sol:
 * 1. Encrypt a ballot (option index) and cast it, paying the Inco fee
 * 2. Verify your own ballot with attestedDecrypt (voter receipt)
 * 3. After the window: close(), attestedReveal the tallies (or the winner),
 *    and submit the attestations to finalize() so the result lives on-chain
 *
 * Prerequisites:
 *   npm install @inco/lightning-js@latest viem
 *   Deploy ConfidentialBallot.sol, setWeights for your voters, createProposal.
 */

import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes, type HexString } from "@inco/lightning-js";
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
const BALLOT_ADDRESS = "0x..." as Address;
const PROPOSAL_ID = 0n;
const MY_CHOICE = 1n; // option index; 0 is conventionally "against"

const BALLOT_ABI = [
  {
    inputs: [
      { name: "id", type: "uint256" },
      { name: "encryptedChoice", type: "bytes" },
    ],
    name: "castVote",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [{ name: "id", type: "uint256" }],
    name: "myBallot",
    outputs: [
      { name: "choice", type: "bytes32" },
      { name: "weight", type: "uint256" },
      { name: "cast", type: "bool" },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "id", type: "uint256" }],
    name: "getProposal",
    outputs: [
      { name: "description", type: "string" },
      { name: "optionCount", type: "uint8" },
      { name: "start", type: "uint64" },
      { name: "end", type: "uint64" },
      { name: "quorum", type: "uint256" },
      { name: "mode", type: "uint8" },
      { name: "totalWeightCast", type: "uint256" },
      { name: "voterCount", type: "uint256" },
      { name: "closed", type: "bool" },
      { name: "finalized", type: "bool" },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "id", type: "uint256" }],
    name: "close",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [{ name: "id", type: "uint256" }],
    name: "tallyHandles",
    outputs: [{ name: "", type: "bytes32[]" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ name: "id", type: "uint256" }],
    name: "winnerHandle",
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [
      { name: "id", type: "uint256" },
      {
        name: "decryptions",
        type: "tuple[]",
        components: [
          { name: "handle", type: "bytes32" },
          { name: "value", type: "bytes32" },
        ],
      },
      { name: "signatures", type: "bytes[][]" },
    ],
    name: "finalize",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [{ name: "id", type: "uint256" }],
    name: "result",
    outputs: [
      { name: "finalized", type: "bool" },
      { name: "winner", type: "uint256" },
      { name: "tallies", type: "uint256[]" },
      { name: "quorumOk", type: "bool" },
    ],
    stateMutability: "view",
    type: "function",
  },
] as const;

const GET_FEE_ABI = [
  { inputs: [], name: "getFee", outputs: [{ name: "", type: "uint256" }], stateMutability: "pure", type: "function" },
] as const;

const REVEAL_MODE_TALLIES = 0;

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

/** Shape one attestedReveal/attestedDecrypt result into finalize() calldata. */
function toAttestation(r: { handle: string; plaintext: { value: bigint | boolean }; covalidatorSignatures: Uint8Array[] }) {
  const value = typeof r.plaintext.value === "boolean" ? (r.plaintext.value ? 1n : 0n) : r.plaintext.value;
  return {
    decryption: { handle: r.handle as `0x${string}`, value: pad(toHex(value), { size: 32 }) as `0x${string}` },
    signatures: r.covalidatorSignatures.map((s) => bytesToHex(s) as `0x${string}`),
  };
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

  // ── 1. Cast a private ballot ─────────────────────────────
  // The ciphertext is bound to (voter, ballot contract); the contract ingests it
  // with newEuint256(ct, msg.sender), so accountAddress MUST be the sender.
  const ciphertext = await zap.encrypt(MY_CHOICE, {
    accountAddress: account.address,
    dappAddress: BALLOT_ADDRESS,
    handleType: handleTypes.euint256,
  });

  const castTx = await walletClient.writeContract({
    address: BALLOT_ADDRESS,
    abi: BALLOT_ABI,
    functionName: "castVote",
    args: [PROPOSAL_ID, ciphertext],
    value: fee,
  });
  await publicClient.waitForTransactionReceipt({ hash: castTx });
  console.log("Ballot cast. Tx:", castTx);
  // Note: the tx reveals THAT you voted and your public weight, never WHAT you voted.

  // ── 2. Voter receipt: decrypt your own ballot ────────────
  // Works only because the contract e.allow()-ed the choice handle to you
  // (VOTER_CAN_DECRYPT_OWN_BALLOT). Nobody else, admin included, can do this.
  const [choiceHandle] = await publicClient.readContract({
    address: BALLOT_ADDRESS,
    abi: BALLOT_ABI,
    functionName: "myBallot",
    args: [PROPOSAL_ID],
  });
  const receipt = await waitAndRetry(async () => {
    const res = await zap.attestedDecrypt(walletClient, [choiceHandle as HexString]);
    return res[0];
  });
  console.log("My ballot decrypts to option:", receipt.plaintext.value);

  // ── 3. After the window: close, reveal, finalize ────────
  const proposal = await publicClient.readContract({
    address: BALLOT_ADDRESS,
    abi: BALLOT_ABI,
    functionName: "getProposal",
    args: [PROPOSAL_ID],
  });
  const [, , , end, , mode, , , closed] = proposal;
  if (BigInt(Math.floor(Date.now() / 1000)) < end) {
    console.log("Voting still open until", new Date(Number(end) * 1000).toISOString());
    return;
  }

  if (!closed) {
    // Anyone can close; this is the moment the tallies (or the winner) become
    // publicly decryptable via e.reveal(). Before it, they are opaque to everyone.
    const closeTx = await walletClient.writeContract({
      address: BALLOT_ADDRESS,
      abi: BALLOT_ABI,
      functionName: "close",
      args: [PROPOSAL_ID],
    });
    await publicClient.waitForTransactionReceipt({ hash: closeTx });
    console.log("Proposal closed. Tx:", closeTx);
  }

  // Which handles to reveal depends on the proposal's reveal mode.
  const handles: HexString[] =
    mode === REVEAL_MODE_TALLIES
      ? ((await publicClient.readContract({
          address: BALLOT_ADDRESS,
          abi: BALLOT_ABI,
          functionName: "tallyHandles",
          args: [PROPOSAL_ID],
        })) as readonly `0x${string}`[]).map((h) => h as HexString)
      : [
          (await publicClient.readContract({
            address: BALLOT_ADDRESS,
            abi: BALLOT_ABI,
            functionName: "winnerHandle",
            args: [PROPOSAL_ID],
          })) as HexString,
        ];

  // attestedReveal needs no wallet: the handles were e.reveal()-ed on-chain.
  const revealed = await waitAndRetry(() => zap.attestedReveal(handles));
  revealed.forEach((r, i) => console.log(`  handle ${i}: ${r.plaintext.value}`));

  // finalize() expects the attestations in option order (Tallies mode) or a
  // single one for the winner handle. It re-checks every handle on-chain, so
  // a reordered or foreign attestation is rejected with HandleMismatch.
  const packed = revealed.map(toAttestation);
  const finalizeTx = await walletClient.writeContract({
    address: BALLOT_ADDRESS,
    abi: BALLOT_ABI,
    functionName: "finalize",
    args: [PROPOSAL_ID, packed.map((p) => p.decryption), packed.map((p) => p.signatures)],
  });
  await publicClient.waitForTransactionReceipt({ hash: finalizeTx });

  const [finalized, winner, tallies, quorumOk] = await publicClient.readContract({
    address: BALLOT_ADDRESS,
    abi: BALLOT_ABI,
    functionName: "result",
    args: [PROPOSAL_ID],
  });
  console.log({ finalized, winner, tallies, quorumOk });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
