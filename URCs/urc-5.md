---
urc: 5
title: Token Venue Policy
status: Discussion
author: 0xBeans
created: 2026-09-15
discussions-to: https://gov.uniswap.org/t/urc-5-token-venue-policy/26307
---

## Abstract

ERC-20 tokens may recommend primary liquidity venues or restrict trading to specific venues, often hooked Uniswap v4 pools. Routers and frontends need to distinguish those preferences from restrictions before constructing transactions. This proposal defines `IVenuePolicy` to declare canonical v4 pools, distinguish preferred, enforced, and disabled venue policies, and expose directional venue permissions through point queries and events. It also defines a standard policy-refusal error and non-binding consumer guidance for routing and liquidity provision.

## Motivation

Some tokens restrict transfers to or from liquidity venues. The token enforces this in its transfer logic by refusing transfers to or from other venues. Nothing on-chain tells a consumer that the policy exists, so consumers discover it the hard way:

- A router simulates a route through a v3 or hookless v4 pool for the token. The simulation reverts on the token transfer, and the router either drops the token or interprets a generic revert as an RPC problem.
- A pool indexer lists a copycat pool for the token. Users add liquidity and then find they cannot trade against it, or cannot withdraw because the token blocks the pool.
- A token allows trading anywhere but keeps its primary liquidity in a hooked pool. It needs a way to make that pool discoverable without excluding other working venues.

Each of these has been resolved bilaterally between individual token teams and individual routers. That does not scale: token launches are not slowing down, and v4 will only grow. The fix should be a discovery rule that a launchpad can adopt once and every consumer can honor once.

[URC-3](./urc-3.md) already establishes the pattern: a contract self-reports something a consumer cannot infer from state, and consumers agree on how to use the report. This proposal applies the same pattern to venue policy.

## Specification

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are to be interpreted as described in RFC 2119. Consumer guidance is non-normative.

### Scope

This proposal covers ERC-20 tokens that declare preferred liquidity venues or an enforced venue policy. A token whose transfer logic refuses transfers to or from some venues is a "venue-gated token". The proposal defines how tokens declare their policy and provides guidance for routers, aggregators, frontends, and pool indexers (together, "consumers").

`Preferred` identifies recommended pools without imposing venue restrictions. `Enforced` means the token enforces its declared venue restrictions on-chain. `Disabled` means there is no active venue policy or canonical pool. These modes do not impose consumer obligations.

A route hop **crosses the token's boundary** when the token is the route's input or output, or when the hop moves the token into or out of a venue (a transfer the token sees). A **net-zero intermediate hop** is one where the token is credited and debited inside a shared venue's accounting within the same route and is never transferred, so the token cannot observe it. This includes the v4 `PoolManager` and other singleton vaults.

A "venue" is any contract that holds the token's balance on behalf of one or more liquidity pools. This includes Uniswap v2 pairs, v3 pools, Liquidity Book pairs, Aerodrome pools, and shared vaults. Because every v4 pool settles through one `PoolManager`, a v4 venue is identified by the pair `(PoolManager address, PoolId)`. `PoolId` is specific to Uniswap v4; all other venues use zero. Other singleton vaults, such as Balancer's Vault, are treated as a single venue: permission applies to the whole vault address, not individual pools within it.

The transfer restrictions in this proposal apply only to transfers to and from venues. Tokens MUST NOT apply those restrictions to transfers between ordinary accounts. Unrelated transfer restrictions, such as account allowlists or pauses, are outside this proposal. Identifying which addresses are venues is outside the scope of this interface.

Every `PoolId` and `PoolKey` in this proposal refers to the canonical Uniswap v4 `PoolManager` on the chain the token is deployed on. Consumers resolve that address from the chain id, as they do for URC-3 and URC-4.

Enforcement mechanisms are token-specific. For external venues, a refused direction means the token rejects transfers in that direction. For v4, `Enforced` means normal transfers into or out of `PoolManager` must be covered by the signed net flow reported by the token's trusted hooks for permitted pools, as described below. It does not mean that every route through a non-canonical pool reverts. V4 settles balances per currency rather than per pool, and multi-hop routes can net out the token's balance changes without transferring it.

### Where the declaration lives

The token MUST be the contract that implements `IVenuePolicy`. It is the authority for its venue preferences and restrictions, it is the key consumers index by, and it can have several canonical pools (an ETH pair and a stable pair) or none on v4 at all. A hook can serve many pools but cannot speak for the token's venues on other protocols, and a hook that is not the token's own has no authority over the token's policy.

An `IVenuePolicy` implementation on any contract other than the token is not a declaration for that token.

### Interface

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice A transfer was refused because of venue policy.
/// @param venue The venue the transfer was refused for.
/// @param poolId The v4 pool id if known, otherwise PoolId.wrap(0).
/// @param inbound True if the refused transfer was into the venue.
error VenueNotAllowed(address venue, PoolId poolId, bool inbound);

/// @notice Declares a token's preferred pools and venue restrictions.
/// @dev ERC-165 id: canonicalPool.selector ^ venueAllowed.selector ^ venueEnforcement.selector.
interface IVenuePolicy {
    enum VenueEnforcement {
        Preferred,
        Enforced,
        Disabled
    }

    /// @notice Starts a complete snapshot. Clear previous indexed entries;
    ///         current entries follow in the same transaction.
    /// @param inboundRestricted Whether unlisted external venues default to refused inbound.
    /// @param outboundRestricted Whether unlisted external venues default to refused outbound.
    event VenuePolicyChanged(VenueEnforcement enforcement, bool inboundRestricted, bool outboundRestricted);

    /// @notice Sets canonical membership and both v4 flow permissions.
    ///         Also emitted when only a direction changes, including retirement.
    event CanonicalPoolChanged(PoolId indexed poolId, bool canonical, bool inbound, bool outbound);

    /// @notice Sets an external venue's permission in one direction.
    event VenueStatusChanged(address indexed venue, bool inbound, bool allowed);

    function venueEnforcement() external view returns (VenueEnforcement);

    /// @notice Whether a v4 pool on this chain's canonical PoolManager is
    ///         canonical. Membership has no preference order.
    function canonicalPool(PoolId poolId) external view returns (bool);

    /// @notice In Enforced mode, whether a v4 pool's flow in this direction
    ///         can cover settlement, or an external venue transfer is permitted.
    ///         A true result does not guarantee execution success.
    /// @param venue The canonical PoolManager or an external venue address.
    /// @param poolId The v4 pool id, or PoolId.wrap(0) for external venues.
    /// @param inbound True for tokens owed to the venue, false for tokens owed by it.
    function venueAllowed(address venue, PoolId poolId, bool inbound) external view returns (bool);
}
```

Four views including ERC-165 `supportsInterface`, three events, one error.

### Token requirements

- A token that implements `IVenuePolicy` MUST implement ERC-165 and MUST return true from `supportsInterface(type(IVenuePolicy).interfaceId)`, including in `Disabled` mode.
- `venueEnforcement()` MUST return `Preferred`, `Enforced`, or `Disabled` (enum values 0, 1, and 2 respectively). In `Preferred` mode the token declares no venue restrictions: `venueAllowed` MUST return true for venue queries within this proposal's scope. Reactive venue refusals require `Enforced` mode. This does not promise that transfers succeed for reasons unrelated to venue policy.
- `canonicalPool(poolId)` MUST identify the token's current canonical v4 pools, without ordering. The set MUST be finite, and each member MUST identify a key containing the declaring token. Retired pools MAY retain outbound permission without remaining canonical.
- In `Disabled` mode, `canonicalPool` MUST return false for every id, `venueAllowed` MUST return true for all in-scope queries. The token MUST impose no venue restrictions in this mode.
- `venueAllowed` MUST reflect the token's declared policy, independently of any transaction-specific authorization needed to execute it. A true result does not guarantee transfer success; holding caps, paused state, or missing execution authorization can still cause failure.
- In `Enforced` mode, `venueAllowed(poolManager, poolId, inbound)` MUST return true in both directions for current canonical pools. A retired canonical pool MAY return false inbound and true outbound. Other v4 pool ids MUST return false. For v4, true means that pool's flow in that direction can cover settlement; false means it cannot, not that every route through the pool reverts. Non-v4 permissions MUST follow the directional rules specified below.
- In `Enforced` mode, a transfer to or from a refused external venue MUST revert with `VenueNotAllowed`. V4 transfers MUST follow the settlement requirements below. A token MUST NOT claim `Enforced` unless it implements these checks. Internal accounting without a token transfer is outside the transfer gate.
- When a transfer is refused because of venue policy, the token MUST revert with `VenueNotAllowed` and MUST NOT revert with any other error for that reason. If the token cannot identify the v4 pool behind a `PoolManager` transfer, it MUST pass zero as `poolId`. Refusals for other reasons are out of scope.
- The token MUST emit the initial policy and all changes as specified below, including for immutable policies. Policy views MUST NOT change without the corresponding events from the token address in the same transaction. This also applies to upgrades and external dependencies. A policy cannot silently change based on a timestamp or block number; ending a launch policy requires a transaction and events.

### V4 settlement

In `Enforced` mode, every v4 pool with permitted flow MUST use a trusted reporting hook; the hook MAY charge zero fee. The token MUST track one signed net balance for the transaction, starting at zero. A positive balance authorizes tokens paid into `PoolManager`; a negative balance authorizes tokens taken out. This balance MUST NOT reset between unlocks in the same transaction. Any unused balance expires at the end of the transaction.

1. The token MUST accept flow reports only from trusted hooks. A report MUST identify an exact registered `PoolKey` containing the token. The hook MUST accept callbacks only from the canonical `PoolManager` and check the key, including its hook address.
2. For swaps and liquidity changes, the reported flow is the negated final caller delta for the token, after hook return-delta adjustments. The hook MUST include any `beforeSwap` adjustment as well as its own returned delta. The liquidity callback's delta already includes `feesAccrued`; adding those fees again would double-count them. Donations report the token amount owed into the pool.
3. A report MUST respect that pool's directional permission. Permitted reports add to the same signed balance, so opposite flows cancel. Separate gross inbound and outbound budgets do not meet this requirement.
4. A normal, nonzero ERC-20 transfer of `amount` into `PoolManager` MUST require a balance of at least `amount` and subtract it. A normal, nonzero transfer of `amount` out MUST require a balance of at most `-amount` and add `amount`. Otherwise the token MUST revert with `VenueNotAllowed`, using a zero pool id when the transfer does not identify a pool. A zero-value transfer does not consume flow.

Transfers between `PoolManager` and a trusted reporting hook MAY be exempt to avoid counting hook fees twice: those fees are already reflected in the final caller delta. This is an address-based exemption, not proof that each such transfer is a fee. Protocol-fee collection from `PoolManager` while it is locked MAY also be exempt because it has no caller delta. Exempt transfers MUST NOT add flow authorization. Transfers between `PoolManager` and other addresses remain subject to the normal check, except for locked protocol-fee collection.

V4 skips a hook's callbacks when that hook initiates the operation itself. A hook that supports its own swaps, liquidity changes, or donations MUST report their flow directly, using the same accounting rules, or refuse those operations.

A retired pool's outbound permission allows its withdrawals to contribute flow while inbound is refused. It also allows swaps that pay the token out; direction alone does not distinguish a withdrawal from a buy.

This check establishes net settlement coverage, not the provenance of every token or the pools used by a route. Net-zero hops need no ERC-20 transfer. ERC-6909 claims can fund swaps or liquidity without a token transfer, and a canonical credit retained as claims or cleared can leave flow that covers a later non-canonical payout in the same transaction. A route involving a non-canonical pool can therefore execute even when that pool's flow is not permitted.

Settlement order also matters. Paying the token before the hook reports its flow fails closed. Opposite flow left over from an earlier operation in the same transaction can make a later canonical transfer fail closed. Multiple unlocks share this balance; protocol-fee collection during an unlock is subject to the normal outbound check. These limits do not impose routing obligations on consumers.

### External venue policy

Non-v4 queries use `venueAllowed(venue, PoolId.wrap(0), inbound)`. The snapshot event supplies a default for each direction: a restricted direction defaults to false and an unrestricted direction defaults to true. Individual `VenueStatusChanged` events supply exceptions. The set of exceptions MUST be finite so events can describe the policy completely.

| Direction | Default permission | Exceptions |
|---|---|---|
| Unrestricted | Permitted | Individual refusals in `Enforced` mode |
| Restricted | Refused | Individually permitted venues |

The two directions are independent. For example, an inbound-restricted policy with an inbound permission for pool `P` permits deposits only to `P`. If outbound is unrestricted, withdrawals are permitted by default, subject to any individual outbound refusals.

Point queries MUST agree with the defaults and exceptions reconstructed from events. External records MUST use a nonzero venue address other than the canonical `PoolManager`. There is no bulk view that omits refusals. A refused transfer uses `VenueNotAllowed` under the token requirements above.

### Events and discovery

The events MUST allow the complete policy to be reconstructed without re-reading its views. Events are applied in log order; each snapshot replaces the state built from all earlier policy events:

1. `VenuePolicyChanged` starts a new snapshot. It replaces the mode and restriction flags and clears all previously indexed canonical pools, v4 permissions, and external permissions. Canonical membership starts false. V4 permissions default to false in `Enforced` mode and true otherwise. Each external direction defaults to false if restricted and true if unrestricted.
2. In the same transaction, the token MUST emit `CanonicalPoolChanged(id, canonical, inbound, outbound)` for each current canonical pool and each pool with non-default v4 permissions, including retired pools that remain outbound-permitted. It MUST emit `VenueStatusChanged(venue, inbound, allowed)` for each external permission that differs from its direction's default. These entries complete the snapshot.
3. A later individual change to canonical membership or either v4 permission MUST emit `CanonicalPoolChanged` with all three new values. Removing canonical membership does not implicitly remove outbound permission; the event states both directions explicitly.
4. A later individual external permission change MUST emit `VenueStatusChanged` for each changed direction. Setting it back to the direction's default removes that exception. The event uses a nonzero external venue address, not the canonical `PoolManager`. It has no pool id.
5. A mode change, restriction-flag change, or complete policy replacement MUST emit a new snapshot. A snapshot MAY also replace individual change events when several entries change. Entries from an older snapshot do not become active again unless the new snapshot includes them.

An initial snapshot MUST be emitted when the token is deployed or initialized, or in the upgrade transaction that first adds this interface. Immutable policies also emit their initial snapshot. For proxies, events from the implementation's constructor do not substitute for events from the token's proxy address. A snapshot in `Preferred` mode has both restriction flags false and no external exceptions; a `Disabled` snapshot also has no canonical members.

After processing all policy events in a transaction, the reconstructed mode, membership, flags, and permissions MUST agree with the views. Current canonical membership and retired-pool permissions are separate parts of the reconstructed state.

These events let indexers find candidate policy tokens by their emitting address. Events from another contract do not establish a policy for a token. The canonical `PoolManager`'s `Initialize` events supply the full keys for initialized v4 pool ids; this interface does not return or rank those keys.

### Consumer guidance

This section is non-binding. Consumers choose their own routing, discovery, and safety requirements; there are no consumer conformance requirements.

Routers and aggregators:

1. `venueEnforcement()` distinguishes recommendations from restrictions and a disabled policy. In `Preferred` mode, canonical pools are recommendations subject to the consumer's hook-support, execution, and safety requirements. In `Enforced` mode, queries report external transfer restrictions or which v4 pool flows can cover settlement. Consumers remain free to use routes that execute successfully, including net-zero intermediate hops. Canonical status does not let a pool skip safety checks.
2. Selling into a venue is inbound; buying out of it is outbound. Consumers can obtain directional permissions from `venueAllowed` or an event history starting from a complete snapshot. Subscribing only to future events does not establish existing permissions. A false v4 permission does not mean every route using that pool fails; settlement coverage depends on the complete transaction.
3. A revert carrying the `VenueNotAllowed` selector on a candidate path means the path was refused. The consumer can drop the path without treating it as a token failure, an RPC failure, or a reason to blacklist the token. The `PoolManager` wraps failed outbound transfers in `WrappedError(address target, bytes4 selector, bytes reason, bytes details)`; consumers can match the selector on the inner `reason` as well as on the outer revert data. Some execution paths discard the original revert data, so absence of the selector does not prove the failure was unrelated to policy.
4. Consumers can maintain cached policy from its events and check or recover it with point queries. Related reads at one block and normal reorganization handling help keep the cache consistent. A failed mode query, unknown mode, or failed permission query is unavailable information, not a declaration that the policy is disabled. Declarations do not replace simulation or execution checks.

Frontends and pool indexers:

5. Frontends can use canonical membership and external permissions to show restrictions or warnings around add-liquidity. In `Preferred` mode, consumers can identify pools outside the canonical set as non-preferred. Normal execution and safety checks still apply.
6. Removing a pool from the canonical set, or a venue becoming disallowed, does not remove existing positions. Consumers can keep remove-liquidity visible and check outbound permission separately. An outbound-only retired pool can still allow withdrawals and buys.

Tokens with neither `IVenuePolicy` nor a trusted token-list declaration are unaffected.

### Token list extension

Non-upgradeable tokens deployed before this proposal cannot add the interface. For those, and as an off-chain mirror, mode and canonical-pool metadata MAY be carried in a token list entry's `extensions` field. The token list schema allows nested objects up to three levels and no arrays, so pools are keyed `pool0`, `pool1`, and so on, without preference ordering:

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

`enforcement` MUST be `"preferred"`, `"enforced"`, or `"disabled"`; if absent, it defaults to `"enforced"`. An unknown value is invalid. A disabled declaration MUST have no pool entries. The keys refer to the canonical `PoolManager` for `chainId`. No `poolN` entries means no current canonical pools. The extension does not describe outbound permissions retained by retired pools. Pool indices MUST be consecutive from zero; they do not rank pools. With the explicit `enforcement` field, the token-list schema's ten-property limit leaves room for up to nine pool entries; a larger policy MUST NOT be silently truncated.

For extension-only tokens, `enforcement` and the `poolN` entries describe the mode and canonical membership. The extension has no external or retired-pool permission representation. The example above illustrates the metadata format; a list declaration is not proof that the token enforces its policy or conforms to this interface.

Which token lists a consumer trusts is the consumer's choice, as it is for every other list-sourced attribute. When both on-chain data and a token list extension exist for a token, on-chain data wins.

### Conformance

A token conforms if it implements `IVenuePolicy`, meets the token and event requirements above, and implements external transfer refusals and v4 settlement coverage as specified, using `VenueNotAllowed` for policy refusals. There are no consumer conformance requirements.

## Rationale

### Token, not hook

The token is the authority for its venue preferences and restrictions. Consumers index by token address, so a token-level view needs no discovery step, and a token may have canonical venues across versions and pairs, which a hook cannot describe.

Allowing a hook to declare on the token's behalf was considered and rejected. A copycat hook could implement the interface and claim a legacy token, and nothing on-chain would contradict it. Tokens that cannot implement the interface use the token list extension instead.

### Preferred, enforced, and disabled policies

A token can recommend its primary pool without forbidding other working liquidity. `Preferred` gives those pools a discovery path while leaving route selection open. `Enforced` describes external transfer refusals and v4 settlement coverage that the token actually checks on-chain. `Disabled` ends the policy without removing interface support.

Transfer enforcement stops at the token's boundary. When the token moves into or out of a venue, the token sees the transfer and can refuse it. A net-zero intermediate hop never transfers the token, so transfer logic cannot reject it; this proposal imposes no routing obligation in its place.

The existing values `Preferred = 0` and `Enforced = 1` are preserved, and `Disabled = 2` is appended. Adding a value is not assumed to be backward-compatible: older Solidity callers may reject a value outside the enum they were compiled with. An unsupported mode is unavailable policy, not `Disabled`.

### Point queries and events

`venueAllowed` supplies the permission for a venue and direction. Events describe the full policy, including reactive refusals, so consumers can build a cache without an incomplete bulk list. Separate inbound and outbound permissions let a token refuse deposits while keeping withdrawals open. A new snapshot replaces cached entries when the mode or directional defaults change.

Pool creation is permissionless, so blocking known external venues does not restrict venues created later. A restricted direction instead refuses unlisted venues. The interface reports these choices; it does not identify new venue addresses for the token.

### Canonical `PoolManager` by convention

Neither `PoolKey` nor its `PoolId` carries a manager address. Adding one to the membership query would diverge from URC-3 and URC-4, which take bare keys. This proposal follows them and fixes the manager by chain convention.

### Pool membership by id

`canonicalPool(PoolId)` checks membership without returning every full key. `CanonicalPoolChanged` events identify the members and directional permissions, and the canonical manager's `Initialize` events supply the full keys. A retired pool can lose canonical status while keeping outbound permission.

### Several pools without ordering

Most tokens will declare one pool. Allowing several supports tokens that want both an ETH pair and a stable pair. Membership does not rank those pools.

### One error

Simulation-based routers already classify reverts by selector. A single standard error lets them recognise a policy refusal without parsing token-specific errors or guessing from generic reverts. Making it a file-level error rather than an interface member means a router can import the selector without depending on the interface. Because v4 wraps outbound transfer failures, the guidance tells consumers to look inside `WrappedError` too.

### Preflight queries

`venueAllowed` provides a cheap check for routers filtering candidate paths and frontends deciding which liquidity forms to render. Keeping the query limited to venue policy avoids duplicating the token's transfer logic. The query does not replace transaction simulation.

### Direction on `VenueStatusChanged`

A token can block inbound transfers to a venue while leaving outbound open so that positions can be withdrawn. Without a direction the event could not describe that change, so it carries `inbound` and mirrors the shape of `venueAllowed`.

### Events instead of polling

Policy change events let consumers cache declarations and update them when the mode, canonical pools, or external permissions change. `VenuePolicyChanged` starts a snapshot with the mode and restriction flags; current canonical members, non-default v4 permissions, and external permission exceptions follow in the same transaction. Initial snapshots and later change events let consumers reconstruct the policy without re-reading views. A policy cannot end silently at a timestamp; the change requires a transaction and its events.

### Why consumer guidance and not just an interface

The guidance explains how consumers can use venue declarations without prescribing routes or frontend behavior. The standard defines token behavior, not consumer conformance.

## Backwards Compatibility

Tokens with neither `IVenuePolicy` nor a trusted token-list declaration are unaffected. Consumers that ignore this proposal continue to work as they do today, with the failure modes described in Motivation.

Non-upgradeable deployed tokens cannot add the interface. The token list extension carries mode and canonical v4 metadata for them until their next token version; it cannot add on-chain enforcement.

The `VenueNotAllowed` error is new. Tokens already deployed with their own policy errors cannot change them; consumers can additionally recognise those errors on a per-token basis, but this proposal does not require it.

Replacing `canonicalPools()` with `canonicalPool(PoolId)` and removing `externalVenues()` changes the ERC-165 interface id from the earlier draft. `PoolId` is used consistently in Solidity; its ABI type remains `bytes32`. Integrations can detect support for the current interface; a missing `venueEnforcement()` view does not establish `Preferred` or `Disabled`. A legacy token-list declaration without `enforcement` still defaults to `enforced`.

`Preferred = 0` and `Enforced = 1` are preserved; `Disabled = 2` is appended. Older Solidity callers may reject an enum value they do not recognize.

`VenuePolicyChanged` replaces `VenueEnforcementChanged` and `ExternalVenuesChanged` with a snapshot of the mode and restriction flags, followed by all current entries. `CanonicalPoolChanged` replaces `CanonicalPoolsChanged` with an individual membership and directional-permission update. `VenueStatusChanged` reports external permissions and drops the always-zero pool-id argument. These changes also change the event signatures. Indexers using the earlier events need to adopt the snapshot and initialization rules. Existing `poolN` entries now identify an unordered set.

V4 `venueAllowed` now describes settlement coverage. A false v4 result does not promise that every route through that pool reverts.

## Test Cases

Unless otherwise specified, these cases use a token `T` in `Enforced` mode with one canonical key `K` on `PoolManager` `PM` (`canonicalPool(K.toId())` returns true), and a copycat pool `K'` for the same pair with a different hook. Its external policy restricts inbound transfers to an allowlist containing one v3 pool `P` and leaves outbound unrestricted with no reactive refusals. Its snapshot starts with `VenuePolicyChanged(Enforced, true, false)` and includes the canonical pool and an inbound permission for `P`. `Q` is another v3 pool for `T`, not on the allowlist.

Consumer-related cases illustrate optional uses of the declaration; they do not impose routing or frontend requirements.

| Case | Call | Expected |
|---|---|---|
| ERC-165 | `T.supportsInterface(type(IVenuePolicy).interfaceId)` | `true` |
| Mode | `T.venueEnforcement()` | `Enforced` |
| Canonical inbound | `T.venueAllowed(PM, K.toId(), true)` | `true` |
| Canonical outbound | `T.venueAllowed(PM, K.toId(), false)` | `true` |
| Copycat declared | `T.venueAllowed(PM, K'.toId(), true)` | `false` |
| Copycat inbound refusal | A swap into `K'` owes `T` to `PM`, with no permitted net flow covering it | Reverts with `VenueNotAllowed(PM, 0, true)` |
| Copycat outbound refusal | A swap out of `K'` takes `T` from `PM`, with no permitted net flow covering it | Reverts with `WrappedError` whose `reason` carries `VenueNotAllowed(PM, 0, false)` |
| Allowlisted v3 inbound | `T.venueAllowed(P, 0, true)` | `true` |
| Unlisted v3 inbound | `T.venueAllowed(Q, 0, true)` | `false` |
| Unrestricted outbound | `T.venueAllowed(Q, 0, false)` | `true` |
| Empty allowlist | Both directions restricted, list is empty | No external venue permitted in either direction |
| Unrestricted | Neither external direction restricted, no exceptions | Point queries return true in both directions |
| Refused v3 transfer | `T` refuses `T.transfer(Q, amount)` on policy grounds | Reverts with `VenueNotAllowed(Q, 0, true)` |
| Reactive refusal | Both external directions unrestricted; `T` blocks inbound transfers to Liquidity Book pair `L` | `venueAllowed(L, 0, true)` is false, outbound is true; the snapshot includes the inbound refusal |
| Reactive refusal event | `T` introduces the inbound block on `L` above | Emits `VenueStatusChanged(L, true, false)`; no `VenuePolicyChanged` snapshot is required because the mode and restriction flags are unchanged |
| Reactive refusal removed | `T` removes that block | `venueAllowed(L, 0, true)` becomes true and `VenueStatusChanged(L, true, true)` is emitted |
| Refusal at execution | A venue is reactively blocked after a quote; a transfer is then refused | Reverts with `VenueNotAllowed`; a consumer may drop the path and refresh the permission |
| Missing cache baseline | Router subscribes only to future events | The cache lacks existing permissions; a point query or replay from a complete policy snapshot supplies the missing baseline |
| Set change | Token adds a second canonical pool | `CanonicalPoolChanged(id, true, true, true)` emitted in the same transaction; `canonicalPool` returns true for both pools |
| Venue change | Token removes `P` from the inbound allowlist | `VenueStatusChanged(P, true, false)` emitted in the same transaction; point queries agree |
| Restriction change | Token marks outbound restricted | Emits `VenuePolicyChanged(Enforced, true, true)` followed by current canonical members, retired-pool permissions, and non-default external permissions in the same transaction; earlier indexed entries are replaced |
| Mode change | Token switches to `Preferred`, clearing external restrictions | Emits `VenuePolicyChanged(Preferred, false, false)` followed by all current canonical members in the same transaction; no external exceptions remain |
| Router candidates | Router asked to route `T` with `K`, `K'`, `P` and `Q` liquid | `K` can cover settlement; `K'` cannot contribute flow. `P` is permitted both ways and `Q` for buys only. The router decides how to use the declaration |
| Other-protocol boundary hop | Route sells `T` into an Aerodrome pool absent from the inbound allowlist | A transfer into that venue reverts with `VenueNotAllowed`, just as for an unlisted v3 pool |
| Ordinary accounts | `T` moves between ordinary accounts while inbound venues are restricted | Venue restrictions do not apply; unrelated token transfer rules remain unaffected |
| Non-v4 singleton | Non-v4 vault `V` holds balances for several pools | Queries use `(V, 0, inbound)`; the answer applies to the whole vault in that direction, not individual pools |
| Enforced boundary hop | Route buys or sells `T` through `K'` | Normal transfers require permitted signed net flow; a route through `K'` can succeed when that coverage exists |
| Enforced intermediate hop | Route uses `T` only as a net-zero intermediary in `K'` | No token transfer occurs for transfer-level enforcement to reject; the proposal imposes no routing prohibition |
| Non-v4 net-zero hop | `T` is credited and debited within vault `V` without a transfer; its inbound permission is false | No token transfer occurs for transfer-level enforcement to reject; the proposal imposes no routing prohibition |
| Unknown net-zero permission | An unrestricted vault direction has no initialized cache and its point query fails | Permission is unavailable, not known to be true or false; consumers choose how to handle that uncertainty |
| Preferred discovery | A `Preferred` token declares `K`, while `K'` also has liquidity | `K` may be considered subject to normal support and safety checks; `K'` may also be used |
| Preferred external policy | Query a `Preferred` token's external policy | Point queries permit all external venues; snapshot flags are false with no external exceptions |
| Preferred reactive refusal | A `Preferred` token reports false for an individual venue | Non-conforming; reactive venue refusals require `Enforced` mode |
| Preferred add-liquidity | User opens add-liquidity on `K'` for a `Preferred` token | May be offered subject to normal checks, with a non-preferred badge |
| Unsupported mode | Mode query fails or returns an unknown value | Policy is unavailable, not disabled; consumers choose whether to offer routes or liquidity actions |
| Legacy list mode | Token-list declaration omits `enforcement` | Treated as `enforced` |
| Frontend add-liquidity | User opens add-liquidity on `K'` or `Q` | A consumer may disable or omit add-liquidity, or warn that the pool is unsupported |
| Frontend reactive refusal | Inbound unrestricted, but a point query or initialized cache reports the venue blocked | A consumer may disable or omit add-liquidity, or display a warning |
| Frontend remove-liquidity | Token retires `K` with outbound permission retained | Emits `CanonicalPoolChanged(K.toId(), false, false, true)`; withdrawals and buys can still contribute outbound flow |
| Canonical membership | `T.canonicalPool(K.toId())` and `T.canonicalPool(K'.toId())` | `true` and `false`, respectively; membership has no preference ordering |
| False enforcement claim | An external refused transfer succeeds, or a normal v4 settlement succeeds without matching signed net flow | Non-conforming |
| Empty enforced canonical set | `canonicalPool` returns false for every id | No active canonical pool; retired pools may still have outbound permission. Normal PM transfers still require net-flow coverage |
| Initial policy | Token is deployed or initialized | Emits `VenuePolicyChanged` followed by all current members, non-default v4 permissions, and external exceptions in the same transaction, including for an immutable policy |
| Upgrade adds interface | A proxy token first gains `IVenuePolicy` through an upgrade | The upgrade transaction emits the complete initial snapshot from the token proxy address |
| Disabled policy | Token switches to `Disabled` | Emits `VenuePolicyChanged(Disabled, false, false)` with no entries; all canonical queries are false and all in-scope permissions are true |
| Disabled interface support | `T.supportsInterface(type(IVenuePolicy).interfaceId)` while disabled | `true`; `Preferred = 0`, `Enforced = 1`, and `Disabled = 2` |
| Re-enable policy | A disabled token activates a policy again | Emits a fresh complete snapshot; entries from the earlier policy do not return implicitly |
| Silent time transition | A policy view changes after a timestamp or block number without a transaction and corresponding events | Non-conforming |
| Event replay | Replay policy events in transaction and log order | Each `VenuePolicyChanged` clears earlier indexed entries; after the transaction, reconstructed policy agrees with the views |
| Disabled list entry | Token-list declaration uses `enforcement: "disabled"` | No pool entries; an on-chain disabled declaration takes precedence over a stale list policy |
| Permission-only update | A retired pool's outbound permission is removed | Emits `CanonicalPoolChanged(id, false, false, false)` even though membership was already false |
| Retired snapshot | A snapshot replaces a policy containing an outbound-only retired pool | The snapshot includes that pool with `(false, false, true)`; replay preserves its outbound permission |
| Canonical round trip | Canonical liquidity is added and removed before a copycat deposit | Opposite canonical flows cancel; there is no separate gross inbound budget left to authorize the copycat deposit |
| Hook return delta | Canonical swap or liquidity withdrawal charges a hook fee | Coverage uses the final caller delta; the hook-fee movement is not counted again |
| Claims and clearing | A canonical buy is retained as ERC-6909 claims or its credit cleared, then a copycat buy takes the same amount | The payout can succeed using the remaining canonical flow; coverage does not prove pool provenance |
| Claims-funded pool | ERC-6909 claims fund copycat liquidity or a trade without an ERC-20 transfer | The transfer gate is not invoked |
| Pre-settlement | Caller transfers `T` into PM before the canonical callback | Fails without previously reported positive flow |
| Multiple unlocks | Earlier flow remains in the transaction | Later unlocks use the same signed balance; opposite leftovers can make a canonical transfer fail closed |
| Protocol fees | Protocol fees are collected while PM is locked, then during an unlock | Locked collection may be exempt; unlocked collection needs matching outbound flow |

## Reference Implementation

The [reference token](../assets/urc-5/src/VenueGatedToken.sol) and [reporting hook](../assets/urc-5/src/CanonicalFlowHook.sol) implement the [interface](../assets/urc-5/src/IVenuePolicy.sol) against Uniswap v4. The [test setup](../assets/urc-5/README.md) includes pinned dependencies and tests against a real `PoolManager`.

The token uses immutable `Enforced` mode. Its owner binds one trusted hook, registers exact canonical keys before their pools are initialized, and can retire a pool while retaining outbound permission. The token also refuses transfers to and from one known external venue supplied at deployment. Other external venues and ordinary-account transfers remain unrestricted.

The hook reports swaps, liquidity changes, and donations to one signed transient balance in the token. It includes its return-delta fees in the final caller delta. Its illustrative fee applies only to positive caller output: the unspecified output on exact-input swaps and token output on liquidity operations. It does not charge an input-side fee on exact-output swaps or initial deposits. The hook has no entry point for initiating its own swaps, liquidity changes, or donations; extensions that add them need direct flow reporting because v4 skips the callbacks.

The example enforces net settlement coverage. It does not guarantee that every pool in a route is canonical. The tests include working non-canonical routes through netting and ERC-6909 claims, along with the settlement-order and protocol-fee limits described above.

## Security Considerations

- **Shared settlement.** A transfer to or from `PoolManager` does not identify the contributing pools. Signed net-flow coverage does not prove that only canonical pools were used. ERC-6909 claims, cleared credits, and internal netting can allow non-canonical routes to execute. This check cannot provide a per-pool transfer blacklist.
- **Net-zero routes and fees.** A transfer-level gate cannot capture the canonical hook's fee on net-zero pass-through routes that avoid the canonical pool. When the token is only credited and debited within a shared venue's accounting, no token transfer occurs for its gate to reject. This applies to v4 and other singleton vaults. This proposal imposes no consumer routing obligation in place of on-chain enforcement. A route that uses the canonical pool still invokes its hook; netting alone does not remove the hook's fees.
- **Self-reported data.** Mode, pool membership, and permissions are claims made by the token. A malicious token can list a pool it later blocks, or declare a venue allowed and refuse it. Declarations do not replace simulation before executing. A policy refusal that conflicts with a cached `Preferred` or `Disabled` declaration is a reason to refresh that declaration; it does not make the failed route safe. Frontends can use the declared permissions to decide what to render.
- **Copycat hooks.** A hook or any other contract can implement `IVenuePolicy`. It has no authority over a token that does not itself implement the interface. Only the token, or a trusted token list, speaks for the token.
- **Policy changes.** Mutable modes, lists, and permissions can change between a quote and execution. Consumers can subscribe to the change events, pin related reads to the same block, and treat a `VenueNotAllowed` revert at execution time as a signal to refresh. Tokens SHOULD make policy changes rare and, where possible, immutable.
- **Empty canonical set.** In `Enforced` mode an empty set has no current canonical pools, but retired pools may retain outbound permission. Consumers can query those permissions separately. Net-zero hops perform no token transfer, and external venues follow their declared permissions. In `Preferred` mode an empty set supplies no recommendations; `Disabled` has no canonical pools or venue restrictions.
- **Trusted accounting.** A reporting hook can authorize settlement, so its access checks, key checks, and delta accounting are part of the token's enforcement. Hook fees must be included exactly once. Hook-transfer exemptions apply only to the trusted hook and `PoolManager`, and locked outbound exemptions depend on the manager's lock state. The reference pins the v4 version used for that check.
- **Settlement order.** The balance lasts for the whole transaction. Prepayment, retained credits, multiple unlocks, and protocol-fee collection during an unlock can make otherwise canonical operations fail. Simulation needs to cover the complete transaction.
- **Retired pools.** Outbound-only permission preserves an exit path but also permits buys from that pool. It is not a withdrawal-only switch.
- **Event spam.** A token could emit policy-change events on every block to burden consumers. Consumers can limit resources spent on indexing each token.
- **Error selector collisions and wrapping.** `VenueNotAllowed(address,bytes32,bool)` has a fixed selector. A non-conforming contract could revert with the same selector for unrelated reasons. Consumers can use the selector to prune routes, not to grant permission, so a collision can only cause a route to be dropped. Conversely, some execution paths discard revert data, so consumers cannot rely on the selector to catch every policy refusal.
- **Token list trust.** The extension lets any list author declare venues for any token. A consumer that trusts a list is trusting its author on this attribute as on every other. On-chain data overrides the extension whenever both exist.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
