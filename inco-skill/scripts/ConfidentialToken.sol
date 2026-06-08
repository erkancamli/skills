// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";

/// @notice A fungible token with confidential balances and transfer amounts.
/// Uses 9 decimals (GWEI standard for confidential tokens).
contract ConfidentialToken {
    using e for *;

    mapping(address => euint256) public balanceOf;
    mapping(address => mapping(address => euint256)) internal allowances;
    address public owner;

    error InsufficientFees();

    constructor() {
        owner = msg.sender;
        // Mint 1000 tokens to deployer (9 decimals = GWEI)
        balanceOf[msg.sender] = uint256(1000 * 1e9).asEuint256();
    }

    // ─── Mint ───────────────────────────────────────────────

    /// @notice Mint encrypted amount to caller (requires fee for ciphertext input)
    function encryptedMint(bytes memory encryptedAmount) external payable {
        _requireFee();
        euint256 amount = encryptedAmount.newEuint256(msg.sender);
        euint256 newBalance = balanceOf[msg.sender].add(amount);
        balanceOf[msg.sender] = newBalance;
        newBalance.allow(msg.sender);
        newBalance.allowThis();
    }

    // ─── Transfer ───────────────────────────────────────────

    /// @notice Transfer for EOAs - accepts encrypted bytes from JS SDK
    function transfer(address to, bytes memory valueInput) external payable returns (ebool) {
        _requireFee();
        euint256 value = valueInput.newEuint256(msg.sender);
        return _transfer(msg.sender, to, value);
    }

    /// @notice Transfer for contracts - accepts existing euint256 handle
    function transfer(address to, euint256 value) public returns (ebool success) {
        require(msg.sender.isAllowed(value), "unauthorized value handle access");
        return _transfer(msg.sender, to, value);
    }

    // ─── Approve ────────────────────────────────────────────

    /// @notice Approve for EOAs
    function approve(address spender, bytes memory valueInput) external payable returns (bool) {
        _requireFee();
        euint256 value = valueInput.newEuint256(msg.sender);
        return _approve(msg.sender, spender, value);
    }

    /// @notice Approve for contracts
    function approve(address spender, euint256 value) public returns (bool) {
        require(msg.sender.isAllowed(value), "unauthorized value handle access");
        return _approve(msg.sender, spender, value);
    }

    // ─── TransferFrom ───────────────────────────────────────

    /// @notice TransferFrom for EOAs
    function transferFrom(address from, address to, bytes memory valueInput) external payable returns (ebool) {
        _requireFee();
        euint256 value = valueInput.newEuint256(msg.sender);
        return _transferFrom(from, to, value);
    }

    /// @notice TransferFrom for contracts
    function transferFrom(address from, address to, euint256 value) public returns (ebool success) {
        require(msg.sender.isAllowed(value), "unauthorized value handle access");
        return _transferFrom(from, to, value);
    }

    // ─── Internal ───────────────────────────────────────────

    function _transfer(address from, address to, euint256 value) internal returns (ebool success) {
        // Check balance >= value (encrypted comparison)
        success = balanceOf[from].ge(value);
        // Multiplexer pattern: transfer value if sufficient, 0 otherwise
        euint256 transferredValue = success.select(value, uint256(0).asEuint256());

        euint256 senderNewBalance = balanceOf[from].sub(transferredValue);
        euint256 receiverNewBalance = balanceOf[to].add(transferredValue);

        balanceOf[from] = senderNewBalance;
        balanceOf[to] = receiverNewBalance;

        // Grant access to see new balances
        senderNewBalance.allow(from);
        receiverNewBalance.allow(to);
        // Grant contract access for future operations
        senderNewBalance.allowThis();
        receiverNewBalance.allowThis();
        // Let caller know if transfer succeeded
        success.allow(from);
    }

    function _approve(address tokenOwner, address spender, euint256 value) internal returns (bool) {
        allowances[tokenOwner][spender] = value;
        value.allow(tokenOwner);
        value.allow(spender);
        value.allowThis();
        return true;
    }

    function _transferFrom(address from, address to, euint256 value) internal returns (ebool success) {
        euint256 currentAllowance = allowances[from][msg.sender];
        ebool hasAllowance = currentAllowance.ge(value);
        ebool hasBalance = balanceOf[from].ge(value);
        success = hasAllowance.and(hasBalance);

        euint256 transferredValue = success.select(value, uint256(0).asEuint256());

        // Update balances
        euint256 senderNewBalance = balanceOf[from].sub(transferredValue);
        euint256 receiverNewBalance = balanceOf[to].add(transferredValue);
        euint256 newAllowance = currentAllowance.sub(transferredValue);

        balanceOf[from] = senderNewBalance;
        balanceOf[to] = receiverNewBalance;
        allowances[from][msg.sender] = newAllowance;

        // Access control
        senderNewBalance.allow(from);
        receiverNewBalance.allow(to);
        newAllowance.allow(from);
        newAllowance.allow(msg.sender);
        senderNewBalance.allowThis();
        receiverNewBalance.allowThis();
        newAllowance.allowThis();
        success.allow(msg.sender);
    }

    function _requireFee() internal view {
        if (msg.value < inco.getFee()) revert InsufficientFees();
    }
}
