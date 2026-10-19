// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DevVesting} from "src/DevVesting.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev No mint/deal: every deposit and donation comes from the actual launch supply.
contract DevVestingSequenceHandler is Test {
    address public constant BENEFICIARY = 0xc5e21e7A89F1fBDc5554e31702e627dD6262C856;
    uint256 public constant ALLOCATION = 40_000_000e18;
    LaunchToken public immutable item;
    DevVesting public immutable vesting;
    address[4] public actors;
    uint256 public ghostFundings;
    uint256 public ghostDonations;
    uint256 public ghostPayments;

    constructor() {
        item = new LaunchToken();
        vesting = new DevVesting(address(item), BENEFICIARY);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("vesting invariant actor ", vm.toString(i)));
            item.transfer(actors[i], 1e27 / actors.length);
            vm.prank(actors[i]);
            item.approve(address(vesting), type(uint256).max);
        }
    }

    function advance(uint256 secondsSeed) external {
        uint256 before = vesting.vested();
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 180 days));
        assertGe(vesting.vested(), before, "vesting cannot run backwards as time advances");
    }

    function fund(uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 before = item.balanceOf(actor);
        if (ghostFundings != 0) {
            vm.expectRevert(DevVesting.AlreadyFunded.selector);
            vm.prank(actor);
            vesting.fund();
            assertEq(item.balanceOf(actor), before, "repeat funding moved caller funds");
        } else {
            vm.prank(actor);
            vesting.fund();
            ++ghostFundings;
            assertEq(before - item.balanceOf(actor), ALLOCATION, "funding must pull exactly the allocation");
        }
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        // At depth 128, even one actor making every donation retains enough to fund.
        uint256 amount = bound(amountSeed, 0, 1_000_000e18);
        vm.prank(actor);
        item.transfer(address(vesting), amount);
        ghostDonations += amount;
    }

    function release(uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        if (ghostFundings == 0) {
            vm.expectRevert(DevVesting.NotFunded.selector);
            vm.prank(actor);
            vesting.release();
            return;
        }
        uint256 expected = vesting.vested() - ghostPayments;
        uint256 before = item.balanceOf(BENEFICIARY);
        uint256 callerBefore = item.balanceOf(actor);
        vm.prank(actor);
        vesting.release();
        uint256 payment = item.balanceOf(BENEFICIARY) - before;
        ghostPayments += payment;
        assertEq(payment, expected, "release did not pay the entire matured debt");
        assertEq(item.balanceOf(actor), callerBefore, "release rewarded its caller");
        assertEq(vesting.released(), ghostPayments, "released counter differs from actual beneficiary receipts");
        vm.prank(actor);
        vesting.release();
        assertEq(item.balanceOf(BENEFICIARY), before + payment, "repeat release paid twice");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract DevVestingInvariantTest is Test {
    DevVestingSequenceHandler private handler;
    LaunchToken private item;
    DevVesting private vesting;
    uint256 private constant ALLOCATION = 40_000_000e18;
    uint256 private constant DURATION = 1460 days;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_123);
        handler = new DevVestingSequenceHandler();
        item = handler.item();
        vesting = handler.vesting();
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.release.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_receiptsEqualCustodyAndActualBeneficiaryPayments() public view {
        uint256 receipts = handler.ghostFundings() * ALLOCATION + handler.ghostDonations();
        assertEq(item.balanceOf(address(vesting)) + handler.ghostPayments(), receipts);
        assertEq(item.balanceOf(handler.BENEFICIARY()), handler.ghostPayments());
        assertEq(vesting.released(), handler.ghostPayments());
        assertLe(vesting.released(), vesting.vested());
        assertLe(vesting.released(), ALLOCATION);
        assertLe(handler.ghostFundings(), 1);
        assertEq(vesting.funded(), handler.ghostFundings() == 1);
    }

    function invariant_scheduleUsesDeploymentTimeWithCliffAndRoundDown() public view {
        uint256 elapsed = vm.getBlockTimestamp() - vesting.deployedAt();
        uint256 vested = vesting.vested();
        if (elapsed < 365 days) {
            assertEq(vested, 0);
        } else if (elapsed >= DURATION) {
            assertEq(vested, ALLOCATION);
        } else {
            // Integer inequalities specify floor without using the contract's division expression.
            assertLe(vested * DURATION, ALLOCATION * elapsed);
            assertGt((vested + 1) * DURATION, ALLOCATION * elapsed);
        }
    }

    function invariant_fixedLaunchSupplyIsEntirelyAccountedFor() public view {
        uint256 sum = item.balanceOf(address(vesting)) + item.balanceOf(handler.BENEFICIARY());
        for (uint256 i; i < 4; ++i) {
            sum += item.balanceOf(handler.actors(i));
        }
        assertEq(item.totalSupply(), 1e27);
        assertEq(sum, 1e27);
    }

    function afterInvariant() public {
        if (!vesting.funded()) handler.fund(0);
        if (vm.getBlockTimestamp() < vesting.deployedAt() + DURATION) vm.warp(vesting.deployedAt() + DURATION);
        handler.release(3);
        assertEq(item.balanceOf(handler.BENEFICIARY()), ALLOCATION, "full allocation must remain releasable");
        assertEq(item.balanceOf(address(vesting)), handler.ghostDonations(), "only unsolicited donations may remain");
    }
}
