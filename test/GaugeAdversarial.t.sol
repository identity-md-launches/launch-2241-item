// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LpGauge} from "src/LpGauge.sol";
import {BaskUsdgGauge} from "src/BaskUsdgGauge.sol";
import {ItemEthGauge} from "src/ItemEthGauge.sol";
import {ReentrancyGuard} from "src/ReentrancyGuard.sol";
import {TokenTransfer} from "src/libraries/TokenTransfer.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @dev A standard LP/ITEM stand-in except when a test deliberately activates hostility.
/// False/malformed return modes move balances first, testing transaction-wide rollback.
contract GaugeHostileERC20 {
    enum BalanceMode {
        Normal,
        RevertCall,
        BurnGas,
        HugeData,
        Zero,
        Max,
        ShortData
    }
    enum TransferMode {
        Normal,
        RevertCall,
        FalseReturn,
        BurnGas,
        HugeData,
        ShortData,
        InvalidBool,
        NoReturn
    }
    BalanceMode public balanceMode;
    TransferMode public transferMode;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public transferCalls;
    address public callbackTarget;
    bytes public callbackData;
    bytes public callbackError;
    bool public callbackSucceeded;
    bool private armed;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function setBalanceMode(BalanceMode mode) external {
        balanceMode = mode;
    }

    function setTransferMode(TransferMode mode) external {
        transferMode = mode;
    }

    function arm(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackError = "";
        callbackSucceeded = false;
        armed = true;
    }

    function balanceOf(address account) external view returns (uint256) {
        BalanceMode mode = balanceMode;
        if (mode == BalanceMode.RevertCall) revert("balance query rejected");
        if (mode == BalanceMode.BurnGas) {
            assembly { for {} 1 {} {} }
        }
        if (mode == BalanceMode.HugeData) {
            assembly { return(0, 0x10000) }
        }
        if (mode == BalanceMode.ShortData) {
            assembly { return(0, 31) }
        }
        if (mode == BalanceMode.Zero) return 0;
        if (mode == BalanceMode.Max) return type(uint256).max;
        return balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        ++transferCalls;
        balances[from] -= amount;
        balances[to] += amount;
        if (armed) {
            armed = false;
            (callbackSucceeded, callbackError) = callbackTarget.call(callbackData);
        }
        TransferMode mode = transferMode;
        if (mode == TransferMode.RevertCall) revert("transfer rejected");
        if (mode == TransferMode.FalseReturn) return false;
        if (mode == TransferMode.BurnGas) {
            assembly { for {} 1 {} {} }
        }
        if (mode == TransferMode.HugeData) {
            assembly {
                mstore(0, 1)
                return(0, 0x100000)
            }
        }
        if (mode == TransferMode.ShortData) {
            assembly { return(0, 31) }
        }
        if (mode == TransferMode.InvalidBool) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == TransferMode.NoReturn) {
            assembly { return(0, 0) }
        }
        return true;
    }
}

/// @dev A lender's LP is borrowed, staked, claimed, withdrawn and repaid in one top-level call.
contract GaugeFlashBorrower {
    function execute(GaugeHostileERC20 lp, LpGauge gauge, uint256 amount) external {
        lp.transferFrom(msg.sender, address(this), amount);
        lp.approve(address(gauge), amount);
        gauge.stake(amount);
        gauge.claim();
        gauge.withdraw(amount);
        lp.transfer(msg.sender, amount);
    }
}

abstract contract GaugeAdversarialBase is Test {
    uint256 internal constant T = 1460 days;
    address internal constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    GaugeHostileERC20 internal item;
    GaugeHostileERC20 internal lp;
    LpGauge internal gauge;
    address internal alice;
    address internal bob;
    address internal carol;
    uint256 internal allocation;

    function _deploy(address token) internal virtual returns (LpGauge);

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_700_000_000);
        alice = makeAddr("gauge-adversarial-alice");
        bob = makeAddr("gauge-adversarial-bob");
        carol = makeAddr("gauge-adversarial-carol");
        item = new GaugeHostileERC20();
        lp = new GaugeHostileERC20();
        gauge = _deploy(address(item));
        allocation = gauge.ALLOCATION();
        vm.etch(FACTORY, address(new MockV2Factory()).code);
        MockV2Factory(FACTORY).setPair(gauge.tokenA(), gauge.tokenB(), address(lp));
        item.mint(address(this), allocation);
        item.approve(address(gauge), allocation);
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < actors.length; ++i) {
            lp.mint(actors[i], 1e27);
            vm.prank(actors[i]);
            lp.approve(address(gauge), type(uint256).max);
        }
    }

    function _stake(address actor, uint256 amount) internal {
        vm.prank(actor);
        gauge.stake(amount);
    }

    function _claim(address actor) internal returns (uint256 paid) {
        uint256 beforeBalance = item.balances(actor);
        vm.prank(actor);
        gauge.claim();
        return item.balances(actor) - beforeBalance;
    }

    function _entrypoints() internal pure returns (bytes[4] memory calls) {
        calls[0] = abi.encodeCall(LpGauge.start, ());
        calls[1] = abi.encodeCall(LpGauge.stake, (1));
        calls[2] = abi.encodeCall(LpGauge.withdraw, (1));
        calls[3] = abi.encodeCall(LpGauge.claim, ());
    }

    function test_constructorMakesNoDependencyCalls() public {
        vm.expectCall(address(item), bytes(""), uint64(0));
        vm.expectCall(FACTORY, bytes(""), uint64(0));
        LpGauge deployed = _deploy(address(item));
        assertEq(deployed.item(), address(item));
        assertFalse(deployed.started());
    }

    function test_failedFundingRollsBackPairStartAndTokenMovement() public {
        item.setTransferMode(GaugeHostileERC20.TransferMode.FalseReturn);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        gauge.start();
        assertFalse(gauge.started());
        assertEq(gauge.pair(), address(0));
        assertEq(item.balances(address(gauge)), 0);
        assertEq(item.balances(address(this)), allocation);
        assertEq(item.allowance(address(this), address(gauge)), allocation);
        vm.warp(vm.getBlockTimestamp() + 400 days);
        item.setTransferMode(GaugeHostileERC20.TransferMode.Normal);
        gauge.start();
        assertTrue(gauge.started());
        assertEq(gauge.stakedSeconds(), 0);
    }

    function test_insufficientFundingCannotLeaveStartedState() public {
        item.burn(address(this), 1);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        gauge.start();
        assertFalse(gauge.started());
        assertEq(gauge.pair(), address(0));
        item.mint(address(this), 1);
        gauge.start();
        assertEq(item.balances(address(gauge)), allocation);
    }

    function test_factoryFailureAndMalformedReturnCanBeRetried() public {
        bytes memory lookup = abi.encodeWithSignature("getPair(address,address)", gauge.tokenA(), gauge.tokenB());
        vm.mockCallRevert(FACTORY, lookup, abi.encodeWithSignature("Error(string)", "factory unavailable"));
        vm.expectRevert();
        gauge.start();
        assertFalse(gauge.started());
        vm.mockCall(FACTORY, lookup, hex"01");
        vm.expectRevert();
        gauge.start();
        assertFalse(gauge.started());
        vm.clearMockedCalls();
        gauge.start();
        assertEq(gauge.pair(), address(lp));
    }

    function test_startedGaugeDoesNotRequeryFactory() public {
        gauge.start();
        vm.mockCallRevert(FACTORY, bytes(""), hex"badfac");
        _stake(alice, 17);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        gauge.withdraw(17);
        assertGt(_claim(alice), 0);
        assertEq(gauge.pair(), address(lp));
    }

    function test_failedLpTransfersRollbackPrincipalAndAccrual() public {
        gauge.start();
        _stake(alice, 3);
        vm.warp(vm.getBlockTimestamp() + 17 days);
        uint256 owed = gauge.earned(alice);
        uint256 beforeLp = lp.balances(alice);
        lp.setTransferMode(GaugeHostileERC20.TransferMode.FalseReturn);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vm.prank(alice);
        gauge.stake(5);
        assertEq(gauge.staked(alice), 3);
        assertEq(gauge.totalStaked(), 3);
        assertEq(lp.balances(alice), beforeLp);
        assertEq(gauge.earned(alice), owed);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vm.prank(alice);
        gauge.withdraw(3);
        assertEq(gauge.staked(alice), 3);
        assertEq(gauge.totalStaked(), 3);
        assertEq(lp.balances(alice), beforeLp);
        assertEq(gauge.earned(alice), owed);
        lp.setTransferMode(GaugeHostileERC20.TransferMode.Normal);
        vm.prank(alice);
        gauge.withdraw(3);
        assertEq(_claim(alice), owed);
    }

    function test_stakeWithoutAllowanceOrBalanceLeavesNoPhantomStake() public {
        gauge.start();
        vm.prank(alice);
        lp.approve(address(gauge), 0);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vm.prank(alice);
        gauge.stake(1);
        vm.expectRevert(TokenTransfer.TransferFailed.selector);
        vm.prank(bob);
        gauge.stake(1e27 + 1);
        assertEq(gauge.totalStaked(), 0);
        assertEq(gauge.staked(alice), 0);
        assertEq(gauge.staked(bob), 0);
        assertEq(lp.balances(address(gauge)), 0);
    }

    function test_allHostileBalanceModesLeaveStakeWithdrawAndViewsLive() public {
        gauge.start();
        _stake(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 owed = gauge.earned(alice);
        uint256 calls = item.transferCalls();
        for (uint256 m = 1; m <= uint256(GaugeHostileERC20.BalanceMode.ShortData); ++m) {
            item.setBalanceMode(GaugeHostileERC20.BalanceMode(m));
            _stake(bob, 7);
            vm.prank(bob);
            gauge.withdraw(7);
            assertEq(gauge.earned(alice), owed);
            assertEq(gauge.earned(bob), 0);
            assertEq(gauge.stakedSeconds(), 30 days);
        }
        vm.prank(alice);
        gauge.withdraw(1);
        assertEq(item.transferCalls(), calls, "LP entry/exit touched reward token");
        assertEq(gauge.earned(alice), owed);
        item.setBalanceMode(GaugeHostileERC20.BalanceMode.Normal);
        assertEq(_claim(alice), owed);
    }

    function test_allHostileTransferModesLeaveStakeAndWithdrawLive() public {
        gauge.start();
        uint256 calls = item.transferCalls();
        for (uint256 m = 1; m <= uint256(GaugeHostileERC20.TransferMode.InvalidBool); ++m) {
            item.setTransferMode(GaugeHostileERC20.TransferMode(m));
            _stake(alice, 1e27);
            vm.warp(vm.getBlockTimestamp() + 1);
            vm.prank(alice);
            gauge.withdraw(1e27);
            assertEq(lp.balances(alice), 1e27);
            assertEq(item.balances(alice), 0);
        }
        assertEq(item.transferCalls(), calls);
        item.setTransferMode(GaugeHostileERC20.TransferMode.Normal);
        assertEq(_claim(alice), gauge.released());
    }

    function test_failedAndGasExhaustingClaimsRevertWholeThenRetry() public {
        gauge.start();
        _stake(alice, 1);
        for (uint256 m = 1; m <= uint256(GaugeHostileERC20.TransferMode.InvalidBool); ++m) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            uint256 owed = gauge.earned(alice);
            uint256 beforeUser = item.balances(alice);
            uint256 beforeGauge = item.balances(address(gauge));
            item.setTransferMode(GaugeHostileERC20.TransferMode(m));
            vm.prank(alice);
            (bool ok,) = address(gauge).call{gas: 250_000}(abi.encodeCall(LpGauge.claim, ()));
            assertFalse(ok, "hostile claim unexpectedly succeeded");
            assertEq(gauge.earned(alice), owed, "failed claim erased debt");
            assertEq(item.balances(alice), beforeUser, "failed claim changed user balance");
            assertEq(item.balances(address(gauge)), beforeGauge, "failed claim moved reserves");
            item.setTransferMode(GaugeHostileERC20.TransferMode.Normal);
            assertEq(_claim(alice), owed);
        }
    }

    function test_noReturnTransfersStillMoveExactPrincipalAndRewards() public {
        item.setTransferMode(GaugeHostileERC20.TransferMode.NoReturn);
        lp.setTransferMode(GaugeHostileERC20.TransferMode.NoReturn);
        gauge.start();
        _stake(alice, 1e27);
        vm.warp(vm.getBlockTimestamp() + T);
        vm.prank(alice);
        gauge.withdraw(1e27);
        assertEq(lp.balances(alice), 1e27);
        assertEq(_claim(alice), allocation);
    }

    function test_itemFundingCallbacksCannotEnterAnyMutator() public {
        bytes[4] memory calls = _entrypoints();
        for (uint256 i; i < calls.length; ++i) {
            LpGauge freshGauge = _deploy(address(item));
            item.mint(address(this), allocation);
            item.approve(address(freshGauge), allocation);
            item.arm(address(freshGauge), calls[i]);
            freshGauge.start();
            assertFalse(item.callbackSucceeded());
            assertEq(item.callbackError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
            assertEq(item.balances(address(freshGauge)), allocation);
            assertTrue(freshGauge.started());
        }
    }

    function test_itemClaimCallbacksCannotEnterAnyMutator() public {
        gauge.start();
        _stake(alice, 1);
        bytes[4] memory calls = _entrypoints();
        for (uint256 i; i < calls.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            uint256 owed = gauge.earned(alice);
            item.arm(address(gauge), calls[i]);
            assertEq(_claim(alice), owed);
            assertFalse(item.callbackSucceeded());
            assertEq(item.callbackError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
            assertEq(gauge.staked(alice), 1);
        }
    }

    function test_lpCallbacksCannotReenterStart() public {
        gauge.start();
        lp.arm(address(gauge), abi.encodeCall(LpGauge.start, ()));
        _stake(alice, 1);
        assertEq(lp.callbackError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        lp.arm(address(gauge), abi.encodeCall(LpGauge.start, ()));
        vm.prank(alice);
        gauge.withdraw(1);
        assertEq(lp.callbackError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
    }

    function test_flashBorrowedLpCannotCapturePendingRewards() public {
        gauge.start();
        _stake(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 incumbentOwed = gauge.earned(alice);
        GaugeFlashBorrower borrower = new GaugeFlashBorrower();
        vm.prank(bob);
        lp.approve(address(borrower), 1e27);
        vm.prank(bob);
        borrower.execute(lp, gauge, 1e27);
        assertEq(lp.balances(bob), 1e27);
        assertEq(lp.balances(address(borrower)), 0);
        assertEq(item.balances(address(borrower)), 0);
        assertEq(gauge.earned(address(borrower)), 0);
        assertEq(gauge.staked(address(borrower)), 0);
        assertEq(gauge.earned(alice), incumbentOwed);
        assertEq(_claim(alice), incumbentOwed);
    }

    function test_newEntrantCannotDilutePastReleaseOrReceiveIt() public {
        gauge.start();
        _stake(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 pastRelease = gauge.released();
        _stake(bob, 1e27);
        assertEq(gauge.earned(bob), 0);
        assertEq(gauge.earned(alice), pastRelease);
        vm.prank(alice);
        gauge.withdraw(1);
        vm.warp(vm.getBlockTimestamp() + 730 days);
        assertEq(_claim(bob), gauge.released() - pastRelease);
        assertEq(_claim(alice), pastRelease);
    }

    function test_fractionalCarrySurvivesRepeatedCompleteExitClaimAndRestake() public {
        gauge.start();
        _stake(alice, 3);
        _stake(bob, 7);
        uint256 paid;
        for (uint256 i = 1; i <= 40; ++i) {
            vm.warp(vm.getBlockTimestamp() + i * 137 + 1);
            vm.prank(alice);
            gauge.withdraw(3);
            paid += _claim(alice);
            assertEq(gauge.earned(alice), 0);
            _stake(alice, 3);
        }
        // 10 divides 1e36 exactly: only the specified user-level rounding remains.
        uint256 totalReleased = gauge.released();
        assertEq(paid, totalReleased * 3 / 10, "exit or claim discarded fractional carry");
        uint256 bobPaid = _claim(bob);
        assertEq(bobPaid, totalReleased * 7 / 10);
        assertLe(paid + bobPaid, totalReleased);
        assertLe(totalReleased - paid - bobPaid, 1);
    }

    function _everyClaimOrderPaysFinalExitingClaimerInFull(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 elapsed,
        uint8 order
    ) internal {
        gauge.start();
        address[3] memory actors = [alice, bob, carol];
        uint256[3] memory amounts = [bound(a, 1, 1e27), bound(b, 1, 1e27), bound(c, 1, 1e27)];
        for (uint256 i; i < 3; ++i) {
            _stake(actors[i], amounts[i]);
        }
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 1, T + 365 days));
        uint256[3] memory owed;
        for (uint256 i; i < 3; ++i) {
            owed[i] = gauge.earned(actors[i]);
            vm.prank(actors[i]);
            gauge.withdraw(amounts[i]);
        }
        uint256 first = order % 3;
        uint256 direction = (order / 3) % 2 == 0 ? 1 : 2;
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            uint256 index = (first + i * direction) % 3;
            uint256 actual = _claim(actors[index]);
            assertEq(actual, owed[index], "claim order or exit reduced payment");
            assertEq(gauge.earned(actors[index]), 0);
            paid += actual;
        }
        assertLe(paid, gauge.released());
        assertLe(gauge.released() - paid, 3);
        assertEq(item.balances(address(gauge)), allocation - paid);
        assertEq(gauge.totalStaked(), 0);
    }
}

contract BaskUsdgGaugeAdversarialTest is GaugeAdversarialBase {
    function _deploy(address token) internal override returns (LpGauge) {
        return new BaskUsdgGauge(token);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_everyClaimOrderPaysFinalExitingClaimerInFull(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 elapsed,
        uint8 order
    ) public {
        _everyClaimOrderPaysFinalExitingClaimerInFull(a, b, c, elapsed, order);
    }
}

contract ItemEthGaugeAdversarialTest is GaugeAdversarialBase {
    function _deploy(address token) internal override returns (LpGauge) {
        return new ItemEthGauge(token);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_everyClaimOrderPaysFinalExitingClaimerInFull(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 elapsed,
        uint8 order
    ) public {
        _everyClaimOrderPaysFinalExitingClaimerInFull(a, b, c, elapsed, order);
    }
}
