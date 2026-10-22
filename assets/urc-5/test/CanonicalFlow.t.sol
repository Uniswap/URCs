// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IVenuePolicy, VenueNotAllowed} from "../src/IVenuePolicy.sol";
import {VenueGatedToken} from "../src/VenueGatedToken.sol";
import {CanonicalFlowHook} from "../src/CanonicalFlowHook.sol";

contract QuoteToken is ERC20 {
    constructor() ERC20("Quote", "Q") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev All swaps, LP operations, claims and fees use an actual v4 PoolManager.
///      The fixture impersonates the trusted hook only to fund pre-existing
///      copycat liquidity. Individual tests never use that privilege to settle.
contract CanonicalFlowTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    enum Op {
        Modify,
        Swap,
        Donate,
        Settle,
        MintClaims,
        BurnClaims,
        Clear,
        AssertNet,
        Prepay,
        Collect,
        ZeroTransfer,
        Seed
    }

    struct Action {
        Op op;
        bool copycat;
        bool sell;
        int256 amount;
        bool claims;
    }
    address constant BLOCKED = address(0xB10C);
    address constant ALICE = address(0xA11CE);
    uint160 constant HOOK_FLAGS = 0x2557;
    uint160 constant Q96 = 79228162514264337593543950336;
    int256 constant LIQUIDITY = 100_000 ether;
    IPoolManager manager;
    IPoolManager pm;
    VenueGatedToken token;
    QuoteToken quote;
    CanonicalFlowHook hook;
    PoolKey canonical;
    PoolKey copycat;
    bool tokenIs0;
    int256 public observedNet;
    int256 public observedTokenDelta;
    int256 public observedFees;
    int256 public observedCallerDelta;

    function setUp() public {
        _deploy(0);
    }

    function _deploy(uint24 feeBps) internal {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        pm = IPoolManager(address(manager));
        token = new VenueGatedToken(address(manager), BLOCKED);
        quote = new QuoteToken();
        address hookAddress = address(uint160(0x100000) | HOOK_FLAGS);
        deployCodeTo("CanonicalFlowHook.sol:CanonicalFlowHook", abi.encode(pm, token, feeBps), hookAddress);
        hook = CanonicalFlowHook(payable(hookAddress));
        token.setCanonicalHook(hookAddress);
        tokenIs0 = address(token) < address(quote);
        canonical = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : address(quote)),
            currency1: Currency.wrap(tokenIs0 ? address(quote) : address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        copycat = canonical;
        copycat.hooks = IHooks(address(0));
        token.registerCanonicalPool(canonical);
        manager.initialize(canonical, Q96);
        manager.initialize(copycat, Q96);

        // The hook funds only the pre-existing copycat fixture below.
        // The first canonical deposit starts with an empty PoolManager.
        token.transfer(hookAddress, 10_000 ether);
        _run(_a(Op.Modify, false, false, LIQUIDITY, false), true);
        _run(_a(Op.Seed, true, false, LIQUIDITY, false), false);
        assertEq(token.canonicalNet(), 0);
    }

    function _a(Op op, bool cc, bool sell, int256 amount, bool claims) internal pure returns (Action memory) {
        return Action(op, cc, sell, amount, claims);
    }

    function _run(Action memory action, bool settle) internal {
        Action[] memory actions = new Action[](settle ? 2 : 1);
        actions[0] = action;
        if (settle) actions[1] = _a(Op.Settle, false, false, 0, false);
        manager.unlock(abi.encode(actions));
    }

    function _actions(Action[] memory actions) internal {
        manager.unlock(abi.encode(actions));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        Action[] memory actions = abi.decode(data, (Action[]));
        for (uint256 i; i < actions.length; ++i) {
            Action memory a = actions[i];
            PoolKey memory key = a.copycat ? copycat : canonical;
            if (a.op == Op.Modify || a.op == Op.Seed) {
                (BalanceDelta delta, BalanceDelta fees) = manager.modifyLiquidity(
                    key, IPoolManager.ModifyLiquidityParams(-600, 600, a.amount, bytes32(0)), ""
                );
                observedFees = _leg(fees);
                observedCallerDelta = _leg(delta);
                observedNet = token.canonicalNet();
                observedTokenDelta = _tokenDelta();
                if (a.op == Op.Seed) {
                    _settleFromHook();
                    _settleQuote();
                }
            } else if (a.op == Op.Swap) {
                bool zeroForOne = a.sell ? tokenIs0 : !tokenIs0;
                BalanceDelta delta = manager.swap(
                    key,
                    IPoolManager.SwapParams(
                        zeroForOne, a.amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                    ""
                );
                observedCallerDelta = _leg(delta);
                observedNet = token.canonicalNet();
                observedTokenDelta = _tokenDelta();
            } else if (a.op == Op.Donate) {
                manager.donate(key, tokenIs0 ? uint256(a.amount) : 0, tokenIs0 ? 0 : uint256(a.amount), "");
                observedNet = token.canonicalNet();
                observedTokenDelta = _tokenDelta();
            } else if (a.op == Op.Settle) {
                _settleToken(a.claims);
                _settleQuote();
            } else if (a.op == Op.MintClaims) {
                uint256 amount = a.amount == 0 ? uint256(_tokenDelta()) : uint256(a.amount);
                manager.mint(address(this), uint256(uint160(address(token))), amount);
            } else if (a.op == Op.BurnClaims) {
                manager.burn(address(this), uint256(uint160(address(token))), uint256(a.amount));
            } else if (a.op == Op.Clear) {
                manager.clear(Currency.wrap(address(token)), uint256(_tokenDelta()));
            } else if (a.op == Op.AssertNet) {
                assertEq(token.canonicalNet(), a.amount);
            } else if (a.op == Op.Prepay) {
                manager.sync(Currency.wrap(address(token)));
                token.transfer(address(manager), uint256(a.amount));
                manager.settle();
            } else if (a.op == Op.ZeroTransfer) {
                int256 netBefore = token.canonicalNet();
                token.transfer(address(manager), 0);
                manager.take(Currency.wrap(address(token)), address(this), 0);
                assertEq(token.canonicalNet(), netBefore);
            } else if (a.op == Op.Collect) {
                manager.collectProtocolFees(ALICE, Currency.wrap(address(token)), uint256(a.amount));
            }
        }
        return "";
    }

    function _leg(BalanceDelta delta) internal view returns (int256) {
        return tokenIs0 ? int256(delta.amount0()) : int256(delta.amount1());
    }

    function _tokenDelta() internal view returns (int256) {
        return pm.currencyDelta(address(this), Currency.wrap(address(token)));
    }

    function _settleToken(bool claims) internal {
        int256 delta = _tokenDelta();
        if (delta < 0) {
            uint256 amount = uint256(-delta);
            if (claims) {
                manager.burn(address(this), uint256(uint160(address(token))), amount);
            } else {
                manager.sync(Currency.wrap(address(token)));
                token.transfer(address(manager), amount);
                manager.settle();
            }
        } else if (delta > 0) {
            if (claims) manager.mint(address(this), uint256(uint160(address(token))), uint256(delta));
            else manager.take(Currency.wrap(address(token)), address(this), uint256(delta));
        }
    }

    function _settleQuote() internal {
        int256 delta = pm.currencyDelta(address(this), Currency.wrap(address(quote)));
        if (delta < 0) {
            manager.sync(Currency.wrap(address(quote)));
            quote.transfer(address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(Currency.wrap(address(quote)), address(this), uint256(delta));
        }
    }

    function _settleFromHook() internal {
        int256 delta = _tokenDelta();
        assertLt(delta, 0);
        manager.sync(Currency.wrap(address(token)));
        vm.prank(address(hook));
        token.transfer(address(manager), uint256(-delta));
        manager.settle();
    }

    function _inboundError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(VenueNotAllowed.selector, address(manager), PoolId.wrap(0), true);
    }

    function _outboundError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(token),
            bytes4(0xa9059cbb),
            abi.encodeWithSelector(VenueNotAllowed.selector, address(manager), PoolId.wrap(0), false),
            abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
        );
    }

    function testCanonicalBuySellExactInputAndOutput() public {
        for (uint256 i; i < 4; ++i) {
            bool sell = i < 2;
            int256 amount = i % 2 == 0 ? -int256(1 ether) : int256(1 ether);
            _run(_a(Op.Swap, false, sell, amount, false), true);
            assertEq(observedNet, -observedCallerDelta);
            assertEq(token.canonicalNet(), 0);
        }
    }

    function testCanonicalLiquidityAndDonation() public {
        _run(_a(Op.Modify, false, false, 100 ether, false), true);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
        _run(_a(Op.Donate, false, false, 1 ether, false), true);
        assertEq(observedNet, 1 ether);
        assertEq(token.canonicalNet(), 0);
        _run(_a(Op.Modify, false, false, -100 ether, false), true);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
    }

    function testCopycatAloneCannotDepositOrSell() public {
        vm.expectRevert(_inboundError());
        _run(_a(Op.Modify, true, false, 100 ether, false), true);
        vm.expectRevert(_inboundError());
        _run(_a(Op.Swap, true, true, -int256(1 ether), false), true);
    }

    function testCopycatAloneCannotPayOut() public {
        vm.expectRevert(_outboundError());
        _run(_a(Op.Swap, true, false, -int256(1 ether), false), true);
        vm.expectRevert(_outboundError());
        _run(_a(Op.Modify, true, false, -100 ether, false), true);
    }

    function testSignedRoundTripCannotLeaveBothDirectionalAllowances() public {
        Action[] memory a = new Action[](4);
        a[0] = _a(Op.Swap, false, true, -int256(1 ether), false);
        a[1] = _a(Op.Swap, false, false, int256(1 ether), false);
        a[2] = _a(Op.AssertNet, false, false, 0, false);
        a[3] = _a(Op.Settle, false, false, 0, false);
        _actions(a);
        assertEq(token.canonicalNet(), 0);
        vm.expectRevert(_inboundError());
        _run(_a(Op.Swap, true, true, -int256(1 ether), false), true);
        vm.expectRevert(_outboundError());
        _run(_a(Op.Swap, true, false, int256(1 ether), false), true);
    }

    function testZeroBoundaryTransfersLeaveEitherSignedBalanceUnchanged() public {
        Action[] memory a = new Action[](3);
        a[1] = _a(Op.ZeroTransfer, false, false, 0, false);
        a[2] = _a(Op.Settle, false, false, 0, false);
        for (uint256 i; i < 2; ++i) {
            a[0] = _a(Op.Swap, false, i == 0, -int256(1 ether), false);
            _actions(a);
            if (i == 0) assertGt(observedNet, 0);
            else assertLt(observedNet, 0);
            assertEq(token.canonicalNet(), 0);
        }
    }

    function testLiquidityRoundTripCannotFundCopycatSettlement() public {
        Action[] memory a = new Action[](3);
        a[0] = _a(Op.Modify, false, false, 100 ether, false);
        a[1] = _a(Op.Modify, false, false, -100 ether, false);
        a[2] = _a(Op.Settle, false, false, 0, false);
        _actions(a);
        // Core may round the deposit up and the withdrawal down by one wei.
        assertGe(observedNet, 0);
        assertLe(observedNet, 1);
        assertEq(token.canonicalNet(), 0);
        vm.expectRevert(_inboundError());
        _run(_a(Op.Swap, true, true, -int256(1 ether), false), true);
        vm.expectRevert(_outboundError());
        _run(_a(Op.Swap, true, false, int256(1 ether), false), true);
    }

    function testClaimsFundCopycatLiquidityAndSellWithoutTokenTransfers() public {
        Action[] memory a = new Action[](2);
        a[0] = _a(Op.Swap, false, false, int256(10 ether), false);
        a[1] = _a(Op.Settle, false, false, 0, true);
        _actions(a);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 claimsBefore = manager.balanceOf(address(this), uint256(uint160(address(token))));
        assertEq(claimsBefore, 10 ether);
        a[0] = _a(Op.Modify, true, false, 100 ether, false);
        _actions(a);
        assertLt(observedCallerDelta, 0);
        uint256 claimsAfter = manager.balanceOf(address(this), uint256(uint160(address(token))));
        assertEq(claimsBefore - claimsAfter, uint256(-observedCallerDelta));
        assertEq(token.balanceOf(address(this)), tokenBefore);
        assertEq(token.canonicalNet(), -int256(10 ether));
        a[0] = _a(Op.Swap, true, true, -int256(1 ether), false);
        _actions(a);
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), claimsAfter - 1 ether);
        assertEq(token.balanceOf(address(this)), tokenBefore);
        assertEq(token.canonicalNet(), -int256(10 ether));
    }

    function testPreSettlementFailsClosed() public {
        vm.expectRevert(_inboundError());
        _run(_a(Op.Prepay, false, false, 1 ether, false), false);
    }

    function testSameHookDifferentKeyAndUnauthorizedReportsReject() public {
        PoolKey memory other = canonical;
        other.fee = 500;
        vm.expectRevert();
        manager.initialize(other, Q96);
        vm.expectRevert(VenueGatedToken.NotCanonicalHook.selector);
        token.reportCanonicalFlow(canonical.toId(), 1);
        vm.expectRevert(CanonicalFlowHook.NotPoolManager.selector);
        hook.afterDonate(address(this), canonical, 1, 1, "");
        vm.prank(address(manager));
        vm.expectRevert(CanonicalFlowHook.UnregisteredPool.selector);
        hook.afterDonate(address(this), other, 1, 1, "");
    }

    function testOrdinaryTransfersAndExternalRefusals() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.transfer(address(0xB0B), 30);
        assertEq(token.balanceOf(ALICE), 70);
        vm.expectRevert(abi.encodeWithSelector(VenueNotAllowed.selector, BLOCKED, PoolId.wrap(0), true));
        token.transfer(BLOCKED, 1);
        deal(address(token), BLOCKED, 100);
        vm.prank(BLOCKED);
        vm.expectRevert(abi.encodeWithSelector(VenueNotAllowed.selector, BLOCKED, PoolId.wrap(0), false));
        token.transfer(ALICE, 1);
    }

    function testRetiredPoolAllowsWithdrawalButRejectsNewTokenInputs() public {
        token.retirePool(canonical.toId());
        assertFalse(token.canonicalPool(canonical.toId()));
        assertFalse(token.venueAllowed(address(manager), canonical.toId(), true));
        assertTrue(token.venueAllowed(address(manager), canonical.toId(), false));
        _run(_a(Op.Modify, false, false, -100 ether, false), true);
        _run(_a(Op.Swap, false, false, -int256(1 ether), false), true);
        vm.expectRevert();
        _run(_a(Op.Modify, false, false, 100 ether, false), true);
        vm.expectRevert();
        _run(_a(Op.Swap, false, true, -int256(1 ether), false), true);
    }

    function testNetZeroCanonicalAndCopycatRouteNeedsNoTokenTransfer() public {
        uint256 beforeBalance = token.balanceOf(address(this));
        Action[] memory a = new Action[](3);
        a[0] = _a(Op.Swap, false, false, int256(1 ether), false);
        a[1] = _a(Op.Swap, true, true, -int256(1 ether), false);
        a[2] = _a(Op.Settle, false, false, 0, false);
        _actions(a);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        assertEq(token.canonicalNet(), -int256(1 ether));
    }

    function testOppositeLeftoverCanRejectLaterCanonicalSettlement() public {
        testNetZeroCanonicalAndCopycatRouteNeedsNoTokenTransfer();
        vm.expectRevert(_inboundError());
        _run(_a(Op.Swap, false, true, -int256(0.5 ether), false), true);
    }

    function testClaimsLeaveAuthorizationForCopycatPayoutAcrossUnlocks() public {
        Action[] memory a = new Action[](2);
        a[0] = _a(Op.Swap, false, false, int256(1 ether), false);
        a[1] = _a(Op.Settle, false, false, 0, true);
        _actions(a);
        assertEq(token.canonicalNet(), -int256(1 ether));
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), 1 ether);
        uint256 beforeBalance = token.balanceOf(address(this));
        _run(_a(Op.Swap, true, false, int256(1 ether), false), true);
        assertEq(token.balanceOf(address(this)), beforeBalance + 1 ether);
        assertEq(token.canonicalNet(), 0);
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), 1 ether);
        // Claims cannot be redeemed to ERC20 without fresh authorization.
        a[0] = _a(Op.BurnClaims, false, false, int256(1 ether), false);
        a[1] = _a(Op.Settle, false, false, 0, false);
        vm.expectRevert(_outboundError());
        _actions(a);
    }

    function testClearAlsoLeavesAuthorizationForCopycatPayout() public {
        Action[] memory a = new Action[](3);
        a[0] = _a(Op.Swap, false, false, int256(1 ether), false);
        a[1] = _a(Op.Clear, false, false, 0, false);
        a[2] = _a(Op.Settle, false, false, 0, false);
        _actions(a);
        assertEq(token.canonicalNet(), -int256(1 ether));
        _run(_a(Op.Swap, true, false, int256(1 ether), false), true);
        assertEq(token.canonicalNet(), 0);
    }

    function testClaimsCanFundCanonicalInputWithoutERC20Transfer() public {
        Action[] memory a = new Action[](2);
        a[0] = _a(Op.Swap, false, false, int256(1 ether), false);
        a[1] = _a(Op.Settle, false, false, 0, true);
        _actions(a);
        uint256 beforeBalance = token.balanceOf(address(this));
        a[0] = _a(Op.Swap, false, true, -int256(1 ether), false);
        _actions(a);
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), 0);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        assertEq(token.canonicalNet(), 0);
    }

    function testReturnDeltaFeesAndAccruedLPFeesAreCountedOnce() public {
        _deploy(100);
        uint256 hookBefore = token.balanceOf(address(hook));
        _run(_a(Op.Swap, false, false, -int256(10 ether), false), true);
        assertGt(token.balanceOf(address(hook)), hookBefore);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
        _run(_a(Op.Swap, false, true, -int256(10 ether), false), true);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
        _run(_a(Op.Modify, false, false, 0, false), true); // collect already-accrued LP fees
        assertGt(observedFees, 0);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
        _run(_a(Op.Modify, false, false, 100 ether, false), true);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
        _run(_a(Op.Modify, false, false, -100 ether, false), true);
        assertEq(observedNet, -observedCallerDelta);
        assertEq(token.canonicalNet(), 0);
    }

    function testProtocolFeeCollectionLockedWorksUnlockedNeedsAuthorization() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(canonical, 1000 | (1000 << 12));
        _run(_a(Op.Swap, false, true, -int256(10 ether), false), true);
        uint256 fees = manager.protocolFeesAccrued(Currency.wrap(address(token)));
        assertGt(fees, 0);
        assertEq(token.canonicalNet(), 0);
        vm.expectRevert(_outboundError());
        _run(_a(Op.Collect, false, false, 0, false), false);
        assertEq(manager.protocolFeesAccrued(Currency.wrap(address(token))), fees);
        manager.collectProtocolFees(ALICE, Currency.wrap(address(token)), 0);
        assertEq(token.balanceOf(ALICE), fees);
    }

    function testConstructorSnapshotAndRegistrationEvents() public {
        vm.recordLogs();
        VenueGatedToken fresh = new VenueGatedToken(address(manager), BLOCKED);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4); // snapshot, two external entries, mint
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], keccak256("VenuePolicyChanged(uint8,bool,bool)"));
        assertEq(logs[0].data, abi.encode(IVenuePolicy.VenueEnforcement.Enforced, false, false));
        for (uint256 i = 1; i <= 2; ++i) {
            assertEq(logs[i].emitter, address(fresh));
            assertEq(logs[i].topics[0], keccak256("VenueStatusChanged(address,bool,bool)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(BLOCKED))));
            assertEq(logs[i].data, abi.encode(i == 1, false));
            assertFalse(fresh.venueAllowed(BLOCKED, PoolId.wrap(0), i == 1));
            assertTrue(fresh.venueAllowed(ALICE, PoolId.wrap(0), i == 1));
            assertFalse(fresh.venueAllowed(address(manager), canonical.toId(), i == 1));
        }
        assertFalse(fresh.canonicalPool(canonical.toId()));
        PoolKey memory second = canonical;
        second.fee = 500;
        vm.recordLogs();
        token.registerCanonicalPool(second);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], keccak256("CanonicalPoolChanged(bytes32,bool,bool,bool)"));
        assertEq(logs[0].topics[1], PoolId.unwrap(second.toId()));
        assertEq(logs[0].data, abi.encode(true, true, true));
    }

    function testRejectedTransferFromRollsBackAllowanceAndBalance() public {
        token.approve(ALICE, 100);
        uint256 beforeBalance = token.balanceOf(address(this));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(VenueNotAllowed.selector, BLOCKED, PoolId.wrap(0), true));
        token.transferFrom(address(this), BLOCKED, 10);
        assertEq(token.allowance(address(this), ALICE), 100);
        assertEq(token.balanceOf(address(this)), beforeBalance);
        vm.prank(ALICE);
        vm.expectRevert(_inboundError());
        token.transferFrom(address(this), address(manager), 10);
        assertEq(token.allowance(address(this), ALICE), 100);
        assertEq(token.balanceOf(address(this)), beforeBalance);
    }

    function testOnlyOwnerCanChangePolicyAndHookBindingIsPermanent() public {
        PoolKey memory second = canonical;
        second.fee = 500;
        vm.prank(ALICE);
        vm.expectRevert(VenueGatedToken.NotOwner.selector);
        token.registerCanonicalPool(second);
        vm.prank(ALICE);
        vm.expectRevert(VenueGatedToken.NotOwner.selector);
        token.retirePool(canonical.toId());
        vm.prank(ALICE);
        vm.expectRevert(VenueGatedToken.NotOwner.selector);
        token.setCanonicalHook(address(hook));
        vm.expectRevert(VenueGatedToken.InvalidHook.selector);
        token.setCanonicalHook(address(hook));
    }

    function testPolicyEventsAndERC165() public {
        assertTrue(token.supportsInterface(type(IVenuePolicy).interfaceId));
        assertTrue(token.supportsInterface(0x01ffc9a7));
        assertFalse(token.supportsInterface(0xffffffff));
        assertTrue(token.canonicalPool(canonical.toId()));
        assertFalse(token.canonicalPool(copycat.toId()));
        vm.recordLogs();
        token.retirePool(canonical.toId());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("CanonicalPoolChanged(bytes32,bool,bool,bool)"));
        assertEq(logs[0].topics[1], PoolId.unwrap(canonical.toId()));
        assertEq(logs[0].data, abi.encode(false, false, true));
    }
}
