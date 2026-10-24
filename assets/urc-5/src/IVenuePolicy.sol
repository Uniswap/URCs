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
