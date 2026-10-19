// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LpGauge} from "src/LpGauge.sol";
import {BaskUsdgGauge} from "src/BaskUsdgGauge.sol";
import {ItemEthGauge} from "src/ItemEthGauge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @dev Ghost balances track successful transfers, independently of the gauge's accounting.
/// Only advanceTime changes the clock; active time is counted from the ghost LP balance.
contract GaugeSequenceHandler is Test {
    uint256 public constant INITIAL_LP = 1e27;
    uint256 public constant DURATION = 1460 days;
    LpGauge public immutable gauge;
    MockERC20 public immutable item;
    MockERC20 public immutable lp;
    address[4] public actors;
    uint256[4] public deposits;
    uint256[4] public withdrawals;
    uint256[4] public paidTo;
    uint256 public ghostTotal;
    uint256 public ghostPaid;
    uint256 public ghostDonated;
    uint256 public ghostActiveSeconds;
    uint256 public checkpoints;

    constructor(LpGauge gauge_, MockERC20 item_, MockERC20 lp_) {
        gauge = gauge_;
        item = item_;
        lp = lp_;
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("gauge-sequence-actor-", vm.toString(i)));
            actors[i] = actor;
            lp.mint(actor, INITIAL_LP);
            vm.prank(actor);
            lp.approve(address(gauge), type(uint256).max);
        }
    }

    function stake(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % actors.length;
        uint256 available = INITIAL_LP - (deposits[i] - withdrawals[i]);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        uint256 rewardBefore = item.balanceOf(actors[i]);
        vm.prank(actors[i]);
        gauge.stake(amount);
        deposits[i] += amount;
        ghostTotal += amount;
        ++checkpoints;
        assertEq(item.balanceOf(actors[i]), rewardBefore, "stake paid ITEM");
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed, bool all) external {
        uint256 i = actorSeed % actors.length;
        uint256 amount = deposits[i] - withdrawals[i];
        if (amount == 0) return;
        if (!all) amount = bound(amountSeed, 1, amount);
        _withdraw(i, amount);
    }

    function claim(uint256 actorSeed) external {
        _claim(actorSeed % actors.length);
    }

    function advanceTime(uint256 secondsSeed) external {
        uint256 elapsed = bound(secondsSeed, 0, 500 days);
        if (ghostTotal != 0) {
            ghostActiveSeconds += elapsed;
            if (ghostActiveSeconds > DURATION) ghostActiveSeconds = DURATION;
        }
        vm.warp(vm.getBlockTimestamp() + elapsed);
    }

    function donateIgnoredItem(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 1e27);
        item.mint(address(gauge), amount);
        ghostDonated += amount;
    }

    /// @dev Entry, exit and payment are in one transaction and must earn no historical release.
    function instantaneousRoundTrip(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = actorSeed % actors.length;
        uint256 available = INITIAL_LP - (deposits[i] - withdrawals[i]);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        uint256 beforeLp = lp.balanceOf(actors[i]);
        uint256 beforeStake = gauge.staked(actors[i]);
        uint256 beforeOwed = gauge.earned(actors[i]);
        uint256 beforeItem = item.balanceOf(actors[i]);
        vm.startPrank(actors[i]);
        gauge.stake(amount);
        gauge.withdraw(amount);
        gauge.claim();
        vm.stopPrank();
        uint256 paid = item.balanceOf(actors[i]) - beforeItem;
        assertEq(paid, beforeOwed, "same-timestamp LP earned past rewards");
        assertEq(lp.balanceOf(actors[i]), beforeLp, "LP round trip changed principal");
        assertEq(gauge.staked(actors[i]), beforeStake);
        paidTo[i] += paid;
        ghostPaid += paid;
        checkpoints += 3;
    }

    function overWithdraw(uint256 actorSeed, uint256 excessSeed) external {
        uint256 i = actorSeed % actors.length;
        uint256 amount = deposits[i] - withdrawals[i] + bound(excessSeed, 1, INITIAL_LP);
        vm.expectRevert(LpGauge.InsufficientStake.selector);
        vm.prank(actors[i]);
        gauge.withdraw(amount);
    }

    /// @dev Repeatedly reaching the empty state exercises pauses and subsequent restarts.
    function exitEveryone() external {
        _exitEveryone();
    }

    /// @dev Called after each campaign, never selected as a random action.
    function finishAndClaimAll() external {
        _exitEveryone();
        for (uint256 i; i < actors.length; ++i) {
            _claim(i);
            assertEq(gauge.earned(actors[i]), 0, "last claimer was not paid in full");
            assertEq(lp.balanceOf(actors[i]), INITIAL_LP, "principal not returned");
        }
        assertEq(gauge.totalStaked(), 0);
    }

    function _exitEveryone() private {
        for (uint256 i; i < actors.length; ++i) {
            uint256 amount = deposits[i] - withdrawals[i];
            if (amount != 0) _withdraw(i, amount);
        }
    }

    function _withdraw(uint256 i, uint256 amount) private {
        uint256 beforeLp = lp.balanceOf(actors[i]);
        uint256 beforeItem = item.balanceOf(actors[i]);
        uint256 beforeOwed = gauge.earned(actors[i]);
        vm.prank(actors[i]);
        gauge.withdraw(amount);
        assertEq(lp.balanceOf(actors[i]) - beforeLp, amount, "withdraw lost LP");
        assertEq(item.balanceOf(actors[i]), beforeItem, "withdraw paid ITEM");
        assertEq(gauge.earned(actors[i]), beforeOwed, "exit erased accrued reward");
        withdrawals[i] += amount;
        ghostTotal -= amount;
        ++checkpoints;
    }

    function _claim(uint256 i) private {
        uint256 beforeItem = item.balanceOf(actors[i]);
        uint256 owed = gauge.earned(actors[i]);
        vm.prank(actors[i]);
        gauge.claim();
        uint256 paid = item.balanceOf(actors[i]) - beforeItem;
        assertEq(paid, owed, "claim differed from current earned");
        assertEq(gauge.earned(actors[i]), 0, "claim left whole wei unpaid");
        paidTo[i] += paid;
        ghostPaid += paid;
        ++checkpoints;
    }
}

abstract contract GaugeInvariantBase is Test {
    uint256 internal constant DURATION = 1460 days;
    address internal constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    LpGauge internal gauge;
    MockERC20 internal item;
    MockERC20 internal lp;
    GaugeSequenceHandler internal handler;
    uint256 internal allocation;

    function _deploy(address item_) internal virtual returns (LpGauge);

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_700_000_000);
        item = new MockERC20();
        lp = new MockERC20();
        gauge = _deploy(address(item));
        allocation = gauge.ALLOCATION();
        vm.etch(FACTORY, address(new MockV2Factory()).code);
        MockV2Factory(FACTORY).setPair(gauge.tokenA(), gauge.tokenB(), address(lp));
        item.mint(address(this), allocation);
        item.approve(address(gauge), allocation);
        gauge.start();
        handler = new GaugeSequenceHandler(gauge, item, lp);
        handler.stake(0, 1);
        handler.stake(1, 1e27);
        handler.advanceTime(1);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.donateIgnoredItem.selector;
        selectors[5] = handler.instantaneousRoundTrip.selector;
        selectors[6] = handler.overWithdraw.selector;
        selectors[7] = handler.exitEveryone.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _assertPrincipalRewardsAndActiveClock() internal view {
        uint256 stakeSum;
        uint256 owedSum;
        uint256 paidSum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 principal = handler.deposits(i) - handler.withdrawals(i);
            assertEq(gauge.staked(actor), principal, "another caller changed this stake");
            assertEq(lp.balanceOf(actor) + principal, handler.INITIAL_LP());
            assertEq(item.balanceOf(actor), handler.paidTo(i));
            stakeSum += principal;
            owedSum += gauge.earned(actor);
            paidSum += item.balanceOf(actor);
        }
        assertEq(stakeSum, handler.ghostTotal());
        assertEq(gauge.totalStaked(), stakeSum);
        assertEq(lp.balanceOf(address(gauge)), stakeSum);
        assertEq(paidSum, handler.ghostPaid());
        assertEq(item.balanceOf(address(gauge)) + paidSum, allocation + handler.ghostDonated());

        uint256 active = handler.ghostActiveSeconds();
        assertEq(gauge.stakedSeconds(), active, "idle wall time leaked into release");
        uint256 expectedReleased = allocation * active * (2 * DURATION - active) / DURATION ** 2;
        assertEq(gauge.released(), expectedReleased);
        assertEq(gauge.remaining() + expectedReleased, allocation);
        assertEq(gauge.rate(), stakeSum == 0 ? 0 : 2 * allocation * (DURATION - active) / DURATION ** 2);
        assertLe(paidSum + owedSum, expectedReleased, "obligations exceed released receipts");

        // A global checkpoint loses < totalStaked / 1e36 wei; totalStaked <= 4e27.
        // Each of four users can additionally retain < one wei in their fractional carry.
        uint256 dustBound = 4 + ((handler.checkpoints() + 1) * 4e27 + 1e36 - 1) / 1e36;
        assertLe(expectedReleased - paidSum - owedSum, dustBound, "release lost beyond index dust");
        assertTrue(gauge.started());
        assertEq(gauge.pair(), address(lp));
    }

    function afterInvariant() public {
        handler.finishAndClaimAll();
        _assertPrincipalRewardsAndActiveClock();
    }
}

contract BaskUsdgGaugeInvariantTest is GaugeInvariantBase {
    function _deploy(address item_) internal override returns (LpGauge) {
        return new BaskUsdgGauge(item_);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_principalRewardsAndActiveClockAreConserved() public view {
        _assertPrincipalRewardsAndActiveClock();
    }
}

contract ItemEthGaugeInvariantTest is GaugeInvariantBase {
    function _deploy(address item_) internal override returns (LpGauge) {
        return new ItemEthGauge(item_);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_principalRewardsAndActiveClockAreConserved() public view {
        _assertPrincipalRewardsAndActiveClock();
    }
}
