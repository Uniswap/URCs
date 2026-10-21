---
urc: 5
title: Token Venue Policy
status: Discussion
author: 0xBeans
created: 2026-09-15
discussions-to: https://gov.uniswap.org/t/urc-5-token-venue-policy/26307
---

## Abstract

ERC-20 tokens may recommend primary liquidity venues or restrict trading to specific venues, often hooked Uniswap v4 pools. Routers and frontends need to distinguish those preferences from restrictions before constructing transactions. This proposal defines `IVenuePolicy` to declare canonical v4 pools, distinguish preferred from enforced venue policies, and expose external-venue permissions through both bulk and point queries. It also defines a standard policy-refusal error and consumer rules for routing, liquidity provision, and simulated withdrawal quotes.

## Motivation

Hooks make it practical for a token to require that all trading pass through a specific pool. The token enforces this in its transfer logic by refusing transfers to or from other venues. Nothing on-chain tells a consumer that the policy exists, so consumers discover it the hard way:

- A router simulates a route through a v3 or hookless v4 pool for the token. The simulation reverts on the token transfer, and the router either drops the token or interprets a generic revert as an RPC problem.
- A pool indexer lists a copycat pool for the token. Users add liquidity and then find they cannot trade against it, or cannot withdraw because the token blocks the pool.
- A frontend quotes an LP withdrawal from the canonical pool using a fixed slippage default. The hook charges an exit fee through return deltas, the received amount is lower than the position's principal, and the position manager reverts on slippage.
- A token allows trading anywhere but keeps its primary liquidity in a hooked pool. It needs a way to make that pool discoverable without excluding other working venues.

Each of these has been resolved bilaterally between individual token teams and individual routers. That does not scale: token launches are not slowing down, and v4 will only grow. The fix should be a discovery rule that a launchpad can adopt once and every consumer can honor once.

[URC-3](./urc-3.md) already establishes the pattern: a contract self-reports something a consumer cannot infer from state, and consumers agree on how to use the report. This proposal applies the same pattern to venue policy.

## Specification

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are to be interpreted as described in RFC 2119.

### Scope

This proposal covers ERC-20 tokens that declare preferred liquidity venues or an enforced venue policy. A token whose transfer logic refuses transfers to or from some venues is a "venue-gated token". The proposal defines how tokens declare their policy and how routers, aggregators, frontends, and pool indexers (together, "consumers") use it.

`Preferred` identifies recommended pools without imposing venue restrictions. `Enforced` requires consumers to honor the declared restrictions wherever the token can observe the trade, and recommends honoring them where it cannot. The mode describes consumer obligations; it does not guarantee that the token can enforce them on-chain.

A route hop **crosses the token's boundary** when the token is the route's input or output, or when the hop moves the token into or out of a venue (a transfer the token sees). A **net-zero intermediate hop** is one where the token is credited and debited inside a shared venue's accounting within the same route and is never transferred, so the token cannot observe it. This includes the v4 `PoolManager` and other singleton vaults.

A "venue" is any contract that holds the token's balance on behalf of one or more liquidity pools. This includes Uniswap v2 pairs, v3 pools, Liquidity Book pairs, Aerodrome pools, and shared vaults. Because every v4 pool settles through one `PoolManager`, a v4 venue is identified by the pair `(PoolManager address, PoolId)`. `PoolId` is specific to Uniswap v4; all other venues use zero. Other singleton vaults, such as Balancer's Vault, are treated as a single venue: permission applies to the whole vault address, not individual pools within it.

The transfer restrictions in this proposal apply only to transfers to and from venues. Consumers and tokens MUST NOT apply those restrictions to transfers between ordinary accounts. The net-zero routing guidance below also applies when a venue accounts for a trade without transferring the token. Identifying which addresses are venues is outside the scope of this interface.

Every `PoolKey` in this proposal refers to the canonical Uniswap v4 `PoolManager` on the chain the token is deployed on. Consumers resolve that address from the chain id, as they do for URC-3 and URC-4.

Transfer-time enforcement is outside the scope of this proposal. V4 settles balances per currency rather than per pool, so a token generally cannot identify the pool behind a `PoolManager` transfer. Multi-hop routes can net out the token's balance changes without transferring it.

### Where the declaration lives

The token MUST be the contract that implements `IVenuePolicy`. It is the authority for its venue preferences and restrictions, it is the key consumers index by, and it can have several canonical pools (an ETH pair and a stable pair) or none on v4 at all. A hook can serve many pools but cannot speak for the token's venues on other protocols, and a hook that is not the token's own has no authority over the token's policy.

Consumers MUST NOT treat an `IVenuePolicy` implementation on any contract other than the token as a declaration for that token.

### Interface

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Declares a token's preferred pools and venue restrictions.
///         ERC-165 interface id: `type(IVenuePolicy).interfaceId`, which is
///         `canonicalPools.selector ^ venueAllowed.selector ^
///          venueEnforcement.selector ^ externalVenues.selector`.
interface IVenuePolicy {
    enum VenueEnforcement {
        Preferred,
        Enforced
    }

    struct ExternalVenue {
        address venue;
        // Membership in the corresponding directional allowlist.
        bool inbound;
        bool outbound;
    }

    /// @notice Emitted when the mode changes. Consumers re-read the full policy.
    event VenueEnforcementChanged(VenueEnforcement enforcement);

    /// @notice Emitted when the canonical pool set or its order changes.
    ///         Consumers re-read `canonicalPools()`.
    event CanonicalPoolsChanged();

    /// @notice Emitted when a venue's declared permission changes in one
    ///         direction. Consumers re-read `venueAllowed` for that venue.
    /// @param venue The contract holding the token's balance for one or more pools.
    /// @param poolId The v4 pool id, or zero for non-v4 venues.
    /// @param inbound True for transfers into the venue, false for out of it.
    /// @param allowed The new declared permission for that direction.
    event VenueStatusChanged(address indexed venue, bytes32 indexed poolId, bool inbound, bool allowed);

    /// @notice Emitted when either restriction flag or the allowlist changes.
    ///         Consumers invalidate cached external-venue permissions.
    event ExternalVenuesChanged();

    /// @notice Whether the venue policy is preferred or enforced.
    function venueEnforcement() external view returns (VenueEnforcement);

    /// @notice Canonical v4 pools, most preferred first, on this chain's
    ///         canonical PoolManager. Exhaustive only in Enforced mode.
    /// @dev Full keys, not ids, so a caller can build a route without an indexer.
    ///      Empty means no preferred pools or, in Enforced mode, no allowed v4 pools.
    function canonicalPools() external view returns (PoolKey[] memory);

    /// @notice Whether the token's declared policy permits a transfer into
    ///         (`inbound`) or out of a venue. A statement of policy, not a
    ///         guarantee that a specific transfer will succeed.
    /// @param venue The contract holding the token's balance for one or more pools.
    /// @param poolId The v4 pool id, or zero for non-v4 venues.
    /// @param inbound True for a transfer into the venue, false for out of it.
    function venueAllowed(address venue, bytes32 poolId, bool inbound) external view returns (bool);

    /// @notice Non-v4 restriction flags and complete directional allowlists.
    /// @dev A restricted direction permits only venues listed in `allowed`
    ///      with that direction's flag set. An unrestricted direction permits
    ///      venues by default; in Enforced mode, `venueAllowed` can report
    ///      individual refusals, which this bulk view does not enumerate.
    function externalVenues()
        external
        view
        returns (bool inboundRestricted, bool outboundRestricted, ExternalVenue[] memory allowed);
}

/// @notice The only error a venue-gated token reverts with when a transfer is
///         refused because of venue policy.
/// @dev Declared at file level so any contract can select on it without
///      inheriting the interface.
/// @param venue The venue the transfer was refused for.
/// @param poolId The v4 pool id when the token can identify it, otherwise zero.
/// @param inbound True if the refused transfer was into the venue.
error VenueNotAllowed(address venue, bytes32 poolId, bool inbound);
```

Five views including ERC-165 `supportsInterface`, four events, one error.

### Token requirements

- A token that implements `IVenuePolicy` MUST implement ERC-165 and MUST return true from `supportsInterface(type(IVenuePolicy).interfaceId)`.
- `venueEnforcement()` MUST return `Preferred` or `Enforced`. In `Preferred` mode the token declares no venue restrictions: `venueAllowed` MUST return true for venue queries within this proposal's scope, and `externalVenues()` MUST return `(false, false, [])`. Reactive venue refusals require `Enforced` mode. This does not promise that transfers succeed for reasons unrelated to venue policy.
- `canonicalPools()` MUST return the token's preferred v4 pools in `Preferred` mode and every permitted v4 pool in `Enforced` mode, ordered most preferred first. Keys MUST be unique and include the declaring token as one currency. The order SHOULD be stable and SHOULD change only when preference changes.
- `venueAllowed` MUST reflect the token's declared policy, independently of any transaction-specific authorization needed to execute it. A true result does not guarantee transfer success; holding caps, paused state, or missing execution authorization can still cause failure.
- In `Enforced` mode, `venueAllowed(poolManager, poolId, inbound)` MUST return true for both directions exactly when `poolId` identifies a key in `canonicalPools()`. Other v4 pool ids MUST return false. Non-v4 permissions MUST follow the directional rules specified below.
- When a transfer is refused because of venue policy, the token MUST revert with `VenueNotAllowed` and MUST NOT revert with any other error for that reason. If the token cannot identify the v4 pool behind a `PoolManager` transfer, it MUST pass zero as `poolId`. Refusals for other reasons are out of scope.
- The token MUST emit `VenueEnforcementChanged` when its mode changes, `CanonicalPoolsChanged` when its canonical pool set or order changes, and `ExternalVenuesChanged` when either restriction flag or the allowlist changes. These events MUST be emitted in the transaction making the change.
- An individual external-venue permission change MUST also emit `VenueStatusChanged` for each affected direction, including when a reactive refusal is introduced or removed in an unrestricted direction. Such a refusal does not require `ExternalVenuesChanged` unless a restriction flag or allowlist also changes. Mode switches, canonical-set changes, and restriction-flag changes MAY use their aggregate events instead of emitting a per-venue event for every permission affected. A mode switch does not waive the events required for changes to the canonical or external lists themselves.
- A token whose policy is immutable still MUST implement the events; they are simply never emitted.

### External venue policy

`externalVenues()` MUST return the restriction flags and a complete finite allowlist for each restricted direction. It does not enumerate reactive refusals in unrestricted directions. Each entry MUST have a unique, nonzero venue address other than the canonical `PoolManager`, at least one membership flag MUST be true, and a flag MUST be false for a direction that is unrestricted. Entry order has no preference meaning. Non-v4 point queries use `poolId = 0`.

For a venue and direction, let `member` be the corresponding flag in its entry, or false if the venue is absent. The declared permission is:

| Direction | Permission | Empty list |
|---|---|---|
| Unrestricted | Permitted by default; `venueAllowed` reports any reactive refusal in `Enforced` mode | Does not establish individual venue permissions |
| Restricted | `member` | No venue permitted in that direction |

The two directions are independent. For example, `(true, false, [{venue: P, inbound: true, outbound: false}])` permits inbound transfers only to `P`. Outbound transfers are permitted by default, subject to any reactive refusals reported by `venueAllowed`.

For a restricted direction, the bulk representation MUST produce the same answer as `venueAllowed(venue, 0, inbound)` for every non-v4 venue at the same block. Both views SHOULD derive from the same stored allowlist. Consumers reading multiple views SHOULD pin them to one block. A partial allowlist MUST NOT be presented as complete.

For an unrestricted direction, `venueAllowed` is authoritative. A token in `Enforced` mode MAY refuse specific venues reactively; it MUST return false for those venues and true for others in that direction. Changes to these permissions MUST emit `VenueStatusChanged`. The bulk view remains allowlist-only and MUST NOT be treated as evidence that no such refusals exist. A refused transfer still uses `VenueNotAllowed` under the token requirements above.

### Consumer rules

Routers and aggregators:

1. Consumers MUST read `venueEnforcement()` before applying the canonical list. In `Preferred` mode, consumers MUST include canonical pools in candidate discovery when those pools meet the consumer's hook-support, execution, and safety requirements. They MAY route or split trades across other pools and SHOULD prefer canonical pools when otherwise equivalent routes tie. In `Enforced` mode, for every hop that crosses the token's boundary, consumers MUST restrict v4 candidates to `canonicalPools()` and MUST NOT use another v4 pool, even if simulation succeeds; non-v4 candidates follow rule 2. For a net-zero intermediate hop, consumers SHOULD NOT use any venue the policy does not permit in the direction of the corresponding internal credit or debit, including non-canonical v4 pools and other singleton vaults. An internal credit is inbound and a debit is outbound. Every token's policy on a route applies independently.
2. In `Enforced` mode, a non-v4 hop that crosses the token's boundary MUST be excluded unless the venue's permission is true for each direction in which the token moves. Selling into a venue is inbound; buying out of it is outbound. For a restricted direction, consumers MAY obtain the permission from `venueAllowed(venue, 0, inbound)` or a complete `externalVenues()` allowlist. For an unrestricted direction, the bulk view alone is insufficient: consumers MUST point-query candidates or use current per-venue permissions cached from earlier point queries or a known initial state and maintained through `VenueStatusChanged` and the invalidations in rule 4. Subscribing only to future events does not establish existing permissions. These same permission reads apply to net-zero intermediate hops, but a false result invokes rule 1's SHOULD NOT rather than the boundary-hop prohibition. Consumers MAY bound the gas, response size, and list length accepted from the bulk query. If it fails, contains invalid entries, or exceeds those limits, they MUST use point queries or exclude the affected candidates. An unavailable permission MUST NOT be treated as permission to route, including for net-zero hops; simulation alone MUST NOT substitute for missing permissions.
3. A revert carrying the `VenueNotAllowed` selector on a candidate path means the path is not permitted. The consumer SHOULD drop the path and SHOULD NOT count the revert as a token failure, an RPC failure, or a reason to blacklist the token. The `PoolManager` wraps failed outbound transfers in `WrappedError(address target, bytes4 selector, bytes reason, bytes details)`; consumers SHOULD match the selector on the inner `reason` as well as on the outer revert data. Some execution paths discard the original revert data, so absence of the selector does not prove the failure was unrelated to policy.
4. Consumers SHOULD refresh cached policy on its change events. `VenueEnforcementChanged` invalidates the full policy, `CanonicalPoolsChanged` invalidates the canonical list and cached v4 permissions, and `ExternalVenuesChanged` invalidates the external list and cached non-v4 permissions. `VenueStatusChanged` invalidates the named venue and direction. Consumers MUST NOT treat a failed mode query, unknown mode, or incomplete bulk response as permission to route. Existing-position withdrawals remain governed by rule 7.

Frontends and pool indexers:

5. In `Enforced` mode, a consumer MUST NOT offer add-liquidity on a v4 pool unless it is in `canonicalPools()`, or on a non-v4 venue unless its inbound permission is true, determined using rule 2's query and cache requirements. Unsupported pools SHOULD be hidden or badged. In `Preferred` mode, consumers MAY offer add-liquidity on other pools and SHOULD identify those outside the canonical list as non-preferred. A failed or unknown mode query MUST NOT enable new liquidity provision. Normal execution and safety checks apply in both modes.
6. For remove-liquidity on a v4 pool with a hook, a consumer SHOULD simulate the removal to establish the expected amounts and then apply the user's slippage tolerance to those amounts. The `PositionManager` validates `amount0Min` and `amount1Min` against the principal delta, which is the returned `liquidityDelta` minus `feesAccrued`, so minima SHOULD be derived from that component of the simulation rather than from total wallet receipts. A known exit fee is not a reason to widen the tolerance.
7. Removing a pool from `canonicalPools()`, or a venue becoming disallowed, MUST NOT by itself cause a consumer to hide remove-liquidity for existing positions in that pool or venue.

Tokens with neither `IVenuePolicy` nor a trusted token-list declaration are unaffected.

### Token list extension

Non-upgradeable tokens deployed before this proposal cannot add the interface. For those, and as an off-chain mirror for everything else, the same data MAY be carried in a token list entry's `extensions` field. The token list schema allows nested objects up to three levels and no arrays, so pools are keyed `pool0`, `pool1`, and so on, in preference order:

```json
{
  "address": "0x88ad8DdF1E3898412146a534538d418c6F8A9062",
  "chainId": 4663,
  "name": "STANDARD",
  "symbol": "STANDARD",
  "decimals": 18,
  "extensions": {
    "venuePolicy": {
      "enforcement": "enforced",
      "pool0": {
        "currency0": "0x0000000000000000000000000000000000000000",
        "currency1": "0x88ad8DdF1E3898412146a534538d418c6F8A9062",
        "fee": 10000,
        "tickSpacing": 200,
        "hooks": "0xF1eE073811B14359D850825E48d200483200eDcd"
      }
    }
  }
}
```

`enforcement` MUST be `"preferred"` or `"enforced"`; if absent, it defaults to `"enforced"`. Consumers MUST NOT interpret an unknown value as `"preferred"`. The keys refer to the canonical `PoolManager` for `chainId`. No `poolN` entries means no preferred pools in preferred mode, or no allowed v4 pools in enforced mode. Pool indices MUST be consecutive from zero and are read in numeric order. With the explicit `enforcement` field, the token-list schema's ten-property limit leaves room for up to nine pool entries; a larger policy MUST NOT be silently truncated.

For extension-only tokens, `enforcement` and the `poolN` entries substitute for the `venueEnforcement()` and `canonicalPools()` reads; unknown modes have the same unavailable-policy handling. The extension has no non-v4 policy representation, so consumers apply the v4 portions of rules 1 and 5, plus rules 6 and 7, and treat non-v4 venues as they do today. It does not override an on-chain restriction on another token in the route.

Which token lists a consumer trusts is the consumer's choice, as it is for every other list-sourced attribute. When both on-chain data and a token list extension exist for a token, on-chain data wins.

### Conformance

A token conforms if it implements `IVenuePolicy`, meets the token requirements above, and reverts with `VenueNotAllowed` for policy refusals. A consumer conforms if it follows rules 1 through 7 for every token that reports the interface via ERC-165, and the v4 portions of rules 1 and 5 plus rules 6 and 7 for every token carrying the extension in a list the consumer trusts.

## Rationale

### Token, not hook

The token is the authority for its venue preferences and restrictions. Consumers index by token address, so a token-level view needs no discovery step, and a token may have canonical venues across versions and pairs, which a hook cannot describe.

Allowing a hook to declare on the token's behalf was considered and rejected. A copycat hook could implement the interface and claim a legacy token, and nothing on-chain would contradict it. Tokens that cannot implement the interface use the token list extension instead.

### Preferred and enforced policies

A token can recommend its primary pool without forbidding other working liquidity. `Preferred` gives those pools a discovery path while leaving route selection open. `Enforced` retains the restrictions needed by tokens whose supported integrations must use declared venues, including when an alternative route could execute successfully.

Hard obligations stop at the token's boundary. When the token is the input or output, or moves into or out of a venue, the token sees the transfer and can refuse it, so the rule is backed by something a consumer can observe. A net-zero intermediate hop never transfers the token, so a MUST there would be unenforceable and unverifiable; it is a SHOULD NOT instead.

The enum values are fixed in this version. Adding a value is not assumed to be backward-compatible: older Solidity callers may reject a value outside the enum they were compiled with. Consumers treat an unsupported mode as unavailable policy.

### Bulk and point queries

`externalVenues()` lets off-chain consumers cache complete allowlists for restricted directions. For unrestricted directions, `venueAllowed` supplies the individual permission, including reactive refusals that the bulk view does not enumerate. It also provides a fallback when a bulk read exceeds resource limits. Separate inbound and outbound restriction flags let a token restrict deposits without restricting withdrawals. Consumers initialize per-venue caches from known permissions and maintain them through change events; aggregate events invalidate caches when a flag change affects many venues at once.

### Allowlists in the bulk view

Pool creation is permissionless, so blocking known venues does not restrict venues created later. An allowlist instead refuses anything unlisted. The bulk view therefore enumerates allowlists only. An unrestricted direction permits venues by default while allowing exact, individual refusals through `venueAllowed` and `VenueStatusChanged`. This lets routers discover reactive blocks without presenting a list of known blocks as an exhaustive set of unsupported venues.

### Canonical `PoolManager` by convention

`PoolKey` carries no manager address. Adding one to every entry would diverge from URC-3 and URC-4, which take bare keys. This proposal follows them and fixes the manager by chain convention.

### Full `PoolKey`s, not ids

Returning `PoolId` values would force every consumer to run an indexer to recover the key. Returning keys lets a router build the route from the view alone.

### An ordered list, not a single pool

Most tokens will return one pool. Allowing several supports tokens that want both an ETH pair and a stable pair.

### One error

Simulation-based routers already classify reverts by selector. A single standard error lets them recognise a policy refusal without parsing token-specific errors or guessing from generic reverts. Making it a file-level error rather than an interface member means a router can import the selector without depending on the interface. Because v4 wraps outbound transfer failures, the rule tells consumers to look inside `WrappedError` too.

### Preflight queries

`venueAllowed` provides a cheap check for routers filtering candidate paths and frontends deciding which liquidity forms to render. Keeping the query limited to venue policy avoids duplicating the token's transfer logic. Consumers must still simulate the transaction.

### Direction on `VenueStatusChanged`

A token can block inbound transfers to a venue while leaving outbound open so that positions can be withdrawn. Without a direction the event could not describe that change, so it carries `inbound` and mirrors the shape of `venueAllowed`.

### Events instead of polling

Policy change events let consumers cache declarations and refresh them when the mode, canonical pools, or external permissions change. Aggregate events cover changes that affect more venues than a token can enumerate individually.

### Why consumer rules and not just an interface

These rules keep consumers from routing through unsupported pools in enforced mode and make preferred pools discoverable without excluding other liquidity.

## Backwards Compatibility

Tokens with neither `IVenuePolicy` nor a trusted token-list declaration are unaffected. Consumers that ignore this proposal continue to work as they do today, with the failure modes described in Motivation.

Non-upgradeable deployed tokens cannot add the interface. The token list extension carries the same data for them until their next token version.

The `VenueNotAllowed` error is new. Tokens already deployed with their own policy errors cannot change them; consumers MAY additionally recognise those errors on a per-token basis, but this proposal does not require it.

The two additional views change the ERC-165 interface id from the earlier draft. Consumers MUST detect support for the full interface and MUST NOT interpret a missing `venueEnforcement()` view as `Preferred`. A legacy token-list declaration without `enforcement` retains enforced behavior.

Reactive-refusal semantics do not change the interface id. Consumers of earlier drafts MUST NOT assume that an unrestricted bulk direction guarantees permission for an individual venue; rule 2's permission checks still apply.

## Test Cases

Unless otherwise specified, these cases use a token `T` in `Enforced` mode with `canonicalPools()` returning one key `K` on `PoolManager` `PM`, and a copycat pool `K'` for the same pair with a different hook. Its external policy restricts inbound transfers to an allowlist containing one v3 pool `P` and leaves outbound unrestricted with no reactive refusals: `(true, false, [{venue: P, inbound: true, outbound: false}])`. `Q` is another v3 pool for `T`, not on the allowlist.

| Case | Call | Expected |
|---|---|---|
| ERC-165 | `T.supportsInterface(type(IVenuePolicy).interfaceId)` | `true` |
| Mode | `T.venueEnforcement()` | `Enforced` |
| Canonical inbound | `T.venueAllowed(PM, K.toId(), true)` | `true` |
| Canonical outbound | `T.venueAllowed(PM, K.toId(), false)` | `true` |
| Copycat declared | `T.venueAllowed(PM, K'.toId(), true)` | `false` |
| Copycat inbound refusal | `T` refuses a transfer into `PM` on policy grounds during a swap into `K'` | Reverts with `VenueNotAllowed(PM, id, true)` where `id` is `K'.toId()` or zero. Whether the token sees a transfer at all depends on how the swap settles |
| Copycat outbound refusal | `T` refuses a transfer out of `PM` on policy grounds during a swap out of `K'` | Reverts with `WrappedError` whose `reason` carries `VenueNotAllowed(PM, id, false)` |
| Allowlisted v3 inbound | `T.venueAllowed(P, 0, true)` | `true` |
| Unlisted v3 inbound | `T.venueAllowed(Q, 0, true)` | `false` |
| Unrestricted outbound | `T.venueAllowed(Q, 0, false)` | `true` |
| Bulk external policy | `T.externalVenues()` | `(true, false, [{venue: P, inbound: true, outbound: false}])`; establishes inbound permissions, but outbound candidates still need point queries or initialized per-venue caches |
| Empty allowlist | Both directions restricted, list is empty | No external venue permitted in either direction |
| Unrestricted | Neither direction restricted, list is empty, no reactive refusals | Point queries return true in both directions; the bulk result alone does not establish the absence of refusals |
| Invalid entry | An entry sets `outbound: true` while outbound is unrestricted | Invalid response; consumer falls back to point queries or excludes affected candidates |
| Refused v3 transfer | `T` refuses `T.transfer(Q, amount)` on policy grounds | Reverts with `VenueNotAllowed(Q, 0, true)` |
| Reactive refusal | Both directions unrestricted; `T` blocks inbound transfers to Liquidity Book pair `L` | `externalVenues()` remains `(false, false, [])`; `venueAllowed(L, 0, true)` is false, outbound is true; an inbound route is excluded before simulation |
| Reactive refusal event | `T` introduces the inbound block on `L` above | Emits `VenueStatusChanged(L, 0, true, false)`; no `ExternalVenuesChanged` is required because the flags and allowlist are unchanged |
| Reactive refusal removed | `T` removes that block | `venueAllowed(L, 0, true)` becomes true and `VenueStatusChanged(L, 0, true, true)` is emitted |
| Refusal at execution | A venue is reactively blocked after a quote; a transfer is then refused | Reverts with `VenueNotAllowed`; consumer drops the path and refreshes the permission |
| Missing cache baseline | Router sees an unrestricted bulk direction and subscribes only to future events | It MUST query a candidate's permission or establish a known initial state before relying on an event-maintained cache |
| Set change | Token adds a second canonical pool | `CanonicalPoolsChanged` emitted in the same transaction; `canonicalPools()` length is 2 |
| Venue change | Token removes `P` from the inbound allowlist | `VenueStatusChanged(P, 0, true, false)` and `ExternalVenuesChanged` emitted in the same transaction |
| Restriction change | Token marks outbound restricted | `ExternalVenuesChanged` emitted; consumers refresh external permissions without per-venue events for every affected address |
| Mode change | Token switches to `Preferred`, clearing external restrictions | `VenueEnforcementChanged(Preferred)` and any required list-change events emitted; consumers refresh the full policy |
| Router candidates | Router asked to route `T` with `K`, `K'`, `P` and `Q` liquid | `K` is a candidate; `K'` is not; `P` is a candidate both ways; `Q` is a candidate for buys only |
| Other-protocol boundary hop | Route sells `T` into an Aerodrome pool absent from the inbound allowlist | Route excluded under rule 2, just as for an unlisted v3 pool |
| Ordinary accounts | `T` moves between ordinary accounts while inbound venues are restricted | Venue restrictions do not apply; unrelated token transfer rules remain unaffected |
| Non-v4 singleton | Non-v4 vault `V` holds balances for several pools | Queries use `(V, 0, inbound)`; the answer applies to the whole vault in that direction, not individual pools |
| Enforced boundary hop | Route buys or sells `T` through `K'` | Route excluded even if simulation succeeds |
| Enforced intermediate hop | Route uses `T` only as a net-zero intermediary in `K'` | Route SHOULD be excluded; a conforming router MAY use it |
| Non-v4 net-zero hop | `T` is credited and debited within vault `V` without a transfer; its inbound permission is false | Route SHOULD be excluded; a conforming router MAY use it under rule 1 rather than rule 2's boundary-hop prohibition |
| Unknown net-zero permission | An unrestricted vault direction has no initialized cache and its point query fails | Route excluded; unavailable permission is not the known false permission covered by SHOULD NOT |
| Preferred discovery | A `Preferred` token declares `K`, while `K'` also has liquidity | `K` is considered subject to normal support and safety checks; `K'` may also be used |
| Preferred external policy | Query a `Preferred` token's external policy | `(false, false, [])`; point queries permit all external venues |
| Preferred reactive refusal | A `Preferred` token reports false for an individual venue | Non-conforming; reactive venue refusals require `Enforced` mode |
| Preferred add-liquidity | User opens add-liquidity on `K'` for a `Preferred` token | May be offered subject to normal checks, with a non-preferred badge |
| Unavailable bulk query | `externalVenues()` reverts or exceeds the consumer's size cap | Consumer uses `venueAllowed` or excludes affected candidates; does not infer permission from simulation |
| Unsupported mode | Mode query fails or returns an unknown value | No new route or add-liquidity offered based on that declaration; withdrawal controls remain available |
| Legacy list mode | Token-list declaration omits `enforcement` | Treated as `enforced` |
| Frontend add-liquidity | User opens add-liquidity on `K'` or `Q` | Add-liquidity disabled or omitted; optionally badged unsupported |
| Frontend reactive refusal | Inbound unrestricted, but a current point query or initialized cache reports the venue blocked | Add-liquidity disabled or omitted; an unrestricted bulk result does not override the refusal |
| Frontend remove-liquidity | Token removes `K` from `canonicalPools()` | Existing positions in `K` still show remove-liquidity |

## Reference Implementation

A minimal token in immutable `Enforced` mode with one canonical pool and an owner-managed inbound allowlist for non-v4 venues, outbound unrestricted with no reactive refusals. One enumerable set backs the restricted direction's bulk and point queries. Enforcement is omitted on both sides: the v4 side because the token cannot see the pool behind a `PoolManager` transfer, and the external side because refusing unlisted venues requires the token to recognise which addresses are venues, which is token-specific. `venueAllowed` is queried for known venues; using it as a transfer guard for arbitrary recipients would incorrectly restrict ordinary-account transfers. The point is the interface surface.

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IVenuePolicy} from "./IVenuePolicy.sol";

contract VenueGatedToken is ERC20, ERC165, IVenuePolicy {
    using PoolIdLibrary for PoolKey;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable poolManager;
    address public immutable owner;
    PoolKey internal canonical;
    EnumerableSet.AddressSet private allowedInbound;

    constructor(address poolManager_, PoolKey memory canonical_) ERC20("Gated", "GATED") {
        poolManager = poolManager_;
        owner = msg.sender;
        canonical = canonical_;
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(IVenuePolicy).interfaceId || super.supportsInterface(id);
    }

    function venueEnforcement() external pure returns (VenueEnforcement) {
        return VenueEnforcement.Enforced;
    }

    function canonicalPools() external view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](1);
        keys[0] = canonical;
    }

    function externalVenues()
        external
        view
        returns (bool inboundRestricted, bool outboundRestricted, ExternalVenue[] memory allowed)
    {
        inboundRestricted = true;
        outboundRestricted = false;
        uint256 count = allowedInbound.length();
        allowed = new ExternalVenue[](count);
        for (uint256 i; i < count; ++i) {
            allowed[i] = ExternalVenue({venue: allowedInbound.at(i), inbound: true, outbound: false});
        }
    }

    function venueAllowed(address venue, bytes32 poolId, bool inbound) public view returns (bool) {
        if (venue == poolManager) return poolId == PoolId.unwrap(canonical.toId());
        return !inbound || allowedInbound.contains(venue);
    }

    /// @notice Allow or disallow inbound transfers to an external venue. The
    ///         PoolManager is governed by the canonical pool declaration
    ///         rather than this allowlist.
    function setAllowedInbound(address venue, bool allowed) external {
        require(msg.sender == owner);
        require(venue != address(0) && venue != poolManager);
        bool changed = allowed ? allowedInbound.add(venue) : allowedInbound.remove(venue);
        if (changed) {
            emit VenueStatusChanged(venue, bytes32(0), true, allowed);
            emit ExternalVenuesChanged();
        }
    }

    // Enforcement is omitted. A token that can recognise a venue rejects an
    // inbound transfer to an unlisted one with
    // VenueNotAllowed(venue, bytes32(0), true); for v4, a token may require a
    // trusted hook to authorise an aggregate PoolManager transfer and reject
    // missing authorisation with VenueNotAllowed(poolManager, 0, inbound).
}
```

## Security Considerations

- **Net-zero routes and fees.** A transfer-level gate cannot capture the canonical hook's fee on net-zero pass-through routes that avoid the canonical pool. When the token is only credited and debited within a shared venue's accounting, no token transfer occurs for its gate to reject. This applies to v4 and other singleton vaults. Consumers SHOULD honor the routing guidance, but it is not on-chain enforcement. A route that uses the canonical pool still invokes its hook; netting alone does not remove the hook's fees.
- **Self-reported data.** Mode, pool lists, and permissions are claims made by the token. A malicious token can list a pool it later blocks, or declare a venue allowed and refuse it. Consumers MUST still simulate before executing. A policy refusal that conflicts with a cached `Preferred` declaration requires the consumer to refresh that declaration; it does not make the failed route safe. Frontends SHOULD use the declared permissions to decide what to render.
- **Copycat hooks.** A hook or any other contract can implement `IVenuePolicy`. It has no authority over a token that does not itself implement the interface, and consumers MUST NOT read it as such. Only the token, or a trusted token list, speaks for the token.
- **Policy changes.** Mutable modes, lists, and permissions can change between a quote and execution. Consumers SHOULD subscribe to the change events, pin related reads to the same block, and treat a `VenueNotAllowed` revert at execution time as a signal to refresh. Tokens SHOULD make policy changes rare and, where possible, immutable.
- **Empty canonical set.** In `Enforced` mode an empty list excludes boundary-crossing v4 hops; net-zero hops follow rule 1, and external venues follow rule 2. In `Preferred` mode it supplies no recommendations and imposes no venue restriction. Consumers MUST read the mode before interpreting an empty list.
- **Bulk-query limits.** A token can return an expensive or oversized external list. Consumers MAY cap read resources, but MUST NOT treat failure or truncation as a complete policy. Rule 2 provides point queries as the fallback.
- **Event spam.** A token could emit policy-change events on every block to force consumers to re-read. Consumers SHOULD rate-limit re-reads per token.
- **Error selector collisions and wrapping.** `VenueNotAllowed(address,bytes32,bool)` has a fixed selector. A non-conforming contract could revert with the same selector for unrelated reasons. Consumers use the selector to prune routes, never to grant permission, so a collision can only cause a route to be dropped. Conversely, some execution paths discard revert data, so consumers cannot rely on the selector to catch every policy refusal.
- **Token list trust.** The extension lets any list author declare venues for any token. A consumer that trusts a list is trusting its author on this attribute as on every other. On-chain data overrides the extension whenever both exist.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
