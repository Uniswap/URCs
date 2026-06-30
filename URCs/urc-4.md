---
urc: 4
title: Active Liquidity Framework Hook Interface
author: Mark Toda (@MarkToda), Daniel Gretzke (@gretzke), Alice Henshaw (@hensha256), Chris Cashwell (@ccashwell)
status: Discussion
extends: 2
created: 2026-06-11
discussions-to: https://gov.uniswap.org/t/urc-4-active-liquidity-framework-hook-interface/26156
---

## Abstract

This URC defines `IALFHook`, a router-facing Active Liquidity Framework interface for Uniswap v4 custom-accounting hooks, covering indicative quotes, liveness, quote gas budgeting, and price-bounded simulation.

## Motivation

Uniswap v4 custom accounting allows hooks to replace, augment, or reduce the core AMM swap calculation. This enables hooks that wrap assets, route to external venues, deploy active liquidity, use vaults, rehypothecate reserves, settle through off-pool balances, or implement custom liquidity mechanisms.

Routers and multiplexers need a standard way to query hooks for indicative quotes, liveness, quote gas limits, and price-bounded simulations.

This URC extends [URC-2](./urc-2.md): a conforming ALF hook also emits the `HookSwap` event for the swaps it fills.

## Specification

The key words “MUST”, “MUST NOT”, “SHOULD”, “SHOULD NOT”, “MAY”, and “OPTIONAL” are to be interpreted as normative requirements.

### Scope

This URC applies to Uniswap v4 hooks that use custom accounting and want to expose standardized router-facing quote and simulation functionality.

A custom-accounting hook is a hook that computes swap accounting using hook-specific logic rather than relying solely on the core concentrated-liquidity AMM swap calculation.

Conformance is based on externally observable behavior: emitted events, implemented interfaces, return values, and documented semantics.

### Active Liquidity Framework Interface

`IALFHook` standardizes router-facing quote and simulation behavior for custom-accounting hooks.

A hook that implements `IALFHook` is an ALF hook.

ALF hooks expose their own capabilities directly so that routers, multiplexers, and other execution infrastructure can query them without bespoke per-hook integrations.

### Hook Data

`hookData` is an opaque hook-specific payload. It MAY contain oracle attestations, solver attestations, routing attestations, external venue data, signed liquidity data, or other hook-specific information.

Callers MAY pass empty `hookData` when the hook requires no payload.

This URC standardizes two errors for `hookData` handling:

```solidity
error MissingHookData();
error MalformedHookData();
```

A hook that requires a payload MUST revert with `MissingHookData` when `hookData` is empty. A hook MUST revert with `MalformedHookData` when non-empty `hookData` cannot be interpreted by the hook.

Hooks that require a payload for execution MAY revert during swap execution when the payload is missing, invalid, stale, replayed, or unauthorized.

### Interface

```solidity
interface IALFHook {
    /// @notice Get a non-binding indicative quote for routing.
    /// @param key The pool key.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param hookData Empty bytes or a hook-specific payload.
    /// @return quoteAmount For exact input, expected output. For exact output, expected input.
    function getIndicativeQuote(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        external
        view
        returns (uint256 quoteAmount);

    /// @notice Whether the hook is generally live and accepting swaps.
    function isLive() external view returns (bool);

    /// @notice Declared maximum gas for getIndicativeQuote execution.
    function maxGas() external view returns (uint32);

    /// @notice Simulate a swap up to a target price.
    /// @param key The pool key.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param sqrtPriceLimitX96 Target Q64.96 sqrt price.
    /// @param hookData Empty bytes or a hook-specific payload.
    /// @return amountIn Input consumed, including fees.
    /// @return amountOut Output received.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    )
        external
        view
        returns (uint256 amountIn, uint256 amountOut);
}
```

### `getIndicativeQuote`

`getIndicativeQuote` returns a non-binding quote for routing purposes.

The function MUST be `view`.

Routers SHOULD invoke it via `staticcall`.

If the hook cannot price the requested swap under normal market conditions — for example because of unsupported directions, unavailable liquidity, or amounts it cannot serve — the function SHOULD return `0` rather than revert.

For exact-input swaps, where `amountSpecified < 0`, `quoteAmount` is the expected output amount.

For exact-output swaps, where `amountSpecified > 0`, `quoteAmount` is the expected input amount.

If `amountSpecified == 0`, the function SHOULD return `0`.

The returned value is indicative only. The actual execution price is determined by the hook’s swap implementation and final custom-accounting deltas. Routers MUST enforce their own slippage and execution limits.

For malformed requests and unmet data requirements, `getIndicativeQuote` SHOULD revert instead of returning `0`:

- For a pool key that does not belong to the hook, it SHOULD revert with a descriptive error.
- If the hook requires a payload and `hookData` is empty, it MUST revert with `MissingHookData`.
- If non-empty `hookData` cannot be interpreted by the hook, it MUST revert with `MalformedHookData`.
- If the payload is invalid, stale, or insufficient, it SHOULD revert with a descriptive hook-specific error.

Routers SHOULD treat any revert as the absence of a quote for routing purposes.

### `isLive`

`isLive` reports whether the hook is generally live and accepting swaps.

Hooks SHOULD return `false` if their quote source, oracle data, solver data, attestation source, external venue, reserve accounting, or settlement mechanism is stale or unavailable.

Because `isLive` is hook-level rather than pool-level, routers SHOULD treat it as a coarse health signal.

A hook that returns `true` MAY still be unable to quote or execute a particular pool, direction, or amount. In that case, `getIndicativeQuote` SHOULD return `0`.

### `maxGas`

`maxGas` declares the maximum gas the hook expects `getIndicativeQuote` to consume.

Routers and multiplexers MAY use this value to set gas limits on quote `staticcall`s.

Hooks whose quote calls exceed their declared gas budget MAY be deprioritized or excluded by routers.

`maxGas` is self-declared metadata. It is not a security guarantee.

Hooks SHOULD return a conservative value that accounts for normal quote execution, including typical valid `hookData`.

### `swapToPrice`

`swapToPrice` simulates a swap up to a target price and returns both the input consumed and the output received.

This function is intended for routers, multiplexers, and split-fill planners.

`amountSpecified` follows the v4 convention:

| Value | Meaning |
| --- | --- |
| `amountSpecified < 0` | Exact input |
| `amountSpecified > 0` | Exact output |
| `amountSpecified == 0` | No swap |

`sqrtPriceLimitX96` is a Q64.96 target price using the standard token1/token0 square-root price convention.

The simulated swap SHOULD terminate when either:

1. The target price is reached.
2. The specified amount is exhausted.

For exact-input simulations, `amountIn` is the input consumed, including fees, and `amountOut` is the output received.

For exact-output simulations, `amountIn` is the input required, including fees, and `amountOut` is the output amount satisfied.

Hooks that do not support price-bounded simulation SHOULD return `(0, 0)`.

The presence of `sqrtPriceLimitX96` in this view function does not imply that the hook uses the core v4 AMM slot0 price for execution. It is a router interoperability parameter.

### Composition

`HookSwap` ([URC-2](./urc-2.md)), `IHookStats` ([URC-3](./urc-3.md)), and `IALFHook` are composable but independent.

A hook MAY emit `HookSwap` without implementing `IALFHook`.

A hook MAY expose `IHookStats` without implementing `IALFHook`.

A hook MAY implement `IALFHook` and use a separate `IHookStats` contract.

An ALF hook whose reserves and swappable liquidity are meaningful on-chain SHOULD also conform to [URC-3](./urc-3.md), either directly or through a separate stats contract.

Recommended ALF composition:

```solidity
contract MyALFHook is IALFHook {
    // swap execution and quote logic
}

contract MyHookStats is IHookStats {
    // TVL and effective-liquidity reporting
}
```

or:

```solidity
contract MyALFHook is IALFHook, IHookStats {
    // swap execution, quote logic, and stats reporting
}
```

When a separate stats contract is used, the hook or hook deployer SHOULD make the relationship discoverable through the relevant integrator registry or metadata process.

### ERC-165 Interface Detection

An ALF hook MUST implement [ERC-165](https://eips.ethereum.org/EIPS/eip-165).

`supportsInterface` MUST return `true` for `type(IALFHook).interfaceId` and for the ERC-165 interface ID itself (`0x01ffc9a7`).

### Conformance

A hook conforms to this URC if it:

1. Implements `IALFHook`.
2. Reverts with `MissingHookData` or `MalformedHookData` for missing or uninterpretable `hookData`.
3. Returns non-binding indicative quotes through `getIndicativeQuote`.
4. Reports coarse liveness through `isLive`.
5. Reports quote gas metadata through `maxGas`.
6. Supports `swapToPrice`, or returns `(0, 0)` when price-bounded simulation is unsupported.
7. Emits `HookSwap` ([URC-2](./urc-2.md)) for swaps in which it fills part or all of the swap.
8. Implements ERC-165 and reports support for `IALFHook` through `supportsInterface`.

## Rationale

### Non-Binding ALF Quotes

ALF quotes are indicative because hook execution may depend on external venues, attestations, solver data, oracle state, vault availability, or rapidly changing reserves.

A view quote cannot guarantee execution in the presence of state changes, concurrent swaps, MEV, attestation expiry, or external settlement constraints.

Routers must therefore enforce slippage and execution constraints independently.

### Quote Failure Semantics

`getIndicativeQuote` distinguishes the absence of a quote from a malformed request. Conditions that occur in normal routing operation — unavailable liquidity, unsupported directions, amounts the hook cannot serve — return `0`, keeping quote loops simple. Malformed requests and unmet data requirements revert with a descriptive error, surfacing integration bugs and data-supply failures that a silent `0` would mask, and providing failure reasons to off-chain tooling.

Because routers treat any revert as the absence of a quote, routing behavior is the same in both cases; the revert carries diagnostic information without changing routing semantics. Standardizing `MissingHookData` and `MalformedHookData` makes the two most common caller errors machine-readable across hooks, and reverting for foreign pool keys matches the behavior of stats providers in [URC-3](./urc-3.md).

### Price-Bounded Simulation

Routers and split-fill systems often reason about liquidity along a price axis.

`swapToPrice` gives custom-accounting hooks a standard way to expose price-bounded simulation, even if the hook does not use the core v4 AMM formula internally.

The `sqrtPriceLimitX96` parameter is a router interoperability parameter. It does not imply that the hook updates or relies on core slot0 price state during execution.

### Recommended Stats Reporting

ALF conformance requires quoting and the `HookSwap` event but recommends stats reporting ([URC-3](./urc-3.md)) rather than requiring it, because stats presuppose that a hook's liquidity is a finite, on-chain-knowable quantity. Transformation hooks, such as a hook that wraps and unwraps native tokens, have effectively unbounded liquidity with no truthful value to report. Hooks whose swappable liquidity depends on off-chain inventory or payload data cannot compute meaningful values in view functions that take no `hookData`. For these hooks, `getIndicativeQuote` remains the authoritative routing signal, while hooks whose reserves are meaningful on-chain are still expected to report them.

### ERC-165 Interface Detection

Requiring ERC-165 gives routers and multiplexers a uniform, on-chain way to detect ALF hooks without bespoke per-hook configuration or `try`/`catch` probing of typed calls. This supports permissionless discovery of quotable hooks across execution infrastructure.

## Backwards Compatibility

This URC does not require changes to Uniswap v4 core.

Existing hooks remain functional even if they do not implement `IALFHook`.

## Test Cases

### Quote: Unsupported Swap

If the hook cannot quote the requested swap under normal market conditions, such as unavailable liquidity, `getIndicativeQuote` should return:

```solidity
0
```

### Quote: Missing Required Hook Data

If the hook requires a payload and `hookData` is empty, `getIndicativeQuote` should revert:

```solidity
revert MissingHookData();
```

### Quote: Malformed Hook Data

If non-empty `hookData` cannot be interpreted by the hook, `getIndicativeQuote` should revert:

```solidity
revert MalformedHookData();
```

### Simulation: Unsupported Price-Bounded Simulation

If the hook does not support price-bounded simulation, `swapToPrice` should return:

```solidity
(0, 0)
```

## Reference Implementation

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Thrown when the hook requires a payload and hookData is empty.
error MissingHookData();

/// @notice Thrown when non-empty hookData cannot be interpreted by the hook.
error MalformedHookData();

/// @notice Router-facing ALF interface for custom-accounting hooks.
interface IALFHook is IERC165 {
    /// @notice Get a non-binding indicative quote.
    /// @dev Callers should invoke via staticcall.
    ///      Returns 0 when the hook cannot price the swap under normal conditions.
    ///      Reverts with MissingHookData or MalformedHookData for missing or
    ///      undecodable hookData.
    /// @param key The pool key.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param hookData Empty bytes or a hook-specific payload.
    /// @return quoteAmount For exact input, expected output. For exact output, expected input.
    function getIndicativeQuote(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata hookData
    )
        external
        view
        returns (uint256 quoteAmount);

    /// @notice Whether the hook is generally live and accepting swaps.
    function isLive() external view returns (bool);

    /// @notice Declared maximum gas for getIndicativeQuote execution.
    function maxGas() external view returns (uint32);

    /// @notice Simulate a swap up to a target price.
    /// @dev Returns (0, 0) when price-bounded simulation is unsupported.
    /// @param key The pool key.
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified Negative = exact input, positive = exact output.
    /// @param sqrtPriceLimitX96 Target Q64.96 sqrt price.
    /// @param hookData Empty bytes or a hook-specific payload.
    /// @return amountIn Input consumed, including fees.
    /// @return amountOut Output received.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    )
        external
        view
        returns (uint256 amountIn, uint256 amountOut);
}
```

## Security Considerations

`getIndicativeQuote` is non-binding. Routers must enforce slippage limits and execution constraints independently.

`isLive` is a coarse signal. A hook that returns `true` may still be unable to execute a specific pool, direction, or amount.

`maxGas` is self-declared metadata. Routers may use it for gas budgeting, but should not treat it as a guarantee.

`swapToPrice` is a simulation function. Routers must account for stale data, concurrent swaps, MEV, oracle updates, attestation expiry, external venue state changes, and other sources of quote drift.

Hooks that rely on signed or attested payloads must validate authenticity, freshness, replay protection, domain separation, chain ID, hook address, pool key, swap direction, amount constraints, and expiry before using the payload during execution.

Missing or malformed `hookData` causes quote calls to revert. Routers should handle failed staticcalls gracefully and treat reverts as the absence of a quote.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
