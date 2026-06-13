// ─────────────────────────────────────────────────────────────────────────────
// REFERENCE EXAMPLE — Inco Lightning skill (games layer). Mines factory (holds the bankroll).
// Demonstrates Model A settlement SAFETY: cumulative liability reservation
// (totalActiveLiability + canAffordMaxPayout), capped permissionless cleanup, and
// .call{value:} payouts with a withdraw guard — the F-1..F-5 audit fixes documented in
// references/games/settlement-and-math.md (sections 3-4). Deploys one Mines per game.
// ─────────────────────────────────────────────────────────────────────────────
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Mines} from "./Mines.sol";
import {MinesMath} from "./MinesMath.sol";
import {inco} from "@inco/lightning/src/Lib.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MinesFactory is Ownable {
    struct GameInfo {
        address contractAddress;
        address player;
        address beneficiary;
        uint256 betAmount;
        uint256 maxPayout;
        uint256 createdAt;
        bool isActive;
        bool playerWon;
        uint256 paidAmount;
    }

    mapping(address => address[]) public playerMinesContracts;
    // NOTE: `playerMinesContractCount` mapping removed — was redundant with
    // `playerMinesContracts[player].length`. See `getPlayerMinesContractCount`
    // which now derives it. Saves one SSTORE per `createMinesContract` (~22k gas).
    mapping(address => GameInfo) public gameInfoByContract;

    address[] public activeGameAddresses;
    mapping(address => uint256) private activeGameIndex;

    uint256 public totalActiveLiability;

    uint256 public constant GAME_TIMEOUT = 15 minutes;
    uint256 public constant CLEANUP_CAP_DEFAULT = 16; // max expired games swept per createMinesContract

    // OZ-style reentrancy guard (1↔2 instead of 0↔1) — never lets the slot fall
    // back to zero, so each call pays a warm SSTORE (~3k gas) instead of the
    // initial-write cost (~22k gas).
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;
    uint8 private _entered = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_entered != _ENTERED, "reentrant");
        _entered = _ENTERED;
        _;
        _entered = _NOT_ENTERED;
    }

    event GameCreated(address indexed player, address indexed contractAddress, uint256 betAmount);
    event GamePayout(address indexed player, address indexed contractAddress, uint256 amount);
    event GameExpired(address indexed player, address indexed contractAddress, uint256 betAmount);
    event GameRefunded(address indexed player, address indexed contractAddress, uint256 refunded);
    event GameStateUpdated(address indexed contractAddress, address indexed player, string state);

    constructor() Ownable(msg.sender) {}

    // ── Math (canonical via MinesMath library) ──────────────
    function calculateMultiplier(
        uint256 safeCount,
        uint256 mineCount,
        uint256 totalTiles
    ) public pure returns (uint256) {
        return MinesMath.calculateMultiplier(safeCount, mineCount, totalTiles);
    }

    function calculateMaxPayout(
        uint256 size,
        uint256 bombs,
        uint256 betAmount
    ) public pure returns (uint256) {
        return MinesMath.calculateMaxPayout(betAmount, size, bombs);
    }

    function canAffordMaxPayout(
        uint256 size,
        uint256 bombs,
        uint256 betAmount
    ) public view returns (bool) {
        uint256 maxPayout = calculateMaxPayout(size, bombs, betAmount);
        return address(this).balance >= totalActiveLiability + maxPayout;
    }

    function getTotalActiveLiability() public view returns (uint256) {
        return totalActiveLiability;
    }

    function getAvailableBalance() public view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance <= totalActiveLiability) return 0;
        return balance - totalActiveLiability;
    }

    function getActiveGameCount() public view returns (uint256) {
        return activeGameAddresses.length;
    }

    function getActiveGameAddresses() public view returns (address[] memory) {
        return activeGameAddresses;
    }

    /// @notice Create a new Mines game and initialize its board atomically.
    /// msg.value must cover `betAmount + initFee`. Excess is refunded.
    function createMinesContract(
        uint256 size,
        uint256 bombs,
        uint256 betAmount,
        address beneficiary
    ) public payable nonReentrant returns (address) {
        require(beneficiary != address(0), "beneficiary zero");
        require(size > 0, "invalid config");
        require(bombs > 0, "need bomb");
        require(bombs < size * size, "bombs >= total");

        uint256 initFee = inco.getFee();
        require(msg.value >= betAmount + initFee, "insufficient payment");

        // Sweep up to CLEANUP_CAP_DEFAULT expired games to free their liability.
        // Bounded so a stale active-game backlog can't gas-DoS new game creation.
        _cleanupExpiredGames(CLEANUP_CAP_DEFAULT);

        uint256 maxPayout = calculateMaxPayout(size, bombs, betAmount);

        // Available balance (excluding the bet just deposited AND the initFee
        // we're about to forward) must cover the new game's max payout on top
        // of all existing liabilities.
        require(
            address(this).balance - msg.value >= totalActiveLiability + maxPayout - betAmount,
            "factory cannot cover cumulative max payouts"
        );

        Mines mines = new Mines(
            size,
            bombs,
            address(this),
            msg.sender,
            betAmount,
            beneficiary
        );
        address contractAddress = address(mines);
        mines.initBoard{value: initFee}();

        playerMinesContracts[msg.sender].push(contractAddress);

        gameInfoByContract[contractAddress] = GameInfo({
            contractAddress: contractAddress,
            player: msg.sender,
            beneficiary: beneficiary,
            betAmount: betAmount,
            maxPayout: maxPayout,
            createdAt: block.timestamp,
            isActive: true,
            playerWon: false,
            paidAmount: 0
        });

        totalActiveLiability += maxPayout;
        activeGameAddresses.push(contractAddress);
        activeGameIndex[contractAddress] = activeGameAddresses.length - 1;

        // Refund any overpayment.
        uint256 overpay = msg.value - betAmount - initFee;
        if (overpay > 0) {
            (bool ok, ) = payable(msg.sender).call{value: overpay}("");
            require(ok, "refund failed");
        }

        emit GameCreated(msg.sender, contractAddress, betAmount);
        emit GameStateUpdated(contractAddress, msg.sender, "created");
        return contractAddress;
    }

    function payoutPlayer(address beneficiary, uint256 amount) external nonReentrant {
        address contractAddress = msg.sender;
        GameInfo storage gameInfo = gameInfoByContract[contractAddress];

        require(gameInfo.isActive, "game not active");
        require(gameInfo.beneficiary == beneficiary, "invalid beneficiary");
        require(!isGameExpired(contractAddress), "game expired");
        require(amount <= gameInfo.maxPayout, "amount > maxPayout"); // defense-in-depth cap
        require(address(this).balance >= amount, "insufficient balance");

        gameInfo.isActive = false;
        gameInfo.playerWon = true;
        gameInfo.paidAmount = amount;

        totalActiveLiability -= gameInfo.maxPayout;
        _removeFromActiveGames(contractAddress);

        // Use .call so smart-contract beneficiaries (Safe, AA wallets, EIP-7702)
        // can receive winnings — `.transfer` only forwards 2300 gas and silently
        // bricks payouts to any non-trivial receive() implementation.
        (bool ok, ) = payable(beneficiary).call{value: amount}("");
        require(ok, "payout failed");

        emit GamePayout(beneficiary, contractAddress, amount);
        emit GameStateUpdated(contractAddress, beneficiary, "won");
    }

    // No external calls in this path — reentrancy not reachable, so no guard needed.
    function playerLost(address player) external {
        address contractAddress = msg.sender;
        GameInfo storage gameInfo = gameInfoByContract[contractAddress];

        require(gameInfo.isActive, "game not active");
        require(gameInfo.player == player, "invalid player");

        gameInfo.isActive = false;
        gameInfo.playerWon = false;
        gameInfo.paidAmount = 0;

        totalActiveLiability -= gameInfo.maxPayout;
        _removeFromActiveGames(contractAddress);

        emit GameStateUpdated(contractAddress, player, "lost");
    }

    function isGameExpired(address contractAddress) public view returns (bool) {
        GameInfo memory gameInfo = gameInfoByContract[contractAddress];
        return block.timestamp >= gameInfo.createdAt + GAME_TIMEOUT;
    }

    function _removeFromActiveGames(address contractAddress) internal {
        uint256 index = activeGameIndex[contractAddress];
        uint256 lastIndex = activeGameAddresses.length - 1;
        if (index != lastIndex) {
            address lastAddress = activeGameAddresses[lastIndex];
            activeGameAddresses[index] = lastAddress;
            activeGameIndex[lastAddress] = index;
        }
        activeGameAddresses.pop();
        delete activeGameIndex[contractAddress];
    }

    /// @notice Public, paginated cleanup. Anyone can call to sweep up to `maxIterations`
    /// expired games. Use this to amortize cleanup cost across many callers and avoid
    /// gas-DoS in `createMinesContract`.
    function cleanupExpiredGames(uint256 maxIterations) public returns (uint256) {
        return _cleanupExpiredGames(maxIterations);
    }

    function _cleanupExpiredGames(uint256 maxIterations) internal returns (uint256) {
        uint256 expiredCount;
        uint256 i;
        while (i < activeGameAddresses.length && expiredCount < maxIterations) {
            address gameAddress = activeGameAddresses[i];
            GameInfo storage gameInfo = gameInfoByContract[gameAddress];
            if (gameInfo.isActive && isGameExpired(gameAddress)) {
                _expireAndRefund(gameAddress, gameInfo);
                unchecked { ++expiredCount; }
                // don't increment i — the swap brought a new entry to position i
            } else {
                unchecked { ++i; }
            }
        }
        return expiredCount;
    }

    /// @notice Expire a single game and refund the player's bet.
    /// Permissionless (anyone can poke), but consequences are fair to the player
    /// (bet returned) rather than confiscatory.
    function expireGame(address contractAddress) external nonReentrant {
        GameInfo storage gameInfo = gameInfoByContract[contractAddress];
        require(gameInfo.isActive, "game not active");
        require(isGameExpired(contractAddress), "not yet expired");
        _expireAndRefund(contractAddress, gameInfo);
    }

    function _expireAndRefund(address contractAddress, GameInfo storage gameInfo) internal {
        uint256 refund = gameInfo.betAmount;
        address payee = gameInfo.player;

        gameInfo.isActive = false;
        gameInfo.playerWon = false;
        gameInfo.paidAmount = 0;
        totalActiveLiability -= gameInfo.maxPayout;
        _removeFromActiveGames(contractAddress);

        // Refund the bet on timeout. Use .call for smart-wallet compatibility.
        // If the refund fails (e.g. beneficiary is a contract that reverts),
        // we still emit the expiry event so off-chain bookkeeping is consistent.
        if (refund > 0 && address(this).balance >= refund) {
            (bool ok, ) = payable(payee).call{value: refund}("");
            if (ok) {
                emit GameRefunded(payee, contractAddress, refund);
            }
        }

        emit GameExpired(payee, contractAddress, gameInfo.betAmount);
        emit GameStateUpdated(contractAddress, payee, "expired");
    }

    /// @notice Called by Mines instances to surface per-pick state to indexers.
    /// Stronger auth than before: msg.sender must itself be a registered game.
    function updateGameState(
        address player,
        string calldata state,
        bytes calldata /*data*/
    ) external {
        address contractAddress = msg.sender;
        GameInfo storage gameInfo = gameInfoByContract[contractAddress];
        require(gameInfo.contractAddress == contractAddress, "unknown game"); // blocks event spam from EOAs
        require(gameInfo.player == player, "invalid player");
        emit GameStateUpdated(contractAddress, player, state);
    }

    function getGameInfo(address contractAddress) external view returns (GameInfo memory) {
        return gameInfoByContract[contractAddress];
    }

    function getTimeRemaining(address contractAddress) external view returns (uint256) {
        GameInfo memory gameInfo = gameInfoByContract[contractAddress];
        if (!gameInfo.isActive) return 0;
        uint256 expiry = gameInfo.createdAt + GAME_TIMEOUT;
        if (block.timestamp >= expiry) return 0;
        return expiry - block.timestamp;
    }

    function getFactoryStats()
        external
        view
        returns (
            uint256 totalBalance,
            uint256 availableBalance,
            uint256 activeLiability,
            uint256 activeGameCount
        )
    {
        totalBalance = address(this).balance;
        availableBalance = getAvailableBalance();
        activeLiability = totalActiveLiability;
        activeGameCount = activeGameAddresses.length;
    }

    function getPlayerMinesContracts(address player) public view returns (address[] memory) {
        return playerMinesContracts[player];
    }

    function getPlayerMinesContractCount(address player) public view returns (uint256) {
        return playerMinesContracts[player].length;
    }

    function getPlayerMinesContract(address player, uint256 index) public view returns (address) {
        return playerMinesContracts[player][index];
    }

    /// @notice Owner withdrawal capped to available (non-reserved) balance.
    /// Funds backing `totalActiveLiability` are not withdrawable while games are active,
    /// closing the rug-active-players path identified in audit Finding #2.
    function withdrawFunds() public onlyOwner {
        uint256 available = getAvailableBalance();
        require(available > 0, "nothing to withdraw");
        (bool ok, ) = payable(owner()).call{value: available}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {}
}
