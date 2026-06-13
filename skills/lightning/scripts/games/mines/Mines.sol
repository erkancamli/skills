// ─────────────────────────────────────────────────────────────────────────────
// REFERENCE EXAMPLE — Inco Lightning skill (games layer). Confidential "Mines" (Stake-style).
// The canonical MODEL A archetype: a wager game settled ON-CHAIN via attestation.
// Demonstrates: encrypted board via elist shuffle; per-pick getEbool; the sticky
// e.or accumulator ("ever hit a bomb"); attestation settlement in cashOut/concedeLoss
// (no callback). Pairs with MinesMath.sol (payout math) + MinesFactory.sol (bankroll).
// Production/audited quality (see the F-1..F-5 fixes in MinesFactory.sol).
// Snapshot of the mines-poc repo — study the patterns; not kept in lockstep with source.
// See references/games/archetypes.md (#1) and patterns.md.
// ─────────────────────────────────────────────────────────────────────────────
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ebool, e, inco, elist, ETypes} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";
import {MinesMath} from "./MinesMath.sol";

interface IMinesFactory {
    function payoutPlayer(address player, uint256 amount) external;
    function playerLost(address player) external;
    function isGameExpired(address contractAddress) external view returns (bool);
    function getTimeRemaining(address contractAddress) external view returns (uint256);
    function updateGameState(address player, string calldata state, bytes calldata data) external;
}

contract Mines {
    using e for *;

    uint256 public immutable boardSize;
    uint256 public immutable totalBombs;
    uint256 public immutable betAmount;
    address public immutable player;
    address public immutable factory;
    address public immutable beneficiary;

    uint256 public constant SCALE = MinesMath.SCALE;

    elist   private board;
    ebool   private everHitBomb;
    bytes32 public  latestAccumHandle;
    uint256[] public openedTiles;
    // Packed into one slot with `_entered` (4 bytes total).
    bool    public boardReady;
    bool    public hasLost;
    bool    public hasCashedOut;
    // OZ-style reentrancy guard: avoid the 0↔1 SSTORE pattern (saves ~19k gas/call).
    // Set to NOT_ENTERED (=1) in constructor so first call only pays warm-slot cost.
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;
    uint8 private _entered;

    event GameCreated(address indexed player, uint256 betAmount);
    event BoardInitialized();
    event PickRevealed(uint256 indexed pos, bytes32 hitHandle, bytes32 accumHandle);
    event BombHit(uint256 indexed pos);
    event PlayerCashedOut(uint256 amount);

    modifier nonReentrant() {
        require(_entered != _ENTERED, "reentrant");
        _entered = _ENTERED;
        _;
        _entered = _NOT_ENTERED;
    }

    modifier gameActive() {
        require(!hasLost, "lost");
        require(!hasCashedOut, "cashed");
        require(!IMinesFactory(factory).isGameExpired(address(this)), "expired");
        _;
    }

    constructor(
        uint256 size,
        uint256 bombs,
        address _factory,
        address _player,
        uint256 _betAmount,
        address _beneficiary
    ) {
        require(size > 0 && bombs > 0 && bombs < size * size, "invalid setup");
        require(size * size <= type(uint16).max, "board too large");
        require(_betAmount > 0, "bet=0");
        require(_player != address(0), "player zero");
        require(_factory != address(0), "factory zero");
        require(_beneficiary != address(0), "beneficiary zero"); // closes silent burn-on-cashout footgun
        boardSize = size;
        totalBombs = bombs;
        betAmount = _betAmount;
        player = _player;
        factory = _factory;
        beneficiary = _beneficiary;
        _entered = _NOT_ENTERED; // pre-warm reentrancy slot
        emit GameCreated(_player, _betAmount);
    }

    function calculateMultiplier(
        uint256 safeCount,
        uint256 mines,
        uint256 total
    ) public pure returns (uint256) {
        return MinesMath.calculateMultiplier(safeCount, mines, total);
    }

    function getCurrentMultiplier() public view returns (uint256) {
        return MinesMath.calculateMultiplier(openedTiles.length, totalBombs, boardSize * boardSize);
    }

    function getPotentialWinnings() external view returns (uint256) {
        return MinesMath.calculateWinnings(
            betAmount,
            openedTiles.length,
            totalBombs,
            boardSize * boardSize
        );
    }

    /// @notice Factory-only initialization. Bundled atomically inside
    /// `MinesFactory.createMinesContract` so `boardReady` is true before any
    /// other caller can reach this contract.
    function initBoard() external payable {
        require(!boardReady, "already initialized");
        require(msg.sender == factory, "only factory"); // dead `player` branch removed
        require(msg.value >= inco.getFee(), "fee");

        uint256 totalTiles = boardSize * boardSize;
        uint256 safeTiles = totalTiles - totalBombs;
        bytes32[] memory bombHandles = new bytes32[](totalBombs);
        bytes32[] memory safeHandles = new bytes32[](safeTiles);
        bytes32 trueHandle  = ebool.unwrap(e.asEbool(true));
        bytes32 falseHandle = ebool.unwrap(e.asEbool(false));
        for (uint256 i = 0; i < totalBombs; i++) {
            bombHandles[i] = trueHandle;
        }
        for (uint256 i = 0; i < safeTiles; i++) {
            safeHandles[i] = falseHandle;
        }

        elist bombs    = e.newEList(bombHandles, ETypes.Bool);
        elist safes    = e.newEList(safeHandles, ETypes.Bool);
        elist combined = e.concat(bombs, safes);
        board = e.shuffle(combined);
        inco.allow(elist.unwrap(board), address(this));

        // Allow contract cross-tx access to the accumulator (we'll OR into it
        // every pickTile). Skip the initial reveal — cashOut requires
        // `openedTiles.length > 0`, so this trivially-known `false` is never
        // attested against. The first pickTile reveals the post-OR handle.
        everHitBomb = e.asEbool(false);
        e.allow(everHitBomb, address(this));
        latestAccumHandle = ebool.unwrap(everHitBomb);

        boardReady = true;
        emit BoardInitialized();
    }

    function _isOpened(uint256 pos) internal view returns (bool) {
        for (uint256 i = 0; i < openedTiles.length; i++) {
            if (openedTiles[i] == pos) return true;
        }
        return false;
    }

    /// @notice Open a tile. NOT payable — none of the encrypted ops we use
    /// here charge an Inco fee (only `eRand`/`listShuffle` do, neither of
    /// which `pickTile` calls). Caller pays gas only.
    function pickTile(uint256 pos) external gameActive nonReentrant {
        require(msg.sender == player, "only player");
        require(boardReady, "not ready");
        require(pos < boardSize * boardSize, "out of bounds");
        require(!_isOpened(pos), "already opened");

        // `hit` is a memory-only handle used within this tx — Inco grants
        // transient access automatically; no e.allow needed.
        ebool hit = e.getEbool(board, uint16(pos));
        e.reveal(hit);

        // `everHitBomb` IS stored across txs (we OR into it every pick), so
        // it still needs cross-tx allow + reveal for the cashout attestation.
        everHitBomb = e.or(everHitBomb, hit);
        e.allow(everHitBomb, address(this));
        e.reveal(everHitBomb);
        latestAccumHandle = ebool.unwrap(everHitBomb);

        openedTiles.push(pos);
        emit PickRevealed(pos, ebool.unwrap(hit), latestAccumHandle);

        IMinesFactory(factory).updateGameState(player, "tile_clicked", abi.encode(pos));
    }

    function cashOut(
        DecryptionAttestation calldata accumAttestation,
        bytes[] calldata signatures
    ) external gameActive nonReentrant {
        require(msg.sender == player, "only player");
        require(openedTiles.length > 0, "need a pick");
        require(accumAttestation.handle == latestAccumHandle, "stale attestation");
        require(
            inco.incoVerifier().isValidDecryptionAttestation(accumAttestation, signatures),
            "bad sig"
        );
        require(asBool(accumAttestation.value) == false, "hit a bomb");

        hasCashedOut = true;
        uint256 winnings = MinesMath.calculateWinnings(
            betAmount,
            openedTiles.length,
            totalBombs,
            boardSize * boardSize
        );

        IMinesFactory(factory).updateGameState(player, "cashing_out", abi.encode(winnings));
        IMinesFactory(factory).payoutPlayer(beneficiary, winnings);
        emit PlayerCashedOut(winnings);
    }

    function concedeLoss(
        DecryptionAttestation calldata accumAttestation,
        bytes[] calldata signatures
    ) external gameActive nonReentrant {
        require(msg.sender == player, "only player");
        require(openedTiles.length > 0, "need a pick");
        require(accumAttestation.handle == latestAccumHandle, "stale attestation");
        require(
            inco.incoVerifier().isValidDecryptionAttestation(accumAttestation, signatures),
            "bad sig"
        );
        require(asBool(accumAttestation.value) == true, "not a bomb");

        hasLost = true;
        inco.reveal(elist.unwrap(board));
        IMinesFactory(factory).playerLost(player);
        emit BombHit(openedTiles[openedTiles.length - 1]);
    }

    // ── Views ─────────────────────────────────────────────────
    function getBoardHandle() external view returns (bytes32) {
        return elist.unwrap(board);
    }

    function getOpenedTiles() external view returns (uint256[] memory) {
        return openedTiles;
    }

    function getGameInfo()
        external
        view
        returns (
            address gamePlayer,
            uint256 size,
            uint256 bombs,
            uint256 bet,
            bool initialized,
            bool ended
        )
    {
        gamePlayer = player;
        size = boardSize;
        bombs = totalBombs;
        bet = betAmount;
        initialized = boardReady;
        ended = hasLost || hasCashedOut || IMinesFactory(factory).isGameExpired(address(this));
    }

    function isGameExpired() external view returns (bool) {
        return IMinesFactory(factory).isGameExpired(address(this));
    }

    function getTimeRemaining() external view returns (uint256) {
        return IMinesFactory(factory).getTimeRemaining(address(this));
    }
}
