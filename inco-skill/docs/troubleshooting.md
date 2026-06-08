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

**Fix**: Implement retry logic with delays:
```typescript
for (let i = 0; i < 10; i++) {
  try {
    const results = await zap.attestedDecrypt(walletClient, [handle]);
    return results[0].plaintext.value;
  } catch {
    await new Promise(r => setTimeout(r, 3000)); // Wait 3s
  }
}
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

### `Lightning.latest()` fails
**Cause**: Network connectivity or wrong parameters.

**Fix**:
```typescript
// Testnet (Base Sepolia)
const zap = await Lightning.latest("testnet", 84532);

// Local development
const zap = await Lightning.localNode();
```
For local: ensure Docker containers are running (`docker compose up -d`).

### Handle hex formatting issues
**Cause**: Handles from contract reads need padding to 32 bytes.

**Fix**:
```typescript
import { pad, toHex } from "viem";

const rawHandle = await publicClient.readContract({ ... });
const handleHex = pad(toHex(rawHandle), { size: 32 });
```

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
