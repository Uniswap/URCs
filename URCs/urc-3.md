---
urc: 3
title: Hook TVL and Effective Liquidity Reporting
author: Mark Toda (@MarkToda), Daniel Gretzke (@gretzke), Alice Henshaw (@hensha256), Chris Cashwell (@ccashwell)
status: Draft
created: 2026-06-11
---

## Abstract

This URC defines `IHookStats`, a read-only interface through which Uniswap v4 hooks report TVL and immediately swappable liquidity.

## Motivation

Uniswap v4 custom accounting allows hooks to replace, augment, or reduce the core AMM swap calculation. This enables hooks that wrap assets, route to external venues, deploy active liquidity, use vaults, rehypothecate reserves, settle through off-pool balances, or implement custom liquidity mechanisms.

DEX interfaces and routers need a standard way to discover hook TVL and immediately swappable liquidity. PoolManager events may not capture liquidity deployed through external protocols, vaults, ERC-6909 claims, JIT strategies, or other custom mechanisms.

## Specification

The key words “MUST”, “MUST NOT”, “SHOULD”, “SHOULD NOT”, “MAY”, and “OPTIONAL” are to be interpreted as normative requirements.

### Scope

This URC applies to Uniswap v4 hooks that use custom accounting and want to expose standardized TVL and liquidity data.

A custom-accounting hook is a hook that computes swap accounting using hook-specific logic rather than relying solely on the core concentrated-liquidity AMM swap calculation.

Conformance is based on externally observable behavior: emitted events, implemented interfaces, return values, and documented semantics.

### HookStats Interface

`IHookStats` standardizes how hooks report total TVL and immediately swappable liquidity.

Hook builders SHOULD implement `IHookStats` if PoolManager state and events do not fully describe the hook’s TVL or usable liquidity.

This is especially important for hooks that:

- Deploy liquidity in external protocols.
- Use vaults or lending markets.
- Rehypothecate assets.
- Use JIT or active liquidity strategies.
- Maintain reserves outside the PoolManager.
- Hold wrapped assets or ERC-6909 claims.
- Implement custom liquidity mechanisms not visible through PoolManager events.

### Interface

```solidity
interface IHookStats {
    /// @notice Total reserves managed by the hook for a pool.
    /// @param key The pool key for the specific pool.
    /// @return token0 Total token0 reserves.
    /// @return token1 Total token1 reserves.
    function getReserves(PoolKey calldata key)
        external
        view
        returns (uint256 token0, uint256 token1);

    /// @notice Assets available for immediate swapping.
    /// @param key The pool key for the specific pool.
    /// @return token0 Immediately swappable token0 liquidity.
    /// @return token1 Immediately swappable token1 liquidity.
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        returns (uint256 token0, uint256 token1);

    /// @notice The hook whose stats this contract reports.
    /// @return The hook address, or the contract's own address when the
    ///         hook implements the interface directly.
    function hook() external view returns (address);
}
```

### Implementation Options

A hook MAY implement `IHookStats` directly on the hook contract.

A hook MAY instead use a separate stats contract that implements `IHookStats`.

A separate stats contract is useful when:

- The hook is already deployed or audited.
- TVL calculations are complex.
- The stats implementation needs to be upgradeable.
- The hook author wants to keep read-only accounting logic separate from swap execution logic.

When a separate stats contract is used, integrations need a way to discover the stats contract for a given hook or pool, for example through a registry or metadata process. The `hook` function makes a candidate stats contract self-describing, so integrators can verify it against a pool's hook.

When the hook does not implement `IHookStats` itself, its stats MAY come from a separate contract whose link to the hook is self-reported. By default, integrators SHOULD treat the most recently deployed `IHookStats` contract that points to the hook and shares the hook's deployer as canonical.

### `getReserves`

`getReserves` reports total reserves managed by the hook for the specified pool.

The returned values SHOULD include all assets under management that economically correspond to the pool’s token0 and token1, including:

- ERC-20 balances.
- ERC-6909 claims.
- Vault deposits.
- External protocol deployments.
- Time-locked funds.
- Rehypothecated assets.
- Wrapped assets.
- Staked or lent assets.
- Redeemable claims controlled by the hook.

The returned values SHOULD be denominated in the pool’s token0 and token1 units.

If the values are not direct token balances, the hook or stats contract MUST document the accounting basis. For example, reported reserves may represent redeemable value, marked value, claim value, or estimated value.

For a valid pool with no hook-managed reserves, `getReserves` SHOULD return `(0, 0)`.

For a pool key that does not belong to the hook or stats contract, `getReserves` SHOULD revert with a descriptive error.

### `getEffectiveLiquidity`

`getEffectiveLiquidity` reports the amount of token0 and token1 liquidity that can be accessed immediately for swapping.

Effective liquidity may be lower than total reserves when some assets are:

- Time-locked.
- Deployed in a vault.
- Subject to utilization limits.
- Awaiting settlement.
- Not immediately withdrawable.
- Reserved for other obligations.
- Otherwise unavailable for immediate swap execution.

For each token, `getEffectiveLiquidity` SHOULD be less than or equal to `getReserves`.

If all reserves are immediately swappable, `getEffectiveLiquidity` MAY return the same values as `getReserves`.

For a valid pool with no immediately swappable hook-managed liquidity, `getEffectiveLiquidity` SHOULD return `(0, 0)`.

For a pool key that does not belong to the hook or stats contract, `getEffectiveLiquidity` SHOULD revert with a descriptive error.

### `hook`

`hook` returns the address of the hook whose stats the contract reports.

A hook that implements `IHookStats` directly MUST return its own address.

A separate stats contract MUST return the address of the hook it reports for.

When the stats provider's address equals the pool's hook address (`key.hooks`), the association between the hook and its stats is authoritative. For separate stats contracts, the returned value is self-reported, and integrators can use it to verify a candidate stats contract against a pool's hook before use.

### Use by Routers and Interfaces

DEX interfaces MAY use `getReserves` for TVL display.

Routers MAY use `getEffectiveLiquidity` as an input to route scoring, pool visibility, or routeability decisions.

`getEffectiveLiquidity` is not a binding quote. Routers MUST use quotes, simulations, slippage checks, or execution constraints to determine whether a swap should actually be executed.

### ERC-165 Interface Detection

A hook or stats contract that implements `IHookStats` MUST implement [ERC-165](https://eips.ethereum.org/EIPS/eip-165).

`supportsInterface` MUST return `true` for `type(IHookStats).interfaceId` and for the ERC-165 interface ID itself (`0x01ffc9a7`).

### Conformance

A hook or stats contract conforms to this URC if it:

1. Implements `IHookStats`.
2. Reports total reserves through `getReserves`.
3. Reports immediately swappable liquidity through `getEffectiveLiquidity`.
4. Reports the hook it serves through `hook`, returning its own address when the hook implements `IHookStats` directly.
5. Returns values denominated in token0 and token1 units, or documents any different accounting basis.
6. Reverts with a descriptive error for pool keys that do not belong to it.
7. Ensures effective liquidity is less than or equal to total reserves for each token.
8. Implements ERC-165 and reports support for `IHookStats` through `supportsInterface`.

## Rationale

### Separate HookStats Interface

`IHookStats` is a standalone read-only interface because TVL reporting and router quoting are related but distinct responsibilities.

Some hooks need TVL reporting even if they do not expose quotes.

Some hooks expose quotes but need a separate stats contract because the hook is already deployed, audited, non-upgradeable, or intentionally minimal.

Keeping `IHookStats` separate allows existing hooks to adopt TVL reporting without forcing all stats logic into the hook contract.

### Total Reserves vs Effective Liquidity

Total TVL is not always the same as immediately swappable liquidity.

A hook may manage significant reserves, but some assets may be deployed externally, time-locked, subject to utilization limits, or otherwise unavailable for immediate settlement.

`getReserves` reports total managed liquidity.

`getEffectiveLiquidity` reports liquidity that is available right now for trading.

Routers and DEX interfaces benefit from both values.

### ERC-165 Interface Detection

Requiring ERC-165 gives integrators a uniform, on-chain way to check for `IHookStats` support without `try`/`catch` probing of typed calls. Because stats may be served either by the hook itself or by a separate stats contract, interface detection on the hook also distinguishes the two deployment models: if the hook does not report support, integrators know to discover a stats contract through a registry or metadata process.

### Hook Pointer

Every stats provider reports the hook it serves through the mandatory `hook` function. A mandatory function keeps the interface uniform: integrators query the same interface regardless of whether stats are served by the hook itself or by a separate contract, and a hook implementing the interface directly simply returns its own address.

The pointer also gives integrators a built-in trust distinction. Stats served by the hook itself are authoritative by construction, because the provider address equals the pool's hook address. Stats served by a separate contract carry a self-reported pointer that integrators can verify against the hook deployer or a registry.

Resolving by deployer and recency lets integrators identify a hook's stats automatically in the common case — a hook author deploying an updated stats contract from the same account — while explicit designation through a registry remains available.

## Backwards Compatibility

This URC does not require changes to Uniswap v4 core.

Existing hooks remain functional even if they do not implement `IHookStats`.

The separate stats contract option allows audited or non-upgradeable hooks to participate in TVL reporting without changing the hook contract itself.

## Test Cases

### Equal Reserves and Effective Liquidity

A hook that keeps all reserves immediately available for swapping may return the same values from both functions:

```solidity
getReserves(key) = (1_000e18, 2_000e18);
getEffectiveLiquidity(key) = (1_000e18, 2_000e18);
```

This is valid.

### Rehypothecated Liquidity

A hook with total reserves of `(1_000e18, 2_000e18)` but only half immediately withdrawable may return:

```solidity
getReserves(key) = (1_000e18, 2_000e18);
getEffectiveLiquidity(key) = (500e18, 1_000e18);
```

This is valid if the accounting basis is documented.

### Invalid Pool Key

If `key` does not belong to the hook or stats contract, the stats provider should revert with a descriptive error:

```solidity
error UnknownPool();
```

## Reference Implementation

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice TVL and effective-liquidity reporting for hooks.
interface IHookStats is IERC165 {
    /// @notice Total reserves managed by the hook for the given pool.
    /// @dev Should include all assets under management that correspond to token0/token1.
    ///      For invalid pool keys, should revert with a descriptive error.
    function getReserves(PoolKey calldata key)
        external
        view
        returns (uint256 token0, uint256 token1);

    /// @notice Liquidity available for immediate swapping.
    /// @dev Should be less than or equal to getReserves() for each token.
    ///      For invalid pool keys, should revert with a descriptive error.
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        returns (uint256 token0, uint256 token1);

    /// @notice The hook whose stats this contract reports.
    /// @dev Returns the contract's own address when the hook implements
    ///      the interface directly.
    function hook() external view returns (address);
}
```

## Security Considerations

`IHookStats` values are self-reported by the hook or stats provider. They are not proof of solvency, custody, or immediate settlement ability.

Stats providers may report assets that are wrapped, rehypothecated, time-locked, externally deployed, or otherwise subject to risk. The accounting basis should be documented.

Routers and DEX interfaces should treat `getReserves` as TVL reporting, not as a guarantee that all assets are available for immediate swap execution.

Routers should treat `getEffectiveLiquidity` as an availability signal, not as a binding quote.

If a stats contract is separate from the hook, registry correctness becomes security-relevant. Integrators should ensure that registered stats contracts are associated with the intended hook and pool.

The `hook` pointer of a separate stats contract is self-reported. Anyone can deploy a contract that points at any hook and reports arbitrary values. Integrators MUST NOT treat the pointer alone as proof of association and SHOULD establish the binding through the hook, its deployer, or a trusted registry, using the pointer as a consistency check. The binding is authoritative only when the stats provider is the hook itself.

The default canonical resolution trusts shared-deployer provenance and recency. An integrator relying on it SHOULD confirm the deployer is the expected hook author, and MAY pin a specific provider to avoid dependence on recency or stale deployer addresses.

Upgradeable stats contracts introduce governance and upgrade risk. Integrators may choose to surface, discount, or label stats from upgradeable providers.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
