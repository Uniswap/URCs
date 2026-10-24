// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {VenueGatedToken} from "./VenueGatedToken.sol";

/// @notice Minimal accounting hook with output fees to exercise returned hook deltas.
/// @dev No public method initiates swaps, liquidity changes, or donations from
///      this hook. V4 skips callbacks for self-initiated operations: an extension
///      adding those operations must report their final caller token delta itself.
contract CanonicalFlowHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    error NotPoolManager();
    error UnregisteredPool();
    error UnusedCallback();

    IPoolManager public immutable poolManager;
    VenueGatedToken public immutable token;
    uint24 public immutable feeBps;

    constructor(IPoolManager poolManager_, VenueGatedToken token_, uint24 feeBps_) {
        require(address(poolManager_) == token_.poolManager());
        require(feeBps_ <= 10_000);
        poolManager = poolManager_;
        token = token_;
        feeBps = feeBps_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.afterSwap = true;
        p.afterDonate = true;
        p.afterSwapReturnDelta = true;
        p.afterAddLiquidityReturnDelta = true;
        p.afterRemoveLiquidityReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkKey(key);
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkKey(key);
        // Without a beforeSwap delta, this is the only hook adjustment. V4
        // deducts the returned fee from the caller's unspecified currency leg.
        // Charge only a positive output leg: an input may not have been paid
        // yet, especially in an initially single-sided pool. Exact-output
        // swaps therefore have no illustrative hook fee in this reference.
        bool unspecifiedIs0 = params.zeroForOne != (params.amountSpecified < 0);
        int128 raw = unspecifiedIs0 ? delta.amount0() : delta.amount1();
        int128 fee = _outputFee(raw);
        BalanceDelta hookDelta = unspecifiedIs0 ? toBalanceDelta(fee, 0) : toBalanceDelta(0, fee);
        _report(key, delta - hookDelta);
        _takeFee(unspecifiedIs0 ? key.currency0 : key.currency1, fee);
        return (IHooks.afterSwap.selector, fee);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, _afterLiquidity(key, delta));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, _afterLiquidity(key, delta));
    }

    function afterDonate(address, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _checkKey(key);
        uint256 amount = Currency.unwrap(key.currency0) == address(token) ? amount0 : amount1;
        token.reportCanonicalFlow(key.toId(), amount.toInt256());
        return IHooks.afterDonate.selector;
    }

    function _afterLiquidity(PoolKey calldata key, BalanceDelta delta) private returns (BalanceDelta hookDelta) {
        _checkKey(key);
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token);
        // Fee only a positive caller token leg, so the first deposit into an
        // empty manager works before its input has been settled. An add with
        // accrued fees exceeding its principal input can still have an output.
        int128 fee = _outputFee(tokenIs0 ? delta.amount0() : delta.amount1());
        hookDelta = tokenIs0 ? toBalanceDelta(fee, 0) : toBalanceDelta(0, fee);
        // `delta` already includes feesAccrued. Adding that parameter again
        // would authorize transfers not owed by this operation.
        _report(key, delta - hookDelta);
        _takeFee(tokenIs0 ? key.currency0 : key.currency1, fee);
    }

    function _report(PoolKey calldata key, BalanceDelta callerDelta) private {
        int128 leg = Currency.unwrap(key.currency0) == address(token) ? callerDelta.amount0() : callerDelta.amount1();
        token.reportCanonicalFlow(key.toId(), -int256(leg));
    }

    function _outputFee(int128 delta) private view returns (int128) {
        if (delta <= 0) return 0;
        return (uint256(uint128(delta)) * feeBps / 10_000).toInt128();
    }

    function _takeFee(Currency currency, int128 fee) private {
        if (fee != 0) poolManager.take(currency, address(this), uint256(uint128(fee)));
    }

    function _checkKey(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this) || !token.registeredPool(key.toId())) revert UnregisteredPool();
    }

    // These permissions are disabled in the constructor's address validation.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert UnusedCallback();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert UnusedCallback();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert UnusedCallback();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert UnusedCallback();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert UnusedCallback();
    }
}
