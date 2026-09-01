---
name: ctoken
description: >
  Build with Inco's Confidential Token (cToken): wrap any ERC-20 into a token with private balances
  and private transfer amounts, on Base and Base Sepolia. Covers the @inco/ctoken SDK's three layers
  (core CTokenClient, React hooks, drop-in UI kit), sessions (sign once, silent balance reads), the
  public indexer REST API (tokens, wallets, history, prices), Safe / ERC-1271 smart accounts, and the
  v1 contract addresses (WrapperFactory, CommonVault, CTokenSessionVerifier).
  TRIGGER: imports "@inco/ctoken", mentions cToken, confidential token, private ERC-20 balances,
  wrap/unwrap into a confidential token, confidential transfer/send, ctoken.inco.org,
  api.ctoken.inco.org, ConfidentialWallet widget, useBalances/useDeposit/useConfidentialSend hooks.
  NOT for: writing new confidential Solidity contracts from scratch (use the lightning skill),
  ZK proofs.
---

# Inco Confidential Token (cToken)

cToken turns any ERC-20 into a confidential token. Balances and transfer amounts are encrypted, only the holder can read them, and the token still moves on-chain like any other. This skill covers **integrating** cToken v1 with the shipped `@inco/ctoken` SDK and the public indexer API. To write your own confidential contracts, reach for the **lightning** skill instead.

**IMPORTANT: Inco is TEE-based, not FHE.** "Encrypted" means decrypt-in-TEE with attestation, not homomorphic encryption. Never describe cToken as FHE.

## Architecture (30-second overview)

| Piece | Job |
|---|---|
| WrapperFactory | Deploys one cToken per ERC-20 |
| cToken | The confidential token itself: wrap, transfer, unwrap |
| CommonVault | Holds the underlying ERC-20 backing the wrapped supply |
| Indexer | Serves wallets, history, and prices to apps |

**Wrap** — approve the cToken, call `wrap(to, amount)`; your ERC-20 goes into the vault, you get an encrypted balance. **Send** — amounts travel encrypted; the tx pays a small ciphertext fee, overpayment refunded. **Unwrap** — prove you have enough with an attestation, burn confidentially, get the underlying back. **Read** — balances live on-chain as `bytes32` handles, decrypted off-chain, usually through a session.

## Networks and addresses

| Network | `network` | Indexer | App |
|---|---|---|---|
| Base | `base` | `https://api.ctoken.inco.org/api` | [ctoken.inco.org](https://ctoken.inco.org) |
| Base Sepolia | `baseSepolia` | `https://api.ctoken.testnet.inco.org/api` | [ctoken.testnet.inco.org](https://ctoken.testnet.inco.org) |

v1 uses the **same addresses on Base and Base Sepolia**, and the SDK ships them — name a network and nothing else:

| Contract | Address |
|---|---|
| `WrapperFactory` | `0x6f9a0ECD77C3Dade8Dc14a507cAbABFD746575f8` |
| `CommonVault` | `0x35A38eFec618cD1924CBf4FB84bE187323Fa7E55` |
| `CTokenSessionVerifier` | `0x8D762303c41F822D3f38f8CE0f0fD1855d602c2A` |

Testing on Base Sepolia? Get USDC from the official [Circle faucet](https://faucet.circle.com/).

Try everything without writing code: the [live playground](https://ctoken-tze4f72wfa-ew.a.run.app/) runs every widget and hook on the published SDK.

## Install and pick a layer

```bash
npm install @inco/ctoken
```

Built on `viem` and `@inco/lightning-js`. React and the UI kit are optional, the core works anywhere JavaScript runs.

| Layer | Import | Use it when |
|---|---|---|
| Core | `@inco/ctoken` | You want raw APIs and full control |
| React hooks | `@inco/ctoken/react` | You have your own UI |
| UI kit | `@inco/ctoken/ui` | You want working widgets today |

## Core client

```ts
import { CTokenClient } from "@inco/ctoken";

const client = CTokenClient.browser({
  network: "base", // or "baseSepolia"
  walletClient,
  indexerUrl: "https://api.ctoken.inco.org/api",
});

await client.deposit({ token: usdc, amount: "100" });           // wrap
await client.confidentialSend({ token: usdc, to, amount: "25" });
await client.withdraw({ token: usdc, amount: "10" });           // unwrap

const balances = await client.balancesSettled({ tokens: [usdc] });
// { value: 65, pending: false }, or pending: true while the
// ciphertext is still being processed. One slow token never
// breaks the rest.

const history = await client.history({ page: 1 });
const prices = await client.prices([usdc]);
```

**Node.js** — same client for scripts and backends. Node signs with the key directly, so reads need no session and no popups:

```ts
const ctoken = CTokenClient.node({
  network: "base",
  privateKey: process.env.PRIVATE_KEY,
  indexerUrl: "https://api.ctoken.inco.org/api",
});

await ctoken.deposit({ token: usdc, amount: "1" });
console.log(await ctoken.balanceOf({ token: usdc }));
```

Running your own deployment? Pass `contracts` and `sessionVerifier` to override the built-in addresses.

## React hooks

Wrap your app once, then every hook just works:

```tsx
import { CTokenProvider } from "@inco/ctoken/react";

<CTokenProvider network="base" indexerUrl="https://api.ctoken.inco.org/api">
  <App />
</CTokenProvider>
```

```tsx
import { useBalances, useDeposit, useConfidentialSend } from "@inco/ctoken/react";

const { data: balances } = useBalances({ tokens: [usdc] });
const { mutate: deposit, isPending } = useDeposit();
const { mutate: send } = useConfidentialSend();
```

Available hooks: `useCToken`, `useTokens`, `useResolvedTokens`, `useAssets`, `useBalances`, `useBalance`, `usePublicBalance`, `useDeposit`, `useApprove`, `useWithdraw`, `useConfidentialSend`, `useDecrypt`, `useHistory`, `useChainGuard`. They sit on wagmi and react-query, so caching, retries, and wallet state come for free.

## UI kit

```tsx
import { ConfidentialWallet } from "@inco/ctoken/ui";
import "@inco/ctoken/ui/styles.css";

<ConfidentialWallet />
```

`ConfidentialWallet` is the full experience: portfolio, shield, unshield, send, history. Or compose the pieces: `DepositWidget`, `WithdrawWidget`, `SendWidget`, `BalanceCard`, `PortfolioCard`, `HistoryList`.

## Sessions: sign once, read silently

Reading a confidential balance means decrypting it, and decryption needs the account's authorization. With a session the user signs one voucher, and a throwaway key held in memory decrypts on their behalf until it expires. The SDK handles this: the first read asks for a signature, everything after is silent.

The default `CTokenSessionVerifier` narrows a session to cToken balances, so a leaked session key exposes token balances and nothing else. Prefer it over the generic `SessionVerifier` for anything user-facing. See `references/sessions.md` for driving `@inco/lightning-js` vouchers yourself.

**Smart accounts:** Safe and other ERC-1271 accounts work end to end — wrapping, sending, and reading balances through sessions. One rule: smart-account users **must** go through sessions; direct decrypts without a voucher only accept EOA signatures.

## Timing, errors, retries

- Ciphertexts are processed **asynchronously** after a transaction lands. A decrypt right after a transfer can briefly answer "not found, try again". The SDK retries automatically, and `balancesSettled` marks such tokens `pending` instead of failing — show a spinner and read again shortly.
- Indexer reads retry transient failures with backoff and honor `Retry-After`. Balance decrypts isolate failures per handle. Everything throws typed `CTokenError`s with stable codes.

## Indexer REST API

Open to play with — fair-use rate limits per IP, and localhost origins always work in the browser. Full endpoint table and semantics in `references/indexer-api.md`.

```bash
curl https://api.ctoken.inco.org/api/tokens
```

Shipping to production? Request origin whitelisting for guaranteed access and a heads-up before breaking changes: [whitelist form](https://docs.google.com/forms/d/e/1FAIpQLSe_lJoMc203TEgdQlL6PhPywG2EW3jdWIOo6QwvoBK0n1QCJQ/viewform?usp=header).

## Red flags — STOP if you catch yourself thinking:

| Thought | Reality |
|---------|---------|
| "I'll read the balance right after the transfer confirms" | Ciphertexts settle asynchronously. Use `balancesSettled` and respect `pending`. |
| "This Safe user can decrypt directly, skip sessions" | Direct decrypts only accept EOA signatures. Smart accounts go through sessions, always. |
| "I'll parse the encrypted amount from the indexer" | The indexer only ever serves `bytes32` handles. Plaintext confidential amounts don't exist off-chain. |
| "I'll hardcode contract addresses" | The SDK ships v1 addresses — pass `network` and nothing else. Override only for your own deployment. |
| "cToken uses FHE" | It's TEE-based decrypt-with-attestation. Say TEE, not FHE. |

## Docs

- Overview: https://docs.inco.org/ctoken/overview
- SDK: https://docs.inco.org/ctoken/sdk
- Sessions: https://docs.inco.org/ctoken/sessions
- Indexer API: https://docs.inco.org/ctoken/indexer-api
