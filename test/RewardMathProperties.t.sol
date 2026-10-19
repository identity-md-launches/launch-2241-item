// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RewardMath} from "src/libraries/RewardMath.sol";

contract RewardMathHarness {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return RewardMath.mulDiv(a, b, d);
    }

    function accrue(uint256 stake, uint256 delta, uint256 carry) external pure returns (uint256, uint256) {
        return RewardMath.accrue(stake, delta, carry);
    }

    function indexGrowth(uint256 released, uint256 total) external pure returns (uint256) {
        return RewardMath.indexGrowth(released, total);
    }
}

/// @notice Check arithmetic using quotient/remainder identities and independent 128-bit limbs.
/// The oracle never copies the production modular-inverse division algorithm.
contract RewardMathPropertiesTest is Test {
    uint256 constant P = 1e36;
    RewardMathHarness internal math;

    function setUp() public {
        math = new RewardMathHarness();
    }

    function _wideProduct(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        uint256 p00 = uint256(uint128(a)) * uint128(b);
        uint256 p01 = uint256(uint128(a)) * (b >> 128);
        uint256 p10 = (a >> 128) * uint128(b);
        uint256 p11 = (a >> 128) * (b >> 128);
        unchecked {
            lo = p00 + (p01 << 128);
            hi = p11 + (p01 >> 128) + (p10 >> 128) + (lo < p00 ? 1 : 0);
            uint256 previous = lo;
            lo += p10 << 128;
            hi += lo < previous ? 1 : 0;
        }
    }

    function _addLow(uint256 hi, uint256 lo, uint256 value) internal pure returns (uint256, uint256) {
        unchecked {
            uint256 next = lo + value;
            return (hi + (next < lo ? 1 : 0), next);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mulDivReconstructsFull512BitProduct(uint256 a, uint256 b, uint256 denominator) public view {
        (uint256 productHi, uint256 productLo) = _wideProduct(a, b);
        // A 256-bit quotient exists precisely when denominator exceeds the high limb.
        denominator = bound(denominator, productHi + 1, type(uint256).max);
        uint256 quotient = math.mulDiv(a, b, denominator);
        uint256 remainder = mulmod(a, b, denominator);
        (uint256 actualHi, uint256 actualLo) = _wideProduct(quotient, denominator);
        (actualHi, actualLo) = _addLow(actualHi, actualLo, remainder);
        assertEq(actualHi, productHi, "quotient/remainder high limb");
        assertEq(actualLo, productLo, "quotient/remainder low limb");
        assertLt(remainder, denominator, "round down, never up");
        assertEq(math.mulDiv(b, a, denominator), quotient, "factor order");
    }

    function test_mulDivEdgesAndOverflow() public {
        uint256 max = type(uint256).max;
        assertEq(math.mulDiv(max, max, max), max);
        assertEq(math.mulDiv(1 << 200, 1 << 200, 1 << 200), 1 << 200);
        assertEq(math.mulDiv(max, 1, max), 1);
        assertEq(math.mulDiv(0, max, 1), 0);
        assertEq(math.mulDiv(1, 1, max), 0);
        vm.expectRevert(RewardMath.MulDivOverflow.selector);
        math.mulDiv(max, max, max - 1);
        vm.expectRevert(RewardMath.MulDivOverflow.selector);
        math.mulDiv(1 << 200, 1 << 200, 1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12));
        math.mulDiv(1, 1, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_accrualPreservesEveryFraction(uint256 stake, uint256 delta, uint256 carry) public view {
        stake = bound(stake, 0, 1e27);
        delta = bound(delta, 0, 1e66);
        carry = bound(carry, 0, P - 1);
        (uint256 amount, uint256 nextCarry) = math.accrue(stake, delta, carry);
        (uint256 expectedHi, uint256 expectedLo) = _wideProduct(stake, delta);
        (expectedHi, expectedLo) = _addLow(expectedHi, expectedLo, carry);
        (uint256 actualHi, uint256 actualLo) = _wideProduct(amount, P);
        (actualHi, actualLo) = _addLow(actualHi, actualLo, nextCarry);
        assertEq(actualHi, expectedHi, "accrual high limb");
        assertEq(actualLo, expectedLo, "no fractional reward disappears");
        assertLt(nextCarry, P);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splittingClaimsDoesNotLoseUserCarry(uint256 stake, uint256 a, uint256 b, uint256 carry)
        public
        view
    {
        stake = bound(stake, 0, 1e27);
        a = bound(a, 0, 1e66);
        b = bound(b, 0, 1e66);
        carry = bound(carry, 0, P - 1);
        (uint256 first, uint256 firstCarry) = math.accrue(stake, a, carry);
        (uint256 second, uint256 secondCarry) = math.accrue(stake, b, firstCarry);
        (uint256 together, uint256 togetherCarry) = math.accrue(stake, a + b, carry);
        assertEq(first + second, together);
        assertEq(secondCarry, togetherCarry);
        (uint256 idleAmount, uint256 idleCarry) = math.accrue(0, b, firstCarry);
        assertEq(idleAmount, 0);
        assertEq(idleCarry, firstCarry, "exiting must preserve the fraction");
    }

    function test_oneWeiOneE27AndCarryBoundary() public view {
        assertEq(math.indexGrowth(1, 1e27), 1e9);
        assertEq(math.indexGrowth(1e27, 1), 1e63);
        (uint256 amount, uint256 carry) = math.accrue(1e27, 1e9, 0);
        assertEq(amount, 1);
        assertEq(carry, 0);
        (amount, carry) = math.accrue(1, 1, P - 1);
        assertEq(amount, 1);
        assertEq(carry, 0);
        (amount, carry) = math.accrue(1, 0, P - 1);
        assertEq(amount, 0);
        assertEq(carry, P - 1);
    }
}
