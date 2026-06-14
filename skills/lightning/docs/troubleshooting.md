# Troubleshooting Guide

Common issues when building with Inco on EVM.

## Smart Contract Issues

### "Fee Not Paid" revert
**Cause**: Functions consuming encrypted inputs require `msg.value >= inco.getFee()` per ciphertext.

**Fix**:
```solidity
// Single ciphertext
require(msg.value >= inco.getFee(), "Fee not paid");

// Multiple ciphertexts (e.g., 2 inputs)
require(msg.value >= inco.getFee() * 2, "Fee not paid");
```
Frontend must pass fee as `value`:
```typescript
const fee = await getFee();
writeContract({ ..., value: fee });
```

### Contract can't compute over stored values
**Cause**: Missing `allowThis()` after updating encrypted state.

**Fix**: Always call `allowThis()` after storing a new handle:
```solidity
balanceOf[msg.sender] = newBalance;
newBalance.allowThis(); // Contract retains access for future txs
```

### User can't decrypt their value
**Cause**: Missing `allow(userAddress)` for the handle.

**Fix**: Grant access after creating/updating:
```solidity
newBalance.allow(msg.sender);
```

### Handle returns 0 / default value after `newEuint256`
**Cause**: Malformed ciphertext or wrong sender address passed to `newEuint256`.

**Fix**:
- Ensure the second parameter matches who created the ciphertext: `encryptedInput.newEuint256(msg.sender)`
- Ensure the frontend encrypts with the correct `accountAddress` and `dappAddress`
- The JS SDK embeds context (account, chain, contract) in the ciphertext - reusing across contexts produces default values

### "unauthorized value handle access" revert
**Cause**: Calling the `euint256`-parameter version of a function without access to the handle.

**Fix**: The caller must have had `e.allow(handle, callerAddress)` called previously:
```solidity
function transfer(address to, euint256 value) public {
    require(msg.sender.isAllowed(value), "unauthorized");
    // ...
}
```

### `e.select` not working as expected
**Cause**: Using `if/else` or `require` with encrypted conditions instead of `select`.

**Fix**: You CANNOT use `if/else` or `revert` based on encrypted booleans:
```solidity
// WRONG - leaks information through execution path
if (getBoolValue(condition)) { ... }

// CORRECT - multiplexer pattern
euint256 result = condition.select(valueIfTrue, valueIfFalse);
```

---

## Frontend / JS SDK Issues

### "attestedDecrypt" fails or times out
**Cause**: Covalidator hasn't processed the ciphertext yet. This is common immediately after a transaction.

**Fix**: Use the SDK's built-in backoff — don't hand-roll a polling loop:
```typescript
const [result] = await zap.attestedDecrypt(walletClient, [handle], {
  backoffConfig: { maxRetries: 12, baseDelayInMs: 350, backoffFactor: 1.4 },
});
return result.plaintext.value;
```

### Encryption returns unexpected ciphertext
**Cause**: Wrong `handleType` or mismatched `accountAddress`/`dappAddress`.

**Fix**: Ensure parameters match exactly:
```typescript
const ct = await zap.encrypt(amount, {
  accountAddress: userWalletAddress,  // Must match msg.sender on-chain
  dappAddress: targetContractAddress, // Must match the contract receiving it
  handleType: handleTypes.euint256,   // Must match the Solidity type
});
```

### SDK init (`Lightning.baseSepoliaTestnet()` / `localNode()`) fails
**Cause**: Network connectivity, or the wrong network factory for the chain. v1 adds explicit per-network factories (recommended over the still-supported `Lightning.latest("testnet", chainId)`). Inco is live on Base Sepolia and Base mainnet.

**Fix**:
```typescript
// Base Sepolia testnet (chain 84532)
const zap = await Lightning.baseSepoliaTestnet();

// Base mainnet (real ETH)
const zap = await Lightning.baseMainnet();

// Local development (anvil + covalidator docker) — pass the network "pepper"
const zap = await Lightning.localNode("mainnet");
```
For local: ensure Docker containers are running (`docker compose up -d`).

### Handle hex formatting issues (`InvalidBytesLengthError`, reveals/attestations fail)
**Cause**: Calling `toHex()` on a handle that is **already a hex string**. `toHex("0xabc…")` treats the string as text and re-encodes it character-by-character, producing a value far longer than 32 bytes → `pad` throws `InvalidBytesLengthError` (or the attestation/reveal silently fails on a wrong handle).

**The rule**: only `toHex()` a handle when it is a **numeric** value (`bigint`/`number`, e.g. an ABI `uint256`). Handles that already arrive as `0x…` strings — **from event logs / `getLogs` args**, or contract reads typed `bytes32` — must be padded **without** `toHex`.

**Fix**:
```typescript
import { pad, toHex } from "viem";

// Handle from an event/log — ALREADY a hex string. Do NOT toHex it.
const handleHex = pad(rawEventHandle, { size: 32 });

// Handle read as a numeric uint256 — convert first.
const handleHex = pad(toHex(numericHandle), { size: 32 });

// toHex is for numeric *attestation/plaintext values*, never for already-hex handles:
const encodedValue = pad(toHex(result.plaintext.value), { size: 32 });
```
Not sure of the type? `typeof handle === "bigint"` → use `toHex`; a `0x…` string → pad as-is.

### Attestation signatures rejected on-chain
**Cause**: Handle mismatch - the attestation is for a different handle than expected.

**Fix**: Always verify handle matches on-chain:
```solidity
require(euint256.unwrap(expectedHandle) == decryption.handle, "Handle mismatch");
```
Ensure you're reading the correct handle from the contract before requesting attestation.

---

## Docker / Local Node Issues

### Docker containers fail to start
**Fix**: Ensure ports 8545 and 50055 are free:
```bash
lsof -i :8545
lsof -i :50055
# Kill any conflicting processes

docker compose down
docker compose up -d
```

### Tests fail with "covalidator not ready"
**Cause**: Covalidator needs a few seconds after container start.

**Fix**: Wait for both services:
```bash
docker compose up -d
sleep 5  # Wait for covalidator to initialize
npx hardhat test --network anvil
```

### Local node transactions have wrong chain ID
**Fix**: Use chain ID 31337 for local anvil node:
```typescript
// Hardhat config
anvil: {
  url: "http://localhost:8545",
  chainId: 31337,
}
```

---

## Foundry Testing Issues

### Tests fail after `setUp`
**Cause**: Missing `super.setUp()` call.

**Fix**: Always call parent setUp:
```solidity
function setUp() public override {
    super.setUp(); // Deploys mocked Inco infrastructure
    // ... your setup
}
```

### `processAllOperations()` not resolving values
**Cause**: Call it after any transaction that creates/modifies encrypted values:
```solidity
myContract.deposit{value: inco.getFee()}(encryptedAmount);
processAllOperations(); // Process encrypted ops before reading results
uint256 balance = getUint256Value(myContract.balanceOf(alice));
```

### `fakePrepareEuint256Ciphertext` returns wrong values
**Fix**: Parameters must match what the contract expects:
```solidity
bytes memory ct = fakePrepareEuint256Ciphertext(
    100 * GWEI,          // plaintext value
    alice,               // who created it (msg.sender in contract)
    address(myContract)  // target contract (dappAddress)
);
```

---

## Deployment Issues

### Contract deployment reverts on Base Sepolia
**Cause**: Constructor may require fee payment for operations like `e.rand()`.

**Fix**: Deploy with value:
```bash
forge create src/MyContract.sol:MyContract --value 0.001ether --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

### Remappings not resolving `@inco/lightning`
**Fix**: Ensure remappings.txt points to node_modules:
```
@inco/=../node_modules/@inco/
```
Note: Point to `@inco/` not `@inco/lightning/`.

### Hardhat compilation fails with "cancun" EVM
**Fix**: Ensure Solidity 0.8.30+ and cancun EVM version:
```typescript
solidity: {
  version: "0.8.30",
  settings: { evmVersion: "cancun" },
}
```
