// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Reward index arithmetic shared by the gauges and ItemStaking
/// @notice One index per reward token at 1e36 precision. Every function is internal so the compiler inlines it
/// and no link placeholder is left in the bytecode.
library RewardMath {
    uint256 internal constant PRECISION = 1e36;

    error MulDivOverflow();

    /// @notice floor(x * y / denominator) with full 512-bit intermediate precision.
    /// @dev Remco Bloemen's algorithm as published in OpenZeppelin's Math library (MIT).
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                return prod0 / denominator;
            }
            if (denominator <= prod1) revert MulDivOverflow();
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }

    /// @notice Index growth for `amount` released over `totalStaked`, rounding down.
    function indexGrowth(uint256 amount, uint256 totalStaked) internal pure returns (uint256) {
        return mulDiv(amount, PRECISION, totalStaked);
    }

    /// @notice floor((stake * indexDelta + carry) / 1e36) and the new carry, computed without overflow.
    function accrue(uint256 stake, uint256 indexDelta, uint256 carry)
        internal
        pure
        returns (uint256 amount, uint256 newCarry)
    {
        uint256 quotient = mulDiv(stake, indexDelta, PRECISION);
        uint256 remainder = mulmod(stake, indexDelta, PRECISION) + carry;
        amount = quotient + remainder / PRECISION;
        newCarry = remainder % PRECISION;
    }
}
