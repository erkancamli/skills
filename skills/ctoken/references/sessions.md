# cToken Sessions

Sign once, then read balances with no popups.

## Why sessions

Decrypting a balance needs the account's authorization. Without sessions that is a wallet popup on every read. With a session the user signs one voucher, and a throwaway key held in memory decrypts on their behalf until it expires. The SDK handles this: the first read asks for a signature, everything after is silent.

## Scoping

The voucher names a verifier contract that decides what the session can reach. `CTokenSessionVerifier`, the SDK default, narrows a session to cToken balances. A leaked session key exposes those and nothing else. A generic `SessionVerifier` also exists and covers everything the signer can read; prefer the scoped one for anything user-facing.

The SDK handles all of this. It only matters if you drive `@inco/lightning-js` yourself:

```ts
const ephemeral = privateKeyToAccount(generatePrivateKey());

// Empty erc20Tokens: one signature covers future tokens too.
const sharerArgData = encodeAbiParameters(
  [{ type: "tuple", components: [
    { name: "decrypter", type: "address" },
    { name: "expiresAt", type: "uint256" },
    { name: "erc20Tokens", type: "address[]" },
  ]}],
  [{ decrypter: ephemeral.address, expiresAt, erc20Tokens: [] }],
);
const voucher = await zap.grantCustomSessionKeyAllowanceVoucher(
  walletClient, CTOKEN_SESSION_VERIFIER, sharerArgData,
);

// Each decrypt names the underlying ERC-20 (USDC for cUSDC).
const requesterArgData = encodeAbiParameters(
  [{ type: "tuple", components: [{ name: "erc20Tokens", type: "address[]" }] }],
  [{ erc20Tokens: [usdc] }],
);
const results = await zap.attestedDecryptWithVoucher(
  ephemeral, voucher, [handle], { requesterArgData },
);
```

Omit `requesterArgData` against this verifier and the covalidator answers `PermissionDenied: advanced acl disallowed`. The session is valid, but nothing is in scope.

## Safe and smart accounts

Sessions work for ERC-1271 accounts. The voucher signature is checked on-chain, so a Safe signs through its normal signed-message flow and everything downstream just works. One rule: smart-account users must go through sessions. Direct decrypts only accept EOA signatures.

## Timing

Ciphertexts settle asynchronously after a transaction lands. A decrypt right after a transfer can briefly answer "not found, try again". The SDK retries automatically, and `balancesSettled` marks such tokens `pending` instead of failing.
