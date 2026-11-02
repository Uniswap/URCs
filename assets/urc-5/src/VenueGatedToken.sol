// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IVenuePolicy, VenueNotAllowed} from "./IVenuePolicy.sol";

/// @notice Reference token with transaction-wide signed settlement accounting.
/// @dev This demonstrates a transfer gate, not attribution of every internal
///      PoolManager operation to a pool. The bound hook is trusted accounting code.
contract VenueGatedToken is ERC20, ERC165, IVenuePolicy {
    using PoolIdLibrary for PoolKey;

    error NotOwner();
    error NotCanonicalHook();
    error InvalidHook();
    error InvalidPool();

    // Uniswap v4-core Lock.IS_UNLOCKED_SLOT. Pin the matching PoolManager version.
    bytes32 private constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    address public immutable owner;
    address public immutable poolManager;
    address public immutable blockedVenue;
    address public canonicalHook;

    struct PoolPolicy {
        bool registered;
        bool canonical;
        bool inbound;
        bool outbound;
    }

    mapping(PoolId => PoolPolicy) private _pools;

    /// @notice Positive means tokens owed into the manager; negative means owed out.
    /// @dev Persists across unlocks in one transaction, and clears at its end.
    int256 public transient canonicalNet;

    constructor(address poolManager_, address blockedVenue_) ERC20("Gated", "GATED") {
        require(poolManager_ != address(0));
        require(blockedVenue_ != address(0) && blockedVenue_ != poolManager_);
        owner = msg.sender;
        poolManager = poolManager_;
        blockedVenue = blockedVenue_;
        emit VenuePolicyChanged(VenueEnforcement.Enforced, false, false);
        emit VenueStatusChanged(blockedVenue_, true, false);
        emit VenueStatusChanged(blockedVenue_, false, false);
        _mint(msg.sender, 1_000_000 ether);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Bind the accounting hook once, after deploying token then hook.
    function setCanonicalHook(address hook) external onlyOwner {
        if (
            canonicalHook != address(0) || hook.code.length == 0 || hook == poolManager || hook == blockedVenue
                || hook == address(this)
        ) revert InvalidHook();
        canonicalHook = hook;
    }

    /// @notice Register the exact key before initializing its pool.
    function registerCanonicalPool(PoolKey calldata key) external onlyOwner {
        if (
            canonicalHook == address(0) || address(key.hooks) != canonicalHook
                || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
                || (Currency.unwrap(key.currency0) != address(this) && Currency.unwrap(key.currency1) != address(this))
        ) revert InvalidPool();
        PoolId id = key.toId();
        if (_pools[id].registered) revert InvalidPool();
        _pools[id] = PoolPolicy(true, true, true, true);
        emit CanonicalPoolChanged(id, true, true, true);
    }

    /// @notice Stop new token inputs while retaining outbound settlement.
    /// @dev Outbound swaps, as well as liquidity withdrawals, remain permitted.
    function retirePool(PoolId id) external onlyOwner {
        PoolPolicy storage policy = _pools[id];
        if (!policy.registered || !policy.canonical) revert InvalidPool();
        policy.canonical = false;
        policy.inbound = false;
        emit CanonicalPoolChanged(id, false, false, true);
    }

    function registeredPool(PoolId id) external view returns (bool) {
        return _pools[id].registered;
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(IVenuePolicy).interfaceId || super.supportsInterface(id);
    }

    function venueEnforcement() external pure returns (VenueEnforcement) {
        return VenueEnforcement.Enforced;
    }

    function canonicalPool(PoolId id) external view returns (bool) {
        return _pools[id].canonical;
    }

    function venueAllowed(address venue, PoolId id, bool inbound) public view returns (bool) {
        if (venue == poolManager) return inbound ? _pools[id].inbound : _pools[id].outbound;
        return venue != blockedVenue;
    }

    /// @notice Report the negative of the final caller token delta of an operation.
    function reportCanonicalFlow(PoolId id, int256 owed) external {
        if (msg.sender != canonicalHook) revert NotCanonicalHook();
        PoolPolicy memory policy = _pools[id];
        if (!policy.registered) revert InvalidPool();
        if ((owed > 0 && !policy.inbound) || (owed < 0 && !policy.outbound)) {
            revert VenueNotAllowed(poolManager, id, owed > 0);
        }
        canonicalNet += owed;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == blockedVenue) revert VenueNotAllowed(from, PoolId.wrap(0), false);
        if (to == blockedVenue) revert VenueNotAllowed(to, PoolId.wrap(0), true);

        if (to == poolManager && from != canonicalHook) {
            _settleTransfer(value, true);
        } else if (from == poolManager && to != canonicalHook) {
            // Allow protocol-fee collection while locked; it has no caller delta.
            if (IExttload(poolManager).exttload(IS_UNLOCKED_SLOT) != bytes32(0)) {
                _settleTransfer(value, false);
            }
        }
        super._update(from, to, value);
    }

    function _settleTransfer(uint256 value, bool inbound) private {
        if (value == 0) return;
        if (value > uint256(type(int256).max)) revert VenueNotAllowed(poolManager, PoolId.wrap(0), inbound);
        int256 amount = int256(value);
        int256 net = canonicalNet;
        if (inbound) {
            if (net < amount) revert VenueNotAllowed(poolManager, PoolId.wrap(0), true);
            canonicalNet = net - amount;
        } else {
            if (net > -amount) revert VenueNotAllowed(poolManager, PoolId.wrap(0), false);
            canonicalNet = net + amount;
        }
    }
}
