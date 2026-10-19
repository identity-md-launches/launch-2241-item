// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ItemStaking} from "src/ItemStaking.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev Exposes gas at the receiving end without allocating dynamic return data.
contract StakingBalanceGasProbe {
    fallback() external {
        assembly {
            mstore(0, gas())
            return(0, 32)
        }
    }
}

/// @dev A CALL would succeed; a STATICCALL must reject the attempted storage write.
contract StakingBalanceWriteProbe {
    uint256 public writes;

    function balanceOf(address) external returns (uint256) {
        ++writes;
        return 100;
    }
}

contract BalanceReadBoundaryTest is Test {
    address constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    ItemStaking internal staking;
    LaunchToken internal item;

    function setUp() public {
        vm.chainId(4663);
        item = new LaunchToken();
        staking = new ItemStaking(address(item));
        item.approve(address(staking), type(uint256).max);
    }

    function test_balanceReadForwardsOnlyFiftyThousandGas() public {
        vm.etch(BASK, address(new StakingBalanceGasProbe()).code);
        // Ample outer gas ensures EIP-150 does not itself reduce the requested stipend.
        staking.sync{gas: 500_000}(BASK);
        (uint256 accounted,, uint256 streamAmount,,) = staking.rewardInfo(BASK);
        // The minimal dispatch uses a few gas before the probe samples GAS. A CALL
        // forwarding the outer gas, or a materially smaller stipend, fails these bounds.
        assertGt(accounted, 49_900);
        assertLt(accounted, 50_000);
        assertEq(streamAmount, accounted);
    }

    function test_balanceReadIsStaticAndInvalidTokenCannotBlockPrincipal() public {
        vm.etch(BASK, address(new StakingBalanceWriteProbe()).code);
        vm.expectEmit(true, false, false, true, address(staking));
        emit ItemStaking.Synced(BASK, false, 0);
        staking.sync(BASK);
        assertEq(StakingBalanceWriteProbe(BASK).writes(), 0);
        (uint256 accounted,, uint256 streamAmount,,) = staking.rewardInfo(BASK);
        assertEq(accounted, 0);
        assertEq(streamAmount, 0);
        staking.stake(1);
        staking.unstake(1);
        assertEq(item.balanceOf(address(this)), 1e27);
        assertEq(staking.totalStaked(), 0);
        assertEq(StakingBalanceWriteProbe(BASK).writes(), 0);
        vm.expectRevert(ItemStaking.InvalidBalanceRead.selector);
        staking.claim(BASK);
    }
}
