# Inco Solidity Reference

## Table of Contents
- [Imports and Setup](#imports-and-setup)
- [Encrypted Types](#encrypted-types)
- [Creating Encrypted Values](#creating-encrypted-values)
- [Math Operations](#math-operations)
- [Comparison Operations](#comparison-operations)
- [Random Number Generation](#random-number-generation)
- [Type Conversions](#type-conversions)
- [Access Control](#access-control)
- [Control Flow (Multiplexer Pattern)](#control-flow-multiplexer-pattern)
- [Reveal (Public Decryption)](#reveal-public-decryption)
- [Fee Payment](#fee-payment)
- [Attestation Verification](#attestation-verification)
- [Best Practices](#best-practices)
- [EList](#elist)

---

## Imports and Setup

```solidity
// Core import - all you need to get started
import {euint256, ebool, eaddress, e, inco} from "@inco/lightning/src/Lib.sol";

contract MyContract {
    using e for *;
    // Or be specific:
    // using e for euint256;
    // using e for ebool;
    // using e for uint256;
    // using e for bytes;
    // using e for address;
}
```

For attestation verification:
```solidity
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";
```

For testing (Foundry):
```solidity
import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
```

For EList (built into the core library in v1):
```solidity
import {euint256, ebool, e, inco, elist, ETypes} from "@inco/lightning/src/Lib.sol";
```

---

## Encrypted Types

All encrypted types are `bytes32` handles - unique identifiers for immutable encrypted data stored off-chain.

| Type | Underlying | Description |
|------|-----------|-------------|
| `euint256` | `bytes32` | Encrypted 256-bit unsigned integer |
| `ebool` | `bytes32` | Encrypted boolean |
| `eaddress` | `bytes32` | Encrypted address |

```solidity
// Storage examples
mapping(address => euint256) public balanceOf;
mapping(address => mapping(address => euint256)) internal allowances;
euint256 internal _totalSupply;
ebool internal _isActive;
```

---

## Creating Encrypted Values

### From off-chain input (user-submitted ciphertext)

```solidity
// euint256 from encrypted bytes (requires fee)
function deposit(bytes memory encryptedAmount) external payable {
    require(msg.value >= inco.getFee() * 1, "Fee not paid");
    euint256 amount = encryptedAmount.newEuint256(msg.sender);
}

// ebool from encrypted bytes
function setFlag(bytes memory flagInput) external payable {
    require(msg.value >= inco.getFee() * 1, "Fee not paid");
    ebool flag = flagInput.newEbool(msg.sender);
}

// eaddress from encrypted bytes
function setAddr(bytes memory addrInput) external payable {
    require(msg.value >= inco.getFee() * 1, "Fee not paid");
    eaddress addr = addrInput.newEaddress(msg.sender);
}
```

IMPORTANT: The second parameter to `newEuint256/newEbool/newEaddress` MUST be the account that created the ciphertext (typically `msg.sender`). Passing another address is a malicious implementation.

### From known values (trivial encrypt)

```solidity
euint256 zero = e.asEuint256(0);
euint256 amount = uint256(1000 * 1e9).asEuint256();
ebool flag = e.asEbool(true);
eaddress addr = e.asEaddress(0x1234...);
```

Note: Anyone can see the initial value of a trivially encrypted handle on-chain. After operations, values become hidden.

---

## Math Operations

All binary operations accept `euint256` or `uint256` as either argument. All return `euint256`.

```solidity
euint256 a = e.asEuint256(10);
euint256 b = e.asEuint256(3);

euint256 sum = a.add(b);        // 13
euint256 diff = a.sub(b);       // 7
euint256 prod = a.mul(b);       // 30
euint256 quot = a.div(b);       // 3
euint256 rem = a.rem(b);        // 1

// Bitwise
euint256 andResult = a.and(b);
euint256 orResult = a.or(b);
euint256 xorResult = a.xor(b);
euint256 shrResult = a.shr(b);  // shift right
euint256 shlResult = a.shl(b);  // shift left
euint256 rotrResult = a.rotr(b); // rotate right
euint256 rotlResult = a.rotl(b); // rotate left

// With plaintext scalar
euint256 doubled = a.mul(2);
euint256 half = a.div(2);
```

---

## Comparison Operations

Return `ebool` (except min/max which return `euint256`).

```solidity
ebool isEqual = a.eq(b);
ebool isNotEqual = a.ne(b);
ebool isGte = a.ge(b);    // >=
ebool isGt = a.gt(b);     // >
ebool isLte = a.le(b);    // <=
ebool isLt = a.lt(b);     // <

euint256 minimum = a.min(b);
euint256 maximum = a.max(b);

// Negation
ebool notFlag = flag.not();

// Address comparison
ebool sameAddr = encAddr1.eq(encAddr2);
ebool diffAddr = encAddr1.ne(encAddr2);

// Ebool logic
ebool result = bool1.and(bool2);
ebool result = bool1.or(bool2);
ebool result = bool1.xor(bool2);
```

---

## Random Number Generation

```solidity
euint256 randomNumber = e.rand();                        // Full range
euint256 bounded = e.randBounded(100);                   // [0, 100)
euint256 boundedEnc = e.randBounded(encryptedUpperBound); // Encrypted bound
```

---

## Type Conversions

```solidity
// Plaintext -> encrypted
euint256 a = e.asEuint256(42);
ebool b = e.asEbool(true);
eaddress c = e.asEaddress(0x123...);

// Cross-cast between encrypted types
ebool d = e.asEbool(someEuint256);   // euint256 -> ebool
euint256 f = e.asEuint256(someEbool); // ebool -> euint256
```

---

## Access Control

CRITICAL: After any operation that creates a new handle, you MUST grant access or the handle becomes permanently inaccessible.

```solidity
// Grant permanent access to a specific address
newBalance.allow(userAddress);

// Grant access to the current contract (ESSENTIAL for future computations)
newBalance.allowThis(); // alias for allow(address(this))

// Check if an address has access
require(msg.sender.isAllowed(value), "unauthorized handle access");
```

### Key Rules

1. **Always `allowThis()` after updating state**: If a variable will be used in future transactions, the contract must retain access.
2. **Always `allow(user)` for values the user needs to see**: Users can only decrypt handles they have access to.
3. **Handles are immutable**: Sharing access grants access only to the current value. New operations create new handles requiring new access grants.
4. **Transient allowance**: Results of operations like `e.add()` are transiently allowed to the calling contract within the same transaction. But `allowThis()` is still needed for persistence across transactions.
5. **Access is irreversible**: Once granted, access cannot be revoked. The recipient can share it further or publicly decrypt.

### Complete Pattern

```solidity
function _transfer(address to, euint256 value) internal returns (ebool success) {
    success = balanceOf[msg.sender].ge(value);
    euint256 transferredValue = success.select(value, uint256(0).asEuint256());

    euint256 senderNew = balanceOf[msg.sender].sub(transferredValue);
    euint256 receiverNew = balanceOf[to].add(transferredValue);

    balanceOf[msg.sender] = senderNew;
    balanceOf[to] = receiverNew;

    // Access control - ALL of these are required
    senderNew.allow(msg.sender);   // sender sees new balance
    receiverNew.allow(to);          // receiver sees new balance
    senderNew.allowThis();          // contract can use in future
    receiverNew.allowThis();        // contract can use in future
    success.allow(msg.sender);      // caller sees if transfer succeeded
}
```

---

## Control Flow (Multiplexer Pattern)

You CANNOT use `if/else` or `revert` with encrypted conditions - the execution path would leak information.

Instead, use `select`:

```solidity
// e.select(condition, valueIfTrue, valueIfFalse)
euint256 result = isEnough.select(amount, e.asEuint256(0));
```

### Common Pattern: Silent Failure

```solidity
function _transfer(address to, euint256 value) internal returns (ebool success) {
    success = balanceOf[msg.sender].ge(value);
    // If insufficient: transfers 0 instead of reverting
    euint256 transferredValue = success.select(value, uint256(0).asEuint256());
    // ... proceed with transfer logic
}
```

---

## Reveal (Public Decryption)

Makes an encrypted value publicly decryptable by anyone. IRREVERSIBLE.

```solidity
e.reveal(encryptedUint);
e.reveal(encryptedBool);
e.reveal(encryptedAddress);
```

After `e.reveal()`, anyone can call `attestedReveal` from the JS SDK without needing `e.allow()`.

---

## Fee Payment

Every encrypted input (`newEuint256`, `newEbool`, `newEaddress`) requires a fee per ciphertext consumed.

```solidity
// Single ciphertext
require(msg.value >= inco.getFee() * 1, "Fee not paid");

// Multiple ciphertexts
require(msg.value >= inco.getFee() * ciphertextCount, "Fee not paid");

// Helper pattern
function _requireFee() internal view {
    if (msg.value < inco.getFee()) revert InsufficientFees();
}
```

### Who pays: pay-per-call vs sponsor

The fee is forwarded from the **contract's balance** — the `Lib` wrappers run `inco.newEuint256{value: inco.getFee()}(ciphertext, user)` (and `eRand`/`eRandBounded` likewise). Since `{value: …}` spends `address(this).balance` regardless of where that ETH came from, you have two strategies:

- **Pay-per-call (user pays).** Make the function `payable` and `require(msg.value >= inco.getFee() * n)`; the user's ETH lands in the contract and is forwarded on. Optional `Fee` modifiers enforce/refund it: `paying` (`require(msg.value == FEE)`), `payingMultiple(n)`, `refundUnspent`.
- **Sponsor (pre-fund the contract).** Fund the contract with ETH ahead of time; each op draws `inco.getFee()` from the existing balance. The function **need not be `payable`** and the caller pays nothing for fees — a paymaster-style "gasless-for-fees" UX. There is no sponsor primitive; "pre-funded" just means the contract holds ETH.

**Notes.** A sponsoring contract must stay funded or fee-charging ops revert — top it up and gate withdrawals so the reserve can't be drained. `FEE` is `0.000001 ether` today but may change via upgrades, so always read `inco.getFee()` — never hardcode. Only ciphertext *ingestion* (`newE*`) and *randomness* (`rand`/`randBounded`/`shuffle`) charge a fee; compute on existing handles (`add`/`eq`/`select`/`getEbool`/`reveal`) is free.

---

## Attestation Verification

For verifying decryption proofs submitted on-chain:

```solidity
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {inco, ebool, euint256} from "@inco/lightning/src/Lib.sol";
import {asBool} from "@inco/lightning/src/shared/TypeUtils.sol";

function verifyAndUse(
    DecryptionAttestation memory decryption,
    bytes[] memory signatures
) external {
    // 1. Verify covalidator signatures
    require(
        inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures),
        "Invalid signature"
    );

    // 2. ALWAYS verify the handle matches what you expect
    require(
        euint256.unwrap(expectedHandle) == decryption.handle,
        "Handle mismatch"
    );

    // 3. Use the decrypted value
    uint256 value = uint256(decryption.value);
    // OR for booleans:
    bool flag = asBool(decryption.value);
}
```

### Attested Compute Verification

For results of off-chain computation (e.g., `creditScore >= 700`):

```solidity
function submitCreditCheck(
    DecryptionAttestation memory decryption,
    bytes[] memory signatures
) external {
    require(
        inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures),
        "Invalid signature"
    );

    // Recompute the expected handle ON-CHAIN
    require(
        ebool.unwrap(e.ge(userCreditScore[msg.sender], 700)) == decryption.handle,
        "Computed handle mismatch"
    );

    require(asBool(decryption.value) == true, "Credit check failed");
    // proceed
}
```

---

## Best Practices

### 1. Dual Function Pattern for User-Facing Functions
```solidity
// For EOAs: accepts encrypted bytes
function transfer(address to, bytes memory valueInput) external payable returns (ebool) {
    require(msg.value >= inco.getFee(), "Fee not paid");
    euint256 value = valueInput.newEuint256(msg.sender);
    return _transfer(to, value);
}

// For contracts: accepts existing euint256
function transfer(address to, euint256 value) public returns (ebool success) {
    require(msg.sender.isAllowed(value), "unauthorized handle access");
    return _transfer(to, value);
}
```

### 2. Always Check Handle Access on Contract-Facing Functions
```solidity
require(msg.sender.isAllowed(value), "unauthorized value handle access");
```

### 3. Think About Information Leakage
- Public price + private swap amount = deducible amount
- Continuously updated highest bidder = deducible highest bid
- Execution path differences leak data

### 4. Be Careful with delegatecall
A delegatecalled contract can decrypt any ciphertext your contract holds.

### 5. Always Verify Handles in Attestations
Signature verification alone is NOT enough. Always check `decryption.handle` matches the expected handle.

### 6. Use 9 Decimals for Confidential Tokens
Standard is GWEI (1e9) not WAD (1e18) for confidential fungible tokens.

---

## EList

Encrypted dynamic lists. As of v1 these are built into the core library (no separate `-preview` package), and every operation is on the `e` namespace. Import:
```solidity
import {euint256, ebool, e, inco, elist, ETypes} from "@inco/lightning/src/Lib.sol";
```

See [elist-reference.md](elist-reference.md) for the full EList API.
