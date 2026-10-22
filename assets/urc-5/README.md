# URC-5 reference implementation

This example pairs an ERC-20 token with a Uniswap v4 hook. The hook reports the
negative of each operation's final caller token delta. The token keeps one signed
transient balance and consumes it when tokens move to or from PoolManager.
Positive balances cover deposits; negative balances cover payouts.

`IVenuePolicy.sol` is the proposed interface. `VenueGatedToken.sol` adds an
illustrative owner-controlled policy and settlement gate. `CanonicalFlowHook.sol`
reports swaps, liquidity changes and donations for exact registered pool keys.
The token remains in `Enforced` mode and rejects both directions for one configured
external venue.

## Run the tests

Use Foundry 1.5.1 or later. From this directory, install these pinned dependencies:

```sh
forge install --root "$PWD" --no-git v4-core=Uniswap/v4-core@rev=e50237c43811bd9b526eff40f26772152a42daba
forge install --root "$PWD" --no-git openzeppelin-contracts=OpenZeppelin/openzeppelin-contracts@rev=c64a1edb67b6e3f4a15cca8909c9482ad33a02b0
forge install --root "$PWD" --no-git forge-std=foundry-rs/forge-std@rev=bf647bd6046f2f7da30d0c2bf435e5c76a780c1b
forge test --root "$PWD" -vv
```

These revisions are v4-core v4.0.0, OpenZeppelin Contracts v5.4.0 and forge-std
v1.16.2. Foundry downloads Solidity 0.8.26 and 0.8.30 when needed. The unmodified
v4.0.0 PoolManager requires 0.8.26; the reference uses native transient variables
and the integration test pins 0.8.30. `test/PoolManagerArtifact.sol` compiles the
manager separately, and the test deploys its real bytecode. The EVM target is
Cancun. Installed dependencies and generated artifacts stay in this directory
and are ignored by Git.

The test hook is deployed at an address with the required permission bits using
Foundry's `deployCodeTo`. A normal deployment must select a hook address with
those bits, bind it to the token, then register the exact pool key before pool
initialization. The hook binding cannot be changed.

## What the tests cover

The suite uses an actual v4 PoolManager for:

- Canonical buys and sells with exact input and exact output, liquidity additions
  and withdrawals, and donations.
- Refused copycat deposits and payouts, and a canonical round trip that cannot
  leave independent inbound and outbound allowances.
- Exact-key registration, unauthorized callbacks and reports, owner permissions,
  ERC-165, event snapshots, ordinary transfers and allowance rollback on refusal.
- Hook return deltas, accrued LP fees counted once, and initial liquidity with an
  empty manager.
- Retirement that rejects new token inputs but retains withdrawals and other
  outbound operations.
- Net-zero routes, ERC-6909 claim minting and burning, `clear`, multiple unlocks,
  pre-settlement, opposite-sign leftovers, and protocol-fee collection.

The fixture supplies a pre-existing copycat pool by impersonating the trusted
hook once during setup. This models liquidity already present in an undeclared
pool; the scenario tests do not use that privilege. The manager is empty before
the first canonical liquidity deposit. One external-venue test seeds a balance
to isolate the outbound refusal.

## Limits demonstrated by the example

The signed balance authorizes token settlement across the whole transaction. It
does not identify the pool responsible for each transfer or guarantee every pool
on a route is canonical. Net-zero operations need no token transfer. Claim
minting, burning and `clear` can leave flow available for a later transfer,
including a copycat payout. The tests demonstrate this directly. Flow remains
available across multiple unlocks in the same transaction; the EVM clears the
transient balance at transaction end. Opposite-sign leftovers can make a later
canonical operation fail closed.

Transfers between the bound hook and PoolManager are exempt so the hook can take
its fee. The hook is trusted accounting code and exposes no hook-initiated pool
operations; v4 skips callbacks for such self-initiated operations. Do not add such
operations without accounting for that behavior. Protocol fees can leave a locked
manager without flow authorization. Collection during an unlock still needs
sufficient outbound flow and can revert.

The optional fee is an illustrative output fee, not a general tax: swaps charge
only a positive unspecified-currency output, and liquidity operations charge only
a positive net token output. Exact-output swaps and initial liquidity deposits
therefore do not incur this hook fee. The hook includes its returned delta in the
reported flow; LP fees already present in the caller delta are not added again.

These tests establish the example's stated behavior. They are not an exhaustive
security audit or a recommendation to deploy this code unchanged.
