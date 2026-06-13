// ─────────────────────────────────────────────────────────────────────────────
// REFERENCE EXAMPLE — Inco Lightning skill (games layer). Mines payout math (pure library).
// Hypergeometric multiplier + house edge + max-payout, all xSCALE(1e6). Single source
// of truth so cash-out and factory reservation can't drift; mirror it byte-identically
// in TS for UI multiplier parity. See references/games/settlement-and-math.md (section 2).
// ─────────────────────────────────────────────────────────────────────────────
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Shared, byte-identical multiplier math used by both `Mines` (for the
/// actual cashout) and `MinesFactory` (for the per-game maxPayout reservation).
/// Keeping a single source-of-truth prevents the solvency invariant
/// `winnings <= maxPayout` from being broken by a future drift between two copies.
library MinesMath {
    uint256 internal constant SCALE = 1_000_000;
    uint256 internal constant HOUSE_EDGE_BPS = 100; // 1.00 %

    /// @dev Canonical hypergeometric Mines multiplier with a fixed house edge.
    ///      `(safeCount, mines, total)` → ×SCALE multiplier (e.g. 1_125_000 == 1.125×).
    function calculateMultiplier(
        uint256 safeCount,
        uint256 mines,
        uint256 total
    ) internal pure returns (uint256) {
        if (safeCount == 0) return SCALE;
        require(safeCount + mines <= total, "invalid args");
        uint256 num = SCALE;
        for (uint256 i = 0; i < safeCount; i++) {
            num = (num * (total - i)) / (total - mines - i);
        }
        return (num * (10_000 - HOUSE_EDGE_BPS)) / 10_000;
    }

    function calculateWinnings(
        uint256 betAmount,
        uint256 safeCount,
        uint256 mines,
        uint256 total
    ) internal pure returns (uint256) {
        return (betAmount * calculateMultiplier(safeCount, mines, total)) / SCALE;
    }

    function calculateMaxPayout(
        uint256 betAmount,
        uint256 size,
        uint256 bombs
    ) internal pure returns (uint256) {
        uint256 totalTiles = size * size;
        require(bombs < totalTiles, "bombs >= total");
        return calculateWinnings(betAmount, totalTiles - bombs, bombs, totalTiles);
    }
}
