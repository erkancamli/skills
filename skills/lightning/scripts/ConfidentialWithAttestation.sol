// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";

/// @notice Template demonstrating all three attestation patterns:
/// - Attested Decrypt: authorized user decrypts their own data
/// - Attested Reveal: anyone decrypts publicly revealed data
/// - Attested Compute: off-chain computation with on-chain verification
contract ConfidentialWithAttestation {
    using e for *;

    // ─── State ──────────────────────────────────────────────

    mapping(address => euint256) internal secretScores;
    euint256 public revealedRandom;
    uint256 public decryptedRandom;

    error InsufficientFees();

    // ─── Setup ──────────────────────────────────────────────

    /// @notice Store encrypted score for a user and generate a public random number
    constructor() payable {
        require(msg.value >= inco.getFee(), "Fee not paid");

        // Generate a random number and reveal it (anyone can decrypt)
        revealedRandom = e.rand();
        e.reveal(revealedRandom);
    }

    /// @notice Set user's encrypted score from off-chain input
    function setScore(bytes memory encryptedScore) external payable {
        require(msg.value >= inco.getFee(), "Fee not paid");
        euint256 score = encryptedScore.newEuint256(msg.sender);
        secretScores[msg.sender] = score;
        score.allow(msg.sender);
        score.allowThis();
    }

    /// @notice Get user's encrypted score handle (for off-chain decryption)
    function getMyScore() external view returns (euint256) {
        return secretScores[msg.sender];
    }

    // ─── Pattern 1: Attested Decrypt ────────────────────────
    // User decrypts their own score and submits proof on-chain

    function submitMyScore(
        DecryptionAttestation memory decryption,
        bytes[] memory signatures
    ) external {
        // 1. Verify covalidator signatures
        require(
            inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures),
            "Invalid signature"
        );

        // 2. Verify handle matches user's score
        require(
            euint256.unwrap(secretScores[msg.sender]) == decryption.handle,
            "Handle mismatch"
        );

        // 3. Use the decrypted value
        uint256 score = uint256(decryption.value);
        // ... do something with score
    }

    // ─── Pattern 2: Attested Reveal ─────────────────────────
    // Anyone decrypts the publicly revealed random number

    function submitRevealedRandom(
        DecryptionAttestation memory decryption,
        bytes[] memory signatures
    ) external {
        require(
            inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures),
            "Invalid signature"
        );

        require(
            euint256.unwrap(revealedRandom) == decryption.handle,
            "Handle mismatch"
        );

        decryptedRandom = uint256(decryption.value);
    }

    // ─── Pattern 3: Attested Compute ────────────────────────
    // Off-chain: check if user's score >= threshold
    // On-chain: verify the computation result

    function submitScoreCheck(
        uint256 threshold,
        DecryptionAttestation memory decryption,
        bytes[] memory signatures
    ) external {
        // 1. Verify signatures
        require(
            inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures),
            "Invalid signature"
        );

        // 2. Recompute the expected handle on-chain
        //    This must match what the off-chain attestedCompute produced
        require(
            ebool.unwrap(e.ge(secretScores[msg.sender], threshold)) == decryption.handle,
            "Computed handle mismatch"
        );

        // 3. Check the boolean result
        require(asBool(decryption.value) == true, "Score check failed");

        // Score check passed - proceed with gated action
    }
}
