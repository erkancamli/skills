// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Foundry tests for ConfidentialBallot using the IncoTest mock infrastructure
// (no Docker / covalidator needed). Copy next to the contract in a Foundry
// project set up as in references/deployment-testing.md and run `forge test -vvv`.

import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
import {inco, euint256, e} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {ConfidentialBallot} from "./ConfidentialBallot.sol";

contract ConfidentialBallotTest is IncoTest {
    ConfidentialBallot internal ballot;

    uint64 internal start;
    uint64 internal end;

    function setUp() public override {
        super.setUp();
        ballot = new ConfidentialBallot(address(this));

        address[] memory voters = new address[](3);
        uint256[] memory weights = new uint256[](3);
        voters[0] = alice;
        weights[0] = 100;
        voters[1] = bob;
        weights[1] = 60;
        voters[2] = carol;
        weights[2] = 30;
        ballot.setWeights(voters, weights);

        start = uint64(block.timestamp);
        end = uint64(block.timestamp + 1 days);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    function _create(uint8 options, uint256 quorum, ConfidentialBallot.RevealMode mode) internal returns (uint256) {
        return ballot.createProposal("Fund the grants program?", options, start, end, quorum, mode);
    }

    function _vote(uint256 id, address voter, uint256 choice) internal {
        bytes memory ct = fakePrepareEuint256Ciphertext(choice, voter, address(ballot));
        uint256 fee = inco.getFee(); // read before prank: getFee() is an external call
        vm.prank(voter);
        ballot.castVote{value: fee}(id, ct);
        processAllOperations();
    }

    function _attest(euint256 handle) internal returns (DecryptionAttestation memory d, bytes[] memory sigs) {
        // After e.reveal() the handle is decryptable by anyone; use a random requester.
        (d, sigs) = getDecryptionAttestation(
            address(0xBEEF), HandleWithProof({handle: euint256.unwrap(handle), proof: _emptyAllowanceProof()})
        );
    }

    // ─── Tallies mode ───────────────────────────────────────

    function testTalliesModeCountsWeightedVotesAndFinalizes() public {
        uint256 id = _create(2, 0, ConfidentialBallot.RevealMode.Tallies);

        _vote(id, alice, 1); // 100 for
        _vote(id, bob, 0); // 60 against
        _vote(id, carol, 1); // 30 for

        // Tallies are correct under the hood (test-only decrypt of the mock store)
        euint256[] memory handles = ballot.tallyHandles(id);
        assertEq(getUint256Value(handles[0]), 60);
        assertEq(getUint256Value(handles[1]), 130);

        (,,,,,, uint256 totalWeight, uint256 voterCount,,) = ballot.getProposal(id);
        assertEq(totalWeight, 190);
        assertEq(voterCount, 3);

        // Cannot close before the window ends
        vm.expectRevert(ConfidentialBallot.VotingStillOpen.selector);
        ballot.close(id);

        vm.warp(end);
        ballot.close(id);
        processAllOperations();

        // Finalize with one attestation per option, in order
        DecryptionAttestation[] memory ds = new DecryptionAttestation[](2);
        bytes[][] memory sigs = new bytes[][](2);
        (ds[0], sigs[0]) = _attest(handles[0]);
        (ds[1], sigs[1]) = _attest(handles[1]);
        ballot.finalize(id, ds, sigs);

        (bool finalized, uint256 winner, uint256[] memory tallies, bool quorumOk) = ballot.result(id);
        assertTrue(finalized);
        assertEq(winner, 1);
        assertEq(tallies[0], 60);
        assertEq(tallies[1], 130);
        assertTrue(quorumOk);
    }

    function testChangingAVoteMovesWeightBetweenOptions() public {
        uint256 id = _create(3, 0, ConfidentialBallot.RevealMode.Tallies);

        _vote(id, alice, 2);
        euint256[] memory h = ballot.tallyHandles(id);
        assertEq(getUint256Value(h[2]), 100);

        _vote(id, alice, 0); // change of mind
        h = ballot.tallyHandles(id);
        assertEq(getUint256Value(h[0]), 100);
        assertEq(getUint256Value(h[2]), 0);

        (,,,,,, uint256 totalWeight, uint256 voterCount,,) = ballot.getProposal(id);
        assertEq(totalWeight, 100, "weight counted once");
        assertEq(voterCount, 1, "voter counted once");
    }

    function testOutOfRangeChoiceCountsAsZeroWithoutReverting() public {
        uint256 id = _create(2, 0, ConfidentialBallot.RevealMode.Tallies);

        _vote(id, alice, 7); // invalid: only options 0 and 1 exist
        euint256[] memory h = ballot.tallyHandles(id);
        assertEq(getUint256Value(h[0]), 0);
        assertEq(getUint256Value(h[1]), 0);
        assertTrue(ballot.hasVoted(id, alice), "ballot recorded, contribution silently zero");
    }

    function testIneligibleVoterIsRejected() public {
        uint256 id = _create(2, 0, ConfidentialBallot.RevealMode.Tallies);
        address stranger = address(0x5717);
        vm.deal(stranger, 1 ether);
        bytes memory ct = fakePrepareEuint256Ciphertext(1, stranger, address(ballot));
        uint256 fee = inco.getFee();
        vm.prank(stranger);
        vm.expectRevert(ConfidentialBallot.NotEligible.selector);
        ballot.castVote{value: fee}(id, ct);
    }

    function testFeeIsRequired() public {
        uint256 id = _create(2, 0, ConfidentialBallot.RevealMode.Tallies);
        bytes memory ct = fakePrepareEuint256Ciphertext(1, alice, address(ballot));
        uint256 fee = inco.getFee();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ConfidentialBallot.FeeNotPaid.selector, fee));
        ballot.castVote(id, ct);
    }

    function testQuorumIsPlaintext() public {
        uint256 id = _create(2, 150, ConfidentialBallot.RevealMode.Tallies);
        _vote(id, alice, 1); // 100 < 150
        assertFalse(ballot.quorumReached(id));
        _vote(id, bob, 1); // 160 >= 150
        assertTrue(ballot.quorumReached(id));
    }

    // ─── Winner-only mode ───────────────────────────────────

    function testWinnerOnlyRevealsJustTheIndex() public {
        uint256 id = _create(3, 0, ConfidentialBallot.RevealMode.WinnerOnly);

        _vote(id, alice, 2); // 100
        _vote(id, bob, 1); // 60
        _vote(id, carol, 1); // 30 -> option 1 = 90, option 2 = 100

        vm.warp(end);
        ballot.close(id);
        processAllOperations();

        euint256 w = ballot.winnerHandle(id);
        assertEq(getUint256Value(w), 2);

        DecryptionAttestation[] memory ds = new DecryptionAttestation[](1);
        bytes[][] memory sigs = new bytes[][](1);
        (ds[0], sigs[0]) = _attest(w);
        ballot.finalize(id, ds, sigs);

        (bool finalized, uint256 winner, uint256[] memory tallies,) = ballot.result(id);
        assertTrue(finalized);
        assertEq(winner, 2);
        assertEq(tallies.length, 0, "margins are never published in WinnerOnly mode");
    }

    function testWinnerOnlyTieGoesToLowestIndex() public {
        address[] memory voters = new address[](2);
        uint256[] memory weights = new uint256[](2);
        voters[0] = alice;
        weights[0] = 50;
        voters[1] = bob;
        weights[1] = 50;
        ballot.setWeights(voters, weights);

        uint256 id = _create(2, 0, ConfidentialBallot.RevealMode.WinnerOnly);
        _vote(id, alice, 1);
        _vote(id, bob, 0);

        vm.warp(end);
        ballot.close(id);
        processAllOperations();
        assertEq(getUint256Value(ballot.winnerHandle(id)), 0, "tie resolves to the lowest index");
    }

    // ─── Attestation binding ────────────────────────────────

    function testFinalizeRejectsAttestationForWrongHandle() public {
        uint256 id = _create(2, 0, ConfidentialBallot.RevealMode.Tallies);
        _vote(id, alice, 1);
        vm.warp(end);
        ballot.close(id);
        processAllOperations();

        euint256[] memory h = ballot.tallyHandles(id);
        DecryptionAttestation[] memory ds = new DecryptionAttestation[](2);
        bytes[][] memory sigs = new bytes[][](2);
        // Swap the two attestations: valid signatures, wrong positions
        (ds[1], sigs[1]) = _attest(h[0]);
        (ds[0], sigs[0]) = _attest(h[1]);
        vm.expectRevert(abi.encodeWithSelector(ConfidentialBallot.HandleMismatch.selector, 0));
        ballot.finalize(id, ds, sigs);
    }
}
