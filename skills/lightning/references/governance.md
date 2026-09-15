# Confidential Governance on Inco Lightning

> The governance hub of this skill. Start here when building private voting for a DAO, a token holder vote, a council election, a grants round, or any "collect sealed choices, publish a result" flow. It decides WHAT stays private and WHEN it reveals, then maps that onto Inco primitives. The base API is on the [main skill page](../SKILL.md).

## Why public voting is broken (and what Inco fixes)

On a transparent chain every ballot is public the moment it lands. Three things follow, and every DAO has lived through all of them:

1. **Bandwagon and herding.** A running tally is visible mid-vote, so late voters vote with the leader (or abstain because "it's decided"). Turnout and outcome both distort.
2. **Vote buying and coercion are verifiable.** A briber can check on-chain that you voted as paid. A whale can see exactly who voted against them.
3. **Minorities are exposed.** "These 14 addresses voted against the treasury spend" is a permanent, queryable record.

With Inco the ballot is an encrypted handle, the tally is an encrypted handle that only the contract can add to, and nothing about either is readable until the vote closes. Weights (how much each address counts) can stay public without hurting any of the three properties above.

**Honesty note (repeat of the main page): Inco is TEE-based, not FHE.** "Encrypted" means the plaintext exists inside the covalidator TEE. The privacy claim is "no on-chain observer, no admin, no other voter can read a ballot or tally"; it is not a cryptographic guarantee against the TEE operator. Say this when someone asks "is it like zk voting?"

## Design before code: the three questions

Do NOT write Solidity before answering these. Each answer changes the contract.

### 1. What is secret?

| Piece of state | Default in the reference | Options |
|---|---|---|
| Ballot direction (which option) | **Secret**, forever (except the voter's own receipt) | Always secret; this is the point |
| Voting weight per address | **Public** (snapshot) | Public (ERC20Votes / NFT / allowlist) or confidential (see [Confidential weight](#confidential-weight-extension)) |
| Running tally during the vote | **Secret from everyone**, admin included | Never make this readable; it re-enables bandwagon voting |
| Final tallies | Revealed at close (`Tallies` mode) | Or never: `WinnerOnly` mode reveals only the winning index |
| Who voted and when | **Public** (tx + `VoteCast` event) | Hiding the voter set needs relayers or a session key path; see [What stays public](#what-stays-public) |
| Quorum | **Public** arithmetic on public weights | With confidential weights it becomes an encrypted compare that you reveal as an `ebool` |

"Public weight, private direction" is the default because it is what almost every DAO needs: eligibility and voting power are already public in their token, and the sensitive part is only how each address voted.

### 2. When does it reveal?

- **Never during the window.** No view function returns anything decryptable about the tally before `close()`. The reference stores tallies with `allowThis()` only; there is no `allow(admin)` anywhere.
- **At close, exactly one of:** all tallies (`e.reveal` on each handle) or the winner index only (`e.reveal` on a select-chain running max). Pick this per proposal, at creation, because it cannot be changed after votes exist without breaking the promise voters were given.
- **Reveal is irreversible.** `e.reveal` makes the handle publicly decryptable forever. That is exactly right for a final result and exactly wrong for anything mid-vote.

### 3. Who needs proof on-chain?

If a timelock, treasury, or another contract acts on the result, the plaintext must come back on-chain **with an attestation** and the contract must **bind each attestation to the handle it expects** (`decryption.handle == euint256.unwrap(tallies[i])`). Signature validity alone is not enough: a valid attestation for the wrong handle (a different proposal, a different option) must be rejected. The reference does this in `finalize()` and the tests cover the swapped-attestation case.

If only humans read the result (a signal vote), `attestedReveal` in the frontend is enough and `finalize()` is optional.

## The mechanics, mapped to Inco primitives

| Step | Primitive | Why |
|---|---|---|
| Ballot ingestion | `bytes.newEuint256(msg.sender)` + `inco.getFee()` | The ciphertext is bound to the voter; the fee is per ciphertext |
| Validity | No check at all: an out-of-range choice matches no option in the tally loop | Never `require` on an encrypted condition; an invalid ballot silently counts zero, so the tx itself leaks nothing |
| Per-option tally | `choice.eq(i).select(weight, 0)` then `tally.add(...)`, for every option | Every option is touched on every vote, so the gas and the trace are the same whatever the choice |
| Vote change | Re-run the same loop with `sub` on the previous ballot, then `add` on the new one | Needs the old choice handle: keep `allowThis()` on it |
| Access | `tally.allowThis()` after every update; `choice.allow(voter)` only if you want receipts | Missing `allowThis` = the contract can never add to that tally again |
| Winner without decrypting | `better = tallies[i].gt(best); best = better.select(tallies[i], best); idx = better.select(i, idx)` | A running max entirely under encryption; only `idx` is revealed |
| Publish | `e.reveal(handle)` at close, `attestedReveal` off-chain, `finalize(attestations)` on-chain | Reveal makes the handle public; the attestation makes the plaintext trustworthy on-chain |

### Gas and options count

The tally loop is O(options) encrypted ops per vote (an `eq`, a `select`, an `add`, an `allow` each). The reference caps options at 8. For ranked-choice or many-candidate elections, pack choices or run one proposal per seat rather than growing the loop.

### Fee model

Each ballot ingests one ciphertext, so the voter pays `inco.getFee()` (`payable` + `require`). For a gasless-for-fees UX, pre-fund the contract and drop the `require` (see [Fee Payment](solidity-reference.md#fee-payment)); then guard against someone draining the reserve with spam votes (eligibility already limits this to weight holders).

## What stays public

Be explicit with your users about these, because "private voting" sets expectations:

- **Participation.** The `castVote` transaction and the `VoteCast(id, voter, weight, changed)` event show who voted, with what weight, and whether they changed their mind. Never log the choice, the ciphertext, or a tally handle; the reference logs none of them.
- **Turnout and total weight cast.** Plaintext sums of public weights. Needed for quorum; harmless because weights are public anyway.
- **The number of options and the proposal text.** Obviously.
- **Timing.** Block timestamps of votes. If "voted 30 seconds after the whale" is sensitive, batch votes through a relayer.

To hide the voter set itself you need to break the link between EOA and ballot: a relayer or session-key path that submits ballots on behalf of voters (the contract-facing `castVote(id, euint256)` overload plus `isAllowed` is the hook), combined with an eligibility proof that does not name the voter. That is a different privacy boundary and a different threat model; scope it as its own design.

## Receipts vs coercion resistance

`VOTER_CAN_DECRYPT_OWN_BALLOT = true` in the reference gives every voter a private receipt (`attestedDecrypt` on their own choice handle). This is great for verifiability ("did my vote land as cast?") and the wallet-signed decrypt keeps it private. It also means a voter *can* prove their vote to a third party, which is the definition of a coercion-vulnerable scheme.

Flip the constant to `false` when coercion resistance matters more than receipts (contested elections, anything with real money on the line). There is no middle ground on-chain: either the voter can decrypt the handle or they cannot.

## Confidential weight extension

When voting power itself is sensitive (a confidential token, a private cap table), the weight becomes an `euint256` too and the tally line becomes `tally.add(choice.eq(i).select(encWeight, 0))`. Three things change:

1. **Provenance.** The contract must not accept any handle the voter happens to be allowed on; it must accept only a weight handle produced by the trusted source. Have the confidential token contract call the ballot (`msg.sender == weightSource`) with the voter's snapshot handle, rather than letting voters pass handles in.
2. **Quorum and turnout become encrypted.** `totalWeightCast` is an `euint256`; quorum is `totalWeightCast.ge(quorum)` revealed as an `ebool` at close.
3. **Double counting.** The public-weight reference recomputes the subtraction on vote change from the stored plaintext weight. With encrypted weights, store the weight handle used at cast time and subtract that exact handle, not a fresh snapshot.

Combine with `WinnerOnly` mode and nothing about the distribution of power ever surfaces.

## Checklist before deploying a ballot

- [ ] Weights come from a real snapshot, not an admin `setWeights` (remove or timelock the admin path)
- [ ] Reveal mode chosen per proposal and stated to voters up front
- [ ] No `allow` on any tally handle to any address other than `address(this)`
- [ ] Every tally update ends in `allowThis()`; the old choice handle keeps `allowThis()` for vote changes
- [ ] No encrypted value in any event; no `require` on an encrypted condition
- [ ] `finalize()` checks `decryption.handle` against the expected handle for every attestation, in order
- [ ] Fee model decided (voter pays vs pre-funded) and the `castVote` signature matches it
- [ ] Receipt policy (`VOTER_CAN_DECRYPT_OWN_BALLOT`) decided deliberately
- [ ] Tie rule documented (a sensible default is lowest option index wins in `WinnerOnly` mode)
- [ ] Foundry tests run green with `IncoTest`, including a swapped-attestation rejection case

## Related

- Sealed-bid auctions share the "sealed input, reveal at close" shape: [games/archetypes.md#5-sealed-bid-auction](games/archetypes.md#5-sealed-bid-auction)
- Attestation patterns in general: [scripts/ConfidentialWithAttestation.sol](../scripts/ConfidentialWithAttestation.sol)
- Frontend encrypt / decrypt / reveal calls: [js-sdk-reference.md](js-sdk-reference.md)
