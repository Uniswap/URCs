---
urc: 2
title: Custom Accounting Hook Swap Event
author: Eric Sanchirico (@ericneil-sanc), Mark Toda (@MarkToda), Daniel Gretzke (@gretzke), Alice Henshaw (@hensha256)
status: Discussion
created: 2026-06-11
discussions-to: https://gov.uniswap.org/t/urc-2-custom-accounting-hook-swap-event/26154
---

## Abstract

This URC defines `HookSwap`, a canonical event through which Uniswap v4 hooks report the token deltas they contribute to a swap through custom accounting.

## Motivation

Uniswap v4 custom accounting allows hooks to replace, augment, or reduce the core AMM swap calculation. This enables hooks that wrap assets, route to external venues, deploy active liquidity, use vaults, rehypothecate reserves, settle through off-pool balances, or implement custom liquidity mechanisms.

Indexers and data systems need a swap event that reflects the actual custom-accounting token deltas. The core v4 `Swap` event reports only the portion of a swap executed by the AMM, so swaps whose accounting is altered partly or fully through hook accounting are only partially captured. The core event also includes AMM-specific fields such as `sqrtPriceX96`, `liquidity`, and `tick`, which may be unchanged, irrelevant, or misleading for hooks that bypass the AMM calculation.

## Specification

The key words “MUST”, “MUST NOT”, “SHOULD”, “SHOULD NOT”, “MAY”, and “OPTIONAL” are to be interpreted as normative requirements.

### Scope

This URC applies to Uniswap v4 hooks that use custom accounting and want to expose a standardized swap event.

A custom-accounting hook is a hook that computes swap accounting using hook-specific logic rather than relying solely on the core concentrated-liquidity AMM swap calculation.

Conformance is based on externally observable behavior: emitted events, return values, and documented semantics.

### HookSwap Event

A custom-accounting hook that conforms to this URC MUST emit `HookSwap` for every successful swap in which it returns a token delta, whether by filling part or all of the swap or by taking a fee on top of an AMM-executed swap.

```solidity
event HookSwap(
    PoolId indexed id,
    address indexed sender,
    int128 amount0,
    int128 amount1,
    uint24 swapFee
);
```

### Fields

| Field | Meaning |
| --- | --- |
| `id` | The `PoolId` of the pool being swapped. |
| `sender` | The address passed into the hook’s swap callback. This is often a router, aggregator, executor, or other intermediate contract. |
| `amount0` | Signed token0 delta of the hook's fill. |
| `amount1` | Signed token1 delta of the hook's fill. |
| `swapFee` | Pips-denominated fee rate applied by the hook, or `0` if no single meaningful pips-denominated fee applies. |

Consumers MUST NOT assume that `sender` is the ultimate end user.

Consumers SHOULD treat `amount0` and `amount1` as the authoritative record of the hook's fill. `swapFee` is metadata and may be `0` for hooks whose fee model is dynamic, externalized, or not expressible as a single pips value.

### Delta Sign Convention

`amount0` and `amount1` MUST be emitted in pool token order.

The sign convention matches the core v4 `Swap` event and the `BalanceDelta` convention, from the swapper's perspective:

| Sign | Meaning |
| --- | --- |
| Positive | Token is leaving the pool or hook accounting system, paid to the swapper. |
| Negative | Token is entering the pool or hook accounting system, paid by the swapper. |

For example, a token0-for-token1 swap SHOULD emit a negative `amount0` and a positive `amount1`.

The emitted deltas MUST reflect the final accounting effect of the hook's fill after hook-applied fees, wrapping effects, or other custom-accounting adjustments that affect the returned swap deltas.

Implementations MUST revert rather than silently truncate if an emitted amount cannot be safely represented as `int128`.

### Relationship to the Core Swap Event

`HookSwap` and the core v4 `Swap` event each report one portion of a swap. The core `Swap` event reports the deltas executed by the AMM. `HookSwap` reports the deltas filled by the hook.

For a swap filled entirely by the hook, `HookSwap` reports the full swap amounts and the core `Swap` event reports zero deltas.

For a swap filled partly by the hook and partly by the AMM, `HookSwap` reports the hook's portion and the core `Swap` event reports the AMM's portion.

Consumers can compute the total amounts of a swap by adding the `HookSwap` and core `Swap` deltas. Each event covers its portion exactly once, so the sum is free of double counting.

A hook that takes a fee in one of the swap tokens on top of an AMM-executed swap contributes a token delta even though it fills none of the swap, and MUST emit `HookSwap` for that delta. For a 100-unit exact-input token0 swap where the hook takes 1 token0 as a fee and the AMM fills the remainder, the core `Swap` event reports `amount0 = -99` while `HookSwap` reports `amount0 = -1`. The two sum to the `-100` total paid by the swapper.

Because a hook sets its own fill through its return deltas, it can emit `HookSwap` from whichever callback finalizes its fill amounts. Emitting the event requires no additional hook permissions.

### Omitted AMM Fields

`HookSwap` MUST NOT include:

```solidity
sqrtPriceX96
liquidity
tick
```

These fields describe the core concentrated-liquidity AMM state transition. Custom-accounting hooks may not use that state transition, may not update those fields, and may not have a meaningful internal equivalent.

A hook MAY expose hook-specific price, inventory, reserve, routing, or strategy information through separate events or views.

### Emission Rules

A conforming custom-accounting hook MUST emit exactly one `HookSwap` event for each successful externally requested swap in which it contributes a token delta, by filling part or all of the swap or by taking a fee.

A hook MUST NOT emit `HookSwap` for:

- Swaps in which the hook contributes no token delta.
- Indicative quote calls.
- Stats calls.
- Simulation calls.
- Reverted swaps.

If a hook internally splits its fill across venues, wrappers, vaults, or strategies, it SHOULD still emit one aggregate `HookSwap` event for its portion of the pool-level swap.

A hook MAY emit additional hook-specific events for internal execution details.

### Conformance

A hook conforms to this URC if it:

1. Contributes token deltas to swaps through custom accounting.
2. Emits exactly one `HookSwap` event for each successful swap in which it contributes a token delta.
3. Emits the token0 and token1 deltas of its fill in pool token order.
4. Uses the sign convention defined in this URC.
5. Emits final fill deltas after custom-accounting adjustments and applicable fees.
6. Does not include `sqrtPriceX96`, `liquidity`, or `tick` in the standard custom-accounting swap event.

## Rationale

### Interface-Based Standard

A shared base contract may be useful for implementation hygiene, but a URC should standardize behavior rather than inheritance structure. Hooks may have different audit constraints, upgrade patterns, gas optimizations, storage layouts, and execution models.

Conformance is therefore based on events and semantics.

### HookSwap Instead of Core Swap Fields

The core v4 `Swap` event is designed for swaps executed through the concentrated-liquidity AMM.

Custom-accounting hooks may bypass that AMM calculation. For those hooks, `sqrtPriceX96`, `liquidity`, and `tick` may be unchanged, irrelevant, or misleading.

`HookSwap` preserves the most generally useful part of the swap event — token0 and token1 deltas — while avoiding AMM-specific fields that may not apply. The deltas use the same sign convention as the core `Swap` event so that consumers can interpret the two events uniformly and add them directly.

### Hook Fill Deltas

`HookSwap` reports the hook's fill rather than the aggregate swap amounts. Each swap leg is reported by exactly one event — the AMM leg by the core `Swap` event and the hook leg by `HookSwap` — so consumers can add the two without double counting.

Per-leg reporting also keeps emission cheap and permissions minimal. A hook knows its own fill in the callback where it sets its return deltas, so it can emit `HookSwap` there. Aggregate reporting was considered and rejected: a hook that fills only part of a swap learns the AMM portion of the final amounts only in `afterSwap`, so aggregate semantics would force such hooks to take on an additional callback and permission solely for event emission.

## Backwards Compatibility

This URC does not require changes to Uniswap v4 core.

Existing hooks remain functional even if they do not emit `HookSwap`.

`HookSwap` complements the core v4 `Swap` event. The core event continues to report AMM-executed deltas, and `HookSwap` reports hook-filled deltas.

## Test Cases

### Fully Hook-Filled Token0-for-Token1 Swap

Given an exact-input swap filled entirely by the hook:

```solidity
zeroForOne = true;
amountSpecified < 0;
hook fill token0 delta = -100;
hook fill token1 delta = 99;
swapFee = 0;
```

The hook should emit:

```solidity
HookSwap(id, sender, -100, 99, 0);
```

The core `Swap` event reports zero deltas for the AMM leg.

### Fully Hook-Filled Token1-for-Token0 Swap

Given an exact-input swap filled entirely by the hook:

```solidity
zeroForOne = false;
amountSpecified < 0;
hook fill token0 delta = 99;
hook fill token1 delta = -100;
swapFee = 0;
```

The hook should emit:

```solidity
HookSwap(id, sender, 99, -100, 0);
```

### Partially Hook-Filled Swap

Given an exact-input token0-for-token1 swap of 100 token0, where the hook fills half and the AMM fills the rest:

```solidity
zeroForOne = true;
amountSpecified = -100;
hook fill: token0 delta = -50, token1 delta = 49;
AMM fill: token0 delta = -50, token1 delta = 49;
```

The hook should emit:

```solidity
HookSwap(id, sender, -50, 49, 0);
```

The core `Swap` event reports the AMM fill of `(-50, 49)`. Adding the two events yields the swap totals of `(-100, 98)`.

### Fee-Only Swap on Top of an AMM Fill

Given an exact-input token0-for-token1 swap of 100 token0, where the AMM fills the swap and the hook takes 1 token0 as a fee:

```solidity
zeroForOne = true;
amountSpecified = -100;
hook fee: token0 delta = -1, token1 delta = 0;
AMM fill: token0 delta = -99, token1 delta = 98;
```

The hook should emit:

```solidity
HookSwap(id, sender, -1, 0, swapFee);
```

The core `Swap` event reports the AMM fill of `(-99, 98)`. Adding the two events yields the swapper's totals of `(-100, 98)`.

## Reference Implementation

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Standard event interface for custom-accounting hook swaps.
interface IHookSwapEvents {
    /// @notice Emitted on every successful swap in which the hook fills part or all of the swap.
    /// @param id The pool ID.
    /// @param sender The swap sender, often a router or executor.
    /// @param amount0 Signed token0 delta of the hook's fill. Negative = paid by the swapper.
    /// @param amount1 Signed token1 delta of the hook's fill. Negative = paid by the swapper.
    /// @param swapFee Pips-denominated fee rate, or 0 if not applicable.
    event HookSwap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint24 swapFee
    );
}
```

## Security Considerations

`HookSwap` is emitted by the hook. Consumers should verify that the emitting hook is the hook associated with the pool being indexed.

`HookSwap` values are self-reported by the hook. A hook can emit `amount0`, `amount1`, or `swapFee` that do not match the swap's actual token flows, whether by error or design, and emission carries no protocol-level guarantee of accuracy. Consumers SHOULD treat `HookSwap` as hook-attested data rather than a verified settlement record, and reconcile against on-chain balance changes where correctness is critical.

Indexers MUST NOT infer AMM price, liquidity, or tick movement from `HookSwap`.

Adding `HookSwap` and core `Swap` deltas relies on hooks emitting exactly one event per swap covering only the hook's fill. A hook that emits aggregate amounts or multiple events per swap would cause double counting in consumers that sum the two.

The `sender` field should not be treated as the ultimate user address.

Implementations must avoid unsafe casts. If a final token delta cannot fit into `int128`, the hook must revert rather than truncate.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
