# EList Reference (Preview)

Encrypted dynamic lists for confidential applications.

> Preview feature - experimental, may have breaking changes. Not for production.

## Setup

### Dependencies
```json
{
  "dependencies": {
    "@inco/lightning-preview": "0.7.10",
    "@inco/lightning": "0.7.10"
  },
  "overrides": {
    "@inco/lightning": "0.7.10"
  }
}
```

### Import
```solidity
import {ePreview, elist, ETypes} from "@inco/lightning-preview/src/Preview.Lib.sol";
import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
```

## Key Concepts

- `elist` handles are IMMUTABLE - operations return new handles
- List length is ALWAYS PUBLIC (encoded in handle)
- Element types: `ETypes.Uint256` or `ETypes.Bool`
- Most operations require fee payment and access control

## Access Control Pattern
```solidity
// After any elist operation, grant access:
inco.allow(elist.unwrap(myList), address(this));
inco.allow(elist.unwrap(myList), msg.sender);
```

## Operations

### Create Empty
```solidity
elist myList = ePreview.newEList(ETypes.Uint256);
```

### Create from Handles
```solidity
bytes32[] memory handles = new bytes32[](3);
handles[0] = euint256.unwrap(e.asEuint256(10));
handles[1] = euint256.unwrap(e.asEuint256(20));
handles[2] = euint256.unwrap(e.asEuint256(30));
elist myList = ePreview.newEList(handles, ETypes.Uint256);
```

### Create from User Inputs
```solidity
function createFromInputs(bytes[] memory inputs) public payable returns (elist) {
    require(msg.value >= inco.getFee() * inputs.length, "Fee not paid");
    elist list = ePreview.newEList(inputs, ETypes.Uint256, msg.sender);
    inco.allow(elist.unwrap(list), address(this));
    inco.allow(elist.unwrap(list), msg.sender);
    return list;
}
```

### Length & Type
```solidity
uint16 len = ePreview.length(myList);        // Public, no gas
ETypes t = ePreview.listTypeOf(myList);       // View function
```

### Append
```solidity
elist newList = ePreview.append(myList, e.asEuint256(42));
```

### Insert (at hidden or plaintext index)
```solidity
elist inserted = ePreview.insert(myList, uint256(0), e.asEuint256(5));
// Or with encrypted index:
elist inserted = ePreview.insert(myList, encryptedIndex, e.asEuint256(5));
```

### Get (plaintext index)
```solidity
euint256 val = ePreview.getEuint256(myList, 0);
ebool flag = ePreview.getEbool(boolList, 0);
```

### GetOr (hidden index with default)
```solidity
euint256 val = ePreview.getOr(myList, encryptedIndex, defaultValue);
```

### Set (replace at index)
```solidity
elist updated = ePreview.set(myList, encryptedIndex, newValue);
// Out-of-range index = append
```

### Concat
```solidity
elist combined = ePreview.concat(listA, listB);
```

### Slice (plaintext bounds)
```solidity
elist sliced = ePreview.slice(myList, 1, 3); // [start, end)
```

### SliceLen (hidden start, fixed length)
```solidity
elist sliced = ePreview.sliceLen(myList, encryptedStart, 2, defaultValue);
```

### Range
```solidity
elist ordered = ePreview.range(0, 5); // E([0,1,2,3,4])
```

### Reverse
```solidity
elist reversed = ePreview.reverse(myList);
```

### Shuffle (requires fee)
```solidity
function shuffleList() public payable returns (elist) {
    require(msg.value >= inco.getFee(), "Fee not paid");
    elist shuffled = ePreview.shuffle(myList);
    inco.allow(elist.unwrap(shuffled), address(this));
    return shuffled;
}
```

### ShuffledRange (requires fee)
```solidity
elist deck = ePreview.shuffledRange(1, 53); // Shuffled card deck
```
