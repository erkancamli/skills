# EList Reference

Encrypted dynamic lists for confidential applications.

> **v1:** EList graduated from the separate `@inco/lightning-preview` package **into the core `@inco/lightning` library** (1.0.0). There is no `-preview` package and no `Preview.Lib.sol` anymore — `elist`, `ETypes`, and all list operations live on the standard `e` namespace in `@inco/lightning/src/Lib.sol`.

## Setup

### Dependencies

EList ships in the core library — no separate package. Just install (or update) `@inco/lightning`:
```bash
npm install @inco/lightning@latest
# or: bun add @inco/lightning@latest
```

### Import
```solidity
import {euint256, ebool, e, inco, elist, ETypes} from "@inco/lightning/src/Lib.sol";

using e for *; // enables both e.append(list, ...) and list.append(...) styles
```

All operations are called on the `e` namespace (e.g. `e.newEList(...)`, `e.append(...)`). With `using e for *;` the method-call style (`myList.append(...)`, `myList.allowThis()`) works too.

## Key Concepts

- `elist` handles are IMMUTABLE - operations return new handles
- List length is ALWAYS PUBLIC (encoded in the handle)
- Element types: `ETypes.Uint256` or `ETypes.Bool`
- Most operations require fee payment and access control

## Access Control Pattern
```solidity
// After any elist operation, grant access (elist has its own allow/allowThis/reveal):
e.allow(myList, address(this)); // or: myList.allowThis();
e.allow(myList, msg.sender);
// Make every element publicly readable (no wallet auth needed):
e.reveal(myList);
```

## Operations

### Create Empty
```solidity
elist myList = e.newEList(ETypes.Uint256);
```

### Create from Handles
```solidity
bytes32[] memory handles = new bytes32[](3);
handles[0] = euint256.unwrap(e.asEuint256(10));
handles[1] = euint256.unwrap(e.asEuint256(20));
handles[2] = euint256.unwrap(e.asEuint256(30));
elist myList = e.newEList(handles, ETypes.Uint256);
```

### Create from User Inputs
```solidity
function createFromInputs(bytes[] memory inputs) public payable returns (elist) {
    require(msg.value >= inco.getFee() * inputs.length, "Fee not paid");
    elist list = e.newEList(inputs, ETypes.Uint256, msg.sender);
    e.allow(list, address(this));
    e.allow(list, msg.sender);
    return list;
}
```

### Length & Type
```solidity
uint16 len = e.length(myList);        // Public, no fee
ETypes t = e.listTypeOf(myList);       // View function
```

### Append
```solidity
elist newList = e.append(myList, e.asEuint256(42));
```

### Insert (at hidden or plaintext index)
```solidity
elist inserted = e.insert(myList, uint16(0), e.asEuint256(5));
// Or with an encrypted (hidden) index:
elist inserted = e.insert(myList, encryptedIndex, e.asEuint256(5));
```

### Get (plaintext index)
```solidity
euint256 val = e.getEuint256(myList, 0);
ebool flag = e.getEbool(boolList, 0);
```

### GetOr (hidden index with default)
```solidity
euint256 val = e.getOr(myList, encryptedIndex, defaultValue);
```

### Set (replace at index)
```solidity
elist updated = e.set(myList, encryptedIndex, newValue);
// Out-of-range index = append
```

### Concat
```solidity
elist combined = e.concat(listA, listB);
```

### Slice (plaintext bounds)
```solidity
elist sliced = e.slice(myList, 1, 3); // [start, end)
```

### SliceLen (hidden start, fixed length)
```solidity
elist sliced = e.sliceLen(myList, encryptedStart, 2, defaultValue);
```

### Range
```solidity
elist ordered = e.range(0, 5); // E([0,1,2,3,4])
```

### Reverse
```solidity
elist reversed = e.reverse(myList);
```

### Shuffle (requires fee)
```solidity
function shuffleList() public payable returns (elist) {
    require(msg.value >= inco.getFee() * e.length(myList), "Fee not paid");
    elist shuffled = e.shuffle(myList);
    e.allow(shuffled, address(this));
    return shuffled;
}
```

### ShuffledRange (requires fee)
```solidity
// v1: shuffledRange takes the element type as a third argument
elist deck = e.shuffledRange(1, 53, ETypes.Uint256); // Shuffled card deck
```

## Fees

EList fees scale with element count and element bitwidth:

```
fee = element_count × bitwidth × (0.000001 / 256) ETH
```

For a `Uint256` list (bitwidth 256) this works out to `element_count × inco.getFee()`, so `require(msg.value >= inco.getFee() * count)` is the right user-pays check; `Bool` lists are cheaper. The library auto-attaches the precise fee (`inco.getEListFee(count, listType)`) drawn from the contract balance, so a contract-sponsored model just needs the contract pre-funded. `get()`/`getOr()`/`length()` are free.
