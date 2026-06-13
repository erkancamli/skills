# Deployment & Testing Reference

## Table of Contents
- [Project Setup](#project-setup)
- [Foundry Setup](#foundry-setup)
- [Hardhat Setup](#hardhat-setup)
- [Local Development (Docker)](#local-development-docker)
- [Testnet Deployment (Base Sepolia)](#testnet-deployment-base-sepolia)
- [Foundry Testing](#foundry-testing)
- [Hardhat Testing](#hardhat-testing)
- [Scaffolding with create-inco-app](#scaffolding-with-create-inco-app)

---

## Project Setup

### Dependencies (npm/bun)

```bash
# Core Inco Solidity library (EList is built in as of v1)
bun add @inco/lightning@latest

# Frontend JS SDK (renamed from @inco/js in v1)
bun add @inco/lightning-js@latest

# Other common deps
bun add @openzeppelin/contracts
```

### Solidity Version
```
solc = "0.8.30"
evm_version = "cancun"
```

---

## Foundry Setup

### Recommended: Use lightning-rod template
```bash
git clone git@github.com:Inco-fhevm/lightning-rod.git
cd lightning-rod
bun install
```

### Manual Setup

1. Install dependencies:
```bash
bun add @inco/lightning@latest https://github.com/dapphub/ds-test https://github.com/foundry-rs/forge-std @openzeppelin/contracts
```

2. Create `remappings.txt`:
```
@openzeppelin/=../node_modules/@openzeppelin/
forge-std/=../node_modules/forge-std/src/
ds-test/=../node_modules/ds-test/src/
@inco/=../node_modules/@inco/
```

3. `foundry.toml`:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["node_modules", "../node_modules"]
solc = "0.8.30"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
```

---

## Hardhat Setup

### hardhat.config.ts
```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.30",
    settings: {
      evmVersion: "cancun",
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    anvil: {
      url: "http://localhost:8545",
      chainId: 31337,
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      accounts: process.env.PRIVATE_KEY_BASE_SEPOLIA
        ? [process.env.PRIVATE_KEY_BASE_SEPOLIA]
        : [],
    },
    // Inco is also live on Base mainnet (real ETH). Frontend uses Lightning.baseMainnet().
    base: {
      url: process.env.BASE_MAINNET_RPC_URL || "https://mainnet.base.org",
      accounts: process.env.PRIVATE_KEY_BASE
        ? [process.env.PRIVATE_KEY_BASE]
        : [],
    },
  },
};

export default config;
```

---

## Local Development (Docker)

Both Foundry and Hardhat templates use the same Docker setup:

### docker-compose.yaml
```yaml
# v1 local node — the `mainnet` pepper images match the canonical executor in
# @inco/lightning/src/Lib.sol. Init the SDK against them with Lightning.localNode("mainnet").
services:
  anvil:
    image: inconetwork/local-node-anvil-mainnet:v1.0.0
    ports:
      - "8545:8545"

  covalidator:
    image: inconetwork/local-node-covalidator-mainnet:v1.0.0
    depends_on:
      anvil:
        condition: service_healthy
    ports:
      - "50055:50055"
```

### Commands
```bash
# Start local node + covalidator
docker compose up -d

# Stop
docker compose down

# Check logs
docker compose logs -f
```

- Anvil node: `http://localhost:8545` (chain ID: 31337)
- Covalidator: `localhost:50055`

### Default Anvil Credentials
```
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SEED_PHRASE="test test test test test test test test test test test junk"
```

---

## Testnet Deployment (Base Sepolia)

### Environment Variables
```bash
# .env
PRIVATE_KEY_BASE_SEPOLIA=0x...your_key...
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
```

### Foundry Deploy
```bash
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY_BASE_SEPOLIA
```

### Hardhat Deploy (with Ignition)
```bash
npx hardhat ignition deploy ignition/modules/Deploy.ts --network baseSepolia
```

### Frontend Environment
```bash
# frontend/.env.local
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=your_id
NEXT_PUBLIC_CONFLOTTERY_ADDRESS=0x...deployed_address...
```

---

## Foundry Testing

Foundry tests use `IncoTest` which mocks the entire Inco infrastructure locally - NO Docker required.

```solidity
import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
import {inco, euint256, e} from "@inco/lightning/src/Lib.sol";
import {GWEI} from "@inco/lightning/src/shared/TypeUtils.sol";

contract MyTest is IncoTest {
    function setUp() public override {
        super.setUp(); // REQUIRED: deploys mocked Inco
        // ... deploy your contracts
        vm.deal(address(this), inco.getFee());
    }

    function testBasic() public {
        // Create encrypted input for testing
        bytes memory encryptedAmount = fakePrepareEuint256Ciphertext(
            100 * GWEI,  // plaintext value
            alice,       // who created it
            address(myContract) // target contract
        );

        // Call contract with fee
        vm.deal(alice, inco.getFee());
        vm.prank(alice);
        myContract.deposit{value: inco.getFee()}(encryptedAmount);

        // Process all pending encrypted operations
        processAllOperations();

        // Read and decrypt values for assertions
        uint256 balance = getUint256Value(myContract.balanceOf(alice));
        assertEq(balance, 100 * GWEI);

        bool flag = getBoolValue(myContract.someFlag());
        assertTrue(flag);
    }

    // Test attestation flow
    function testAttestation() public {
        // Get the handle
        euint256 handle = myContract.someEncryptedValue();

        // Create mock attestation
        (DecryptionAttestation memory attestation, bytes[] memory sigs)
            = getDecryptionAttestation(alice, handle);

        // Submit on-chain
        vm.prank(alice);
        myContract.submitDecryption(attestation, sigs);
    }
}
```

### Key IncoTest Cheatcodes

| Function | Description |
|----------|-------------|
| `processAllOperations()` | Process all pending encrypted operations |
| `fakePrepareEuint256Ciphertext(value, sender, contract)` | Create test ciphertext |
| `getUint256Value(euint256)` | Decrypt euint256 for assertions |
| `getBoolValue(ebool)` | Decrypt ebool for assertions |
| `getDecryptionAttestation(user, handle)` | Create mock attestation + signatures |

Run tests:
```bash
forge test -vvv
```

---

## Hardhat Testing

Hardhat tests use the real Lightning SDK and require Docker for the local node + covalidator.

```typescript
import { expect } from "chai";
import hre from "hardhat";
import { Lightning } from "@inco/lightning-js/lite";
import { handleTypes } from "@inco/lightning-js";

describe("MyContract", function () {
  let contract: any;
  let zap: any;

  before(async function () {
    // Initialize Lightning SDK
    const chainId = hre.network.config.chainId;
    if (chainId === 31337) {
      zap = await Lightning.localNode("mainnet");
    } else {
      zap = await Lightning.baseSepoliaTestnet();
    }

    // Deploy contract
    contract = await hre.viem.deployContract("MyContract", [], {
      value: await getFee(),
    });
  });

  it("should encrypt and deposit", async function () {
    const [deployer] = await hre.viem.getWalletClients();

    // Encrypt value
    const encrypted = await zap.encrypt(100n * 10n ** 9n, {
      accountAddress: deployer.account.address,
      dappAddress: contract.address,
      handleType: handleTypes.euint256,
    });

    const fee = await getFee();
    await contract.write.deposit([encrypted], { value: fee });

    // Wait for covalidator to process
    await new Promise(resolve => setTimeout(resolve, 3000));
  });

  async function getFee() {
    const publicClient = await hre.viem.getPublicClient();
    return await publicClient.readContract({
      address: zap.executorAddress,
      abi: [{ inputs: [], name: "getFee", outputs: [{ type: "uint256" }], stateMutability: "pure", type: "function" }],
      functionName: "getFee",
    });
  }
});
```

### Decrypt with Retry (Covalidator Latency)

The covalidator processes ciphertexts asynchronously, so a freshly-produced handle may 404 if read immediately. Use the SDK's built-in backoff — don't hand-roll a polling loop:

```typescript
const [result] = await zap.attestedDecrypt(walletClient, [handle], {
  backoffConfig: { maxRetries: 12, baseDelayInMs: 350, backoffFactor: 1.4 },
});
const value = result.plaintext.value;
```

Run tests:
```bash
# Start local node first
docker compose up -d

# Run against local node
npx hardhat test --network anvil

# Run against testnet
npx hardhat test --network baseSepolia
```

---

## Scaffolding with create-inco-app

```bash
# Interactive (prompts for template, chain, framework, wallet)
npx create-inco-app my-app

# Non-interactive — EVM monorepo with Hardhat + RainbowKit
npx create-inco-app my-app --chain evm --framework hardhat --wallet rainbowkit --git --install
```

**Flags:** `-t/--template <monorepo|contracts|frontend>` (default `monorepo`), `-c/--chain <evm|svm>`, `-f/--framework <hardhat|foundry|anchor>`, `-w/--wallet <rainbowkit|privy|dynamic|reown|para>`, `-y/--yes`, `--git`, `--install`, `--use-npm|--use-pnpm|--use-yarn|--use-bun`.

- **Templates:** `monorepo` (contracts + frontend, default), `contracts` (contracts only), `frontend` (Next.js dApp only).
- **Wallets (EVM):** rainbowkit (recommended), privy, dynamic, reown, para.
- **Frameworks (EVM):** hardhat (recommended), foundry. (`anchor` is the Solana/SVM path — `create-inco-app` also scaffolds SVM via `--chain svm --framework anchor`, but this skill covers the EVM / Inco Lightning path.)

The EVM monorepo ships `contracts/` (Hardhat or Foundry; `ConfidentialERC20.sol` + `ConfidentialLottery.sol`, tests, Ignition deploy) and `frontend/` (Next.js 15 + Tailwind, the chosen wallet, pre-wired Inco helpers). It targets **Base Sepolia by default**, switchable to Base mainnet via `NEXT_PUBLIC_NETWORK`.

### Workspace scripts (EVM)

```bash
npm run dev                      # frontend dev server
npm run contracts:compile        # compile contracts
npm run contracts:test           # run contract tests
npm run contracts:node           # local Inco node (anvil + covalidator)
npm run contracts:deploy:local   # deploy to local node
npm run contracts:deploy:testnet # deploy to Base Sepolia
npm run contracts:deploy:mainnet # deploy to Base mainnet
```

Deploy keys live in `contracts/.env` per chain (`PRIVATE_KEY_ANVIL` / `PRIVATE_KEY_BASE_SEPOLIA` / `PRIVATE_KEY_BASE`); `deploy:token:*` variants deploy only the token. For a scaffolded project, `npm run contracts:node` replaces the manual docker-compose in [Local Development](#local-development-docker).
