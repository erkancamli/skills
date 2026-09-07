// ─────────────────────────────────────────────────────────────────────────────
// REFERENCE EXAMPLE — Inco Lightning skill (governance layer). Confidential Ballot.
// Private voting for DAOs / token holders: every voter's CHOICE is encrypted, the
// running TALLY is encrypted and unreadable by anyone (including the admin) until
// the vote closes, and the result is brought back on-chain with an attestation so
// a timelock or treasury can act on it. Voting WEIGHT is public (a snapshot, e.g.
// ERC20Votes.getPastVotes) — "public weight, private direction", the model most
// DAOs actually need. See references/governance.md for the design reasoning and
// the confidential-weight extension.
//
// Demonstrates: encrypted choice ingestion + fee; "silent invalid ballot" (an
// out-of-range choice matches no option, so it counts zero and never reverts);
// per-option tally with eq/select/add; vote CHANGE by subtracting the previous contribution;
// two reveal modes (all tallies vs winner-only) using e.reveal; a select-chain
// running max to pick the winner without decrypting; attested finalization with
// handle checks; allowThis on every encrypted store; no ballot ever in an event.
//
// (!) Reference quality — things to decide/harden before production:
//   1. Weights are set by an admin snapshot (setWeights). Wire this to your real
//      source of truth (ERC20Votes / ERC721 snapshot / allowlist) and remove the
//      admin path, or the admin can rig the electorate.
//   2. Participation (who voted, with what weight) is public by design. If the
//      SET of voters is sensitive too, see governance.md#what-stays-public.
//   3. Ties resolve to the LOWEST option index. Make that explicit in your rules
//      or add an ebool `tie` that reveals alongside the winner.
//   4. Voters can decrypt their own ballot (a receipt). That is great for
//      verifiability and bad for coercion resistance; flip
//      VOTER_CAN_DECRYPT_OWN_BALLOT if you need the latter.
// ─────────────────────────────────────────────────────────────────────────────
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";

contract ConfidentialBallot {
    using e for *;

    // ─── Types ──────────────────────────────────────────────

    /// @notice What becomes public when the vote closes.
    /// - Tallies: every option's total is revealed (classic DAO vote).
    /// - WinnerOnly: only the winning option index is revealed; the margins stay
    ///   secret forever (protects minorities, kills "we lost by 2%" politics).
    enum RevealMode {
        Tallies,
        WinnerOnly
    }

    struct Proposal {
        string description;
        uint8 optionCount; // 2..MAX_OPTIONS; option 0 is conventionally "against"/"no"
        uint64 start;
        uint64 end;
        uint256 quorum; // minimum total weight cast for the vote to be valid (0 = none)
        RevealMode mode;
        // Public aggregates (weights are public, so these leak nothing new)
        uint256 totalWeightCast;
        uint256 voterCount;
        // Encrypted state
        euint256[] tallies; // one per option, only this contract can use them
        euint256 winner; // set at close() in WinnerOnly mode
        // Lifecycle
        bool closed;
        bool finalized;
        // Finalized plaintext result (populated by finalize())
        uint256[] finalTallies; // Tallies mode
        uint256 finalWinner; // both modes (derived from finalTallies in Tallies mode)
    }

    struct Ballot {
        euint256 choice; // encrypted option index
        uint256 weight; // weight that was counted (public snapshot weight at cast time)
        bool cast;
    }

    // ─── Config ─────────────────────────────────────────────

    uint8 public constant MAX_OPTIONS = 8;
    /// @dev Receipt vs coercion resistance; see header note 4.
    bool public constant VOTER_CAN_DECRYPT_OWN_BALLOT = true;

    // ─── State ──────────────────────────────────────────────

    address public admin;
    Proposal[] internal proposals;
    mapping(uint256 => mapping(address => Ballot)) internal ballots;
    /// @notice Public voting weight per address (a snapshot). 0 = not eligible.
    mapping(address => uint256) public weightOf;

    // ─── Events ─────────────────────────────────────────────
    // NEVER put a choice, a ciphertext, or a tally handle in an event.

    event ProposalCreated(
        uint256 indexed id, string description, uint8 optionCount, uint64 start, uint64 end, RevealMode mode
    );
    event VoteCast(uint256 indexed id, address indexed voter, uint256 weight, bool changed);
    event ProposalClosed(uint256 indexed id);
    event ProposalFinalized(uint256 indexed id, uint256 winner, bool quorumReached);
    event WeightsUpdated(uint256 count);

    // ─── Errors ─────────────────────────────────────────────

    error NotAdmin();
    error FeeNotPaid(uint256 required);
    error UnknownProposal();
    error BadOptionCount();
    error BadWindow();
    error VotingNotOpen();
    error VotingStillOpen();
    error AlreadyClosed();
    error NotClosed();
    error AlreadyFinalized();
    error NotEligible();
    error InvalidAttestation();
    error HandleMismatch(uint256 index);
    error WrongAttestationCount(uint256 expected, uint256 got);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    // ─── Electorate (public weights) ────────────────────────

    /// @notice Snapshot voting weights. Replace with your real source of truth
    /// (see header note 1). Weights are PUBLIC; only the direction of a vote is private.
    function setWeights(address[] calldata voters, uint256[] calldata weights) external onlyAdmin {
        require(voters.length == weights.length, "length mismatch");
        for (uint256 i = 0; i < voters.length; i++) {
            weightOf[voters[i]] = weights[i];
        }
        emit WeightsUpdated(voters.length);
    }

    // ─── Proposals ──────────────────────────────────────────

    function createProposal(
        string calldata description,
        uint8 optionCount,
        uint64 start,
        uint64 end,
        uint256 quorum,
        RevealMode mode
    ) external onlyAdmin returns (uint256 id) {
        if (optionCount < 2 || optionCount > MAX_OPTIONS) revert BadOptionCount();
        if (end <= start || end <= block.timestamp) revert BadWindow();

        id = proposals.length;
        Proposal storage p = proposals.push();
        p.description = description;
        p.optionCount = optionCount;
        p.start = start;
        p.end = end;
        p.quorum = quorum;
        p.mode = mode;

        // Tallies start at an encrypted zero. Trivial encryptions are readable
        // on-chain at creation, which is fine: everyone knows a tally starts at 0.
        // After the first e.add they are opaque. allowThis so future txs can add.
        for (uint8 i = 0; i < optionCount; i++) {
            euint256 zero = e.asEuint256(0);
            zero.allowThis();
            p.tallies.push(zero);
        }

        emit ProposalCreated(id, description, optionCount, start, end, mode);
    }

    // ─── Voting ─────────────────────────────────────────────

    /// @notice Cast (or change) a private vote. `encryptedChoice` is an euint256
    /// ciphertext of the option index, produced client-side with
    /// `zap.encrypt(choice, { accountAddress: voter, dappAddress: this })`.
    /// Out-of-range choices are counted with weight 0 (silent invalid ballot),
    /// never reverted, so the transaction itself does not leak validity.
    function castVote(uint256 id, bytes calldata encryptedChoice) external payable {
        if (msg.value < inco.getFee()) revert FeeNotPaid(inco.getFee());
        Proposal storage p = _open(id);

        uint256 weight = weightOf[msg.sender];
        if (weight == 0) revert NotEligible();

        euint256 choice = encryptedChoice.newEuint256(msg.sender);
        _count(p, id, msg.sender, choice, weight);
    }

    /// @notice Contract-facing variant: cast with an existing handle (e.g. a
    /// governance frontend contract or a session-key relayer that already holds
    /// the encrypted choice). The caller must be allowed on the handle.
    function castVote(uint256 id, euint256 choice) external {
        if (!msg.sender.isAllowed(choice)) revert NotEligible();
        Proposal storage p = _open(id);

        uint256 weight = weightOf[msg.sender];
        if (weight == 0) revert NotEligible();

        _count(p, id, msg.sender, choice, weight);
    }

    function _count(Proposal storage p, uint256 id, address voter, euint256 choice, uint256 weight) internal {
        Ballot storage b = ballots[id][voter];
        bool changed = b.cast;

        // Changing a vote: remove the previous contribution first. The old choice
        // handle is still allowed to this contract, so this is a plain re-compute.
        if (changed) {
            _applyBallot(p, b.choice, b.weight, false);
            p.totalWeightCast -= b.weight;
        } else {
            p.voterCount += 1;
        }

        _applyBallot(p, choice, weight, true);
        p.totalWeightCast += weight;

        b.choice = choice;
        b.weight = weight;
        b.cast = true;

        choice.allowThis(); // needed again if the voter changes their vote later
        if (VOTER_CAN_DECRYPT_OWN_BALLOT) {
            choice.allow(voter);
        }

        emit VoteCast(id, voter, weight, changed);
    }

    /// @dev tallies[i] += (choice == i ? weight : 0) for every option, all under
    /// encryption. `add == false` subtracts instead (vote change). An out-of-range
    /// choice matches no option and therefore contributes nothing.
    function _applyBallot(Proposal storage p, euint256 choice, uint256 weight, bool add) internal {
        euint256 zero = e.asEuint256(0);
        euint256 w = e.asEuint256(weight);
        uint256 n = p.optionCount;
        for (uint256 i = 0; i < n; i++) {
            ebool isThis = choice.eq(i);
            euint256 delta = isThis.select(w, zero);
            euint256 updated = add ? p.tallies[i].add(delta) : p.tallies[i].sub(delta);
            updated.allowThis(); // CRITICAL: the contract must keep access to the new handle
            p.tallies[i] = updated;
        }
    }

    // ─── Close & reveal ─────────────────────────────────────

    /// @notice Anyone can close a proposal once its window has ended. This is the
    /// only moment anything about the tally becomes decryptable.
    function close(uint256 id) external {
        Proposal storage p = _get(id);
        if (p.closed) revert AlreadyClosed();
        if (block.timestamp < p.end) revert VotingStillOpen();
        p.closed = true;

        if (p.mode == RevealMode.Tallies) {
            for (uint256 i = 0; i < p.optionCount; i++) {
                e.reveal(p.tallies[i]); // irreversible: anyone can now attestedReveal it
            }
        } else {
            // Winner-only: running max over the encrypted tallies, then reveal just
            // the index. Ties resolve to the lowest index (strict gt).
            euint256 bestValue = p.tallies[0];
            euint256 bestIndex = e.asEuint256(0);
            for (uint256 i = 1; i < p.optionCount; i++) {
                ebool better = p.tallies[i].gt(bestValue);
                bestValue = better.select(p.tallies[i], bestValue);
                bestIndex = better.select(e.asEuint256(i), bestIndex);
            }
            bestIndex.allowThis();
            p.winner = bestIndex;
            e.reveal(bestIndex);
        }

        emit ProposalClosed(id);
    }

    /// @notice Bring the decrypted result on-chain. Anyone can submit the
    /// covalidator attestations obtained via `zap.attestedReveal` after close().
    /// - Tallies mode: one attestation per option, in option order.
    /// - WinnerOnly mode: exactly one attestation, for the winner handle.
    function finalize(uint256 id, DecryptionAttestation[] calldata decryptions, bytes[][] calldata signatures)
        external
    {
        Proposal storage p = _get(id);
        if (!p.closed) revert NotClosed();
        if (p.finalized) revert AlreadyFinalized();
        if (decryptions.length != signatures.length) {
            revert WrongAttestationCount(decryptions.length, signatures.length);
        }

        if (p.mode == RevealMode.Tallies) {
            if (decryptions.length != p.optionCount) revert WrongAttestationCount(p.optionCount, decryptions.length);
            uint256 best = 0;
            for (uint256 i = 0; i < p.optionCount; i++) {
                _verify(decryptions[i], signatures[i]);
                // ALWAYS bind the attestation to the handle we expect, in order.
                if (euint256.unwrap(p.tallies[i]) != decryptions[i].handle) revert HandleMismatch(i);
                uint256 v = uint256(decryptions[i].value);
                p.finalTallies.push(v);
                if (v > p.finalTallies[best]) best = i;
            }
            p.finalWinner = best;
        } else {
            if (decryptions.length != 1) revert WrongAttestationCount(1, decryptions.length);
            _verify(decryptions[0], signatures[0]);
            if (euint256.unwrap(p.winner) != decryptions[0].handle) revert HandleMismatch(0);
            p.finalWinner = uint256(decryptions[0].value);
        }

        p.finalized = true;
        emit ProposalFinalized(id, p.finalWinner, quorumReached(id));
    }

    function _verify(DecryptionAttestation calldata d, bytes[] calldata sigs) internal view {
        if (!inco.incoVerifier().isValidDecryptionAttestation(d, sigs)) revert InvalidAttestation();
    }

    // ─── Views ──────────────────────────────────────────────

    function proposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function getProposal(uint256 id)
        external
        view
        returns (
            string memory description,
            uint8 optionCount,
            uint64 start,
            uint64 end,
            uint256 quorum,
            RevealMode mode,
            uint256 totalWeightCast,
            uint256 voterCount,
            bool closed,
            bool finalized
        )
    {
        Proposal storage p = _get(id);
        return (
            p.description,
            p.optionCount,
            p.start,
            p.end,
            p.quorum,
            p.mode,
            p.totalWeightCast,
            p.voterCount,
            p.closed,
            p.finalized
        );
    }

    /// @notice Encrypted tally handles. Only decryptable after close() in Tallies
    /// mode (via attestedReveal); before that nobody, admin included, can read them.
    function tallyHandles(uint256 id) external view returns (euint256[] memory) {
        return _get(id).tallies;
    }

    /// @notice Encrypted winner handle (WinnerOnly mode, after close()).
    function winnerHandle(uint256 id) external view returns (euint256) {
        return _get(id).winner;
    }

    /// @notice The voter's own encrypted ballot handle (decryptable by the voter
    /// when VOTER_CAN_DECRYPT_OWN_BALLOT is true).
    function myBallot(uint256 id) external view returns (euint256 choice, uint256 weight, bool cast) {
        Ballot storage b = ballots[id][msg.sender];
        return (b.choice, b.weight, b.cast);
    }

    function hasVoted(uint256 id, address voter) external view returns (bool) {
        return ballots[id][voter].cast;
    }

    /// @notice Plaintext result, valid only once finalized. In WinnerOnly mode
    /// `tallies` is empty by design.
    function result(uint256 id)
        external
        view
        returns (bool finalized, uint256 winner, uint256[] memory tallies, bool quorumOk)
    {
        Proposal storage p = _get(id);
        return (p.finalized, p.finalWinner, p.finalTallies, quorumReached(id));
    }

    /// @notice Quorum is a plaintext check because weights are public.
    function quorumReached(uint256 id) public view returns (bool) {
        Proposal storage p = _get(id);
        return p.totalWeightCast >= p.quorum;
    }

    // ─── Internal helpers ───────────────────────────────────

    function _get(uint256 id) internal view returns (Proposal storage p) {
        if (id >= proposals.length) revert UnknownProposal();
        p = proposals[id];
    }

    function _open(uint256 id) internal view returns (Proposal storage p) {
        p = _get(id);
        if (p.closed || block.timestamp < p.start || block.timestamp >= p.end) revert VotingNotOpen();
    }
}
