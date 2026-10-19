// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {ItemStaking} from "src/ItemStaking.sol";
import {BaskUsdgGauge} from "src/BaskUsdgGauge.sol";
import {ItemEthGauge} from "src/ItemEthGauge.sol";
import {DevVesting} from "src/DevVesting.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

/// @dev All deployments happen in a single external call, as in a factory launch.
contract BasketDeploymentBatch {
    function deploy() external returns (address[5] memory contracts_) {
        contracts_[0] = address(new LaunchToken());
        contracts_[1] = address(new ItemStaking(contracts_[0]));
        contracts_[2] = address(new BaskUsdgGauge(contracts_[0]));
        contracts_[3] = address(new ItemEthGauge(contracts_[0]));
        contracts_[4] = address(new DevVesting(contracts_[0], 0xc5e21e7A89F1fBDc5554e31702e627dD6262C856));
    }
}

contract ProjectBoundariesTest is Test {
    address constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address constant BENEFICIARY = 0xc5e21e7A89F1fBDc5554e31702e627dD6262C856;

    function test_singleTransactionConstructorsMakeNoExternalCallsAndPreserveSupply() public {
        vm.chainId(4663);
        assertEq(BASK.code.length, 0);
        assertEq(USDG.code.length, 0);
        assertEq(WETH.code.length, 0);
        assertEq(FACTORY.code.length, 0);
        BasketDeploymentBatch deployer = new BasketDeploymentBatch();
        vm.startStateDiffRecording();
        address[5] memory targets = deployer.deploy();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 created;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].kind == VmSafe.AccountAccessKind.Create) ++created;
            for (uint256 j; j < targets.length; ++j) {
                if (accesses[i].accessor != targets[j]) continue;
                VmSafe.AccountAccessKind kind = accesses[i].kind;
                assertTrue(
                    kind != VmSafe.AccountAccessKind.Call && kind != VmSafe.AccountAccessKind.StaticCall
                        && kind != VmSafe.AccountAccessKind.DelegateCall && kind != VmSafe.AccountAccessKind.CallCode,
                    "a constructor called another contract"
                );
            }
        }
        assertEq(created, 5, "deployment recording must observe all constructors");
        LaunchToken item = LaunchToken(targets[0]);
        assertEq(item.totalSupply(), 1e27);
        assertEq(item.balanceOf(address(deployer)), 1e27);
        for (uint256 i = 1; i < targets.length; ++i) {
            assertEq(item.balanceOf(targets[i]), 0);
        }
        assertEq(ItemStaking(targets[1]).item(), targets[0]);
        assertEq(BaskUsdgGauge(targets[2]).item(), targets[0]);
        assertEq(ItemEthGauge(targets[3]).item(), targets[0]);
        assertEq(DevVesting(targets[4]).item(), targets[0]);
        assertEq(DevVesting(targets[4]).beneficiary(), BENEFICIARY);
    }

    function test_applicationConstructorsAcceptAnItemAddressWithNoCode() public {
        address item = makeAddr("not-yet-deployed-item");
        assertEq(item.code.length, 0);
        assertEq(new ItemStaking(item).item(), item);
        assertEq(new BaskUsdgGauge(item).item(), item);
        assertEq(new ItemEthGauge(item).item(), item);
        assertEq(new DevVesting(item, BENEFICIARY).beneficiary(), BENEFICIARY);
    }

    function test_noAdminPauseUpgradeOrRecoveryEntryPointsForDeployerOrOutsider() public {
        BasketDeploymentBatch deployer = new BasketDeploymentBatch();
        address[5] memory targets = deployer.deploy();
        address outsider = makeAddr("outsider");
        // Give every application real custody so recovery probes cannot fail merely
        // because the target is empty. These donations confer no special authority.
        for (uint256 i = 1; i < targets.length; ++i) {
            vm.prank(address(deployer));
            LaunchToken(targets[0]).transfer(targets[i], 10);
        }
        bytes[] memory calls = new bytes[](14);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("admin()");
        calls[2] = abi.encodeWithSignature("pause()");
        calls[3] = abi.encodeWithSignature("unpause()");
        calls[4] = abi.encodeWithSignature("transferOwnership(address)", outsider);
        calls[5] = abi.encodeWithSignature("renounceOwnership()");
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", outsider);
        calls[7] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", outsider, bytes(""));
        calls[8] = abi.encodeWithSignature("rescue(address,address,uint256)", targets[0], outsider, 1);
        calls[9] = abi.encodeWithSignature("sweep(address)", targets[0]);
        calls[10] = abi.encodeWithSignature("initialize(address)", outsider);
        calls[11] = abi.encodeWithSignature("setBeneficiary(address)", outsider);
        calls[12] = abi.encodeWithSignature("revoke()");
        calls[13] = abi.encodeWithSignature("withdrawFor(address,uint256)", outsider, 1);
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(address(deployer));
                (bool deployerOk,) = targets[i].call(calls[j]);
                assertFalse(deployerOk, "deployer has an unrequested administrative path");
                vm.prank(outsider);
                (bool outsiderOk,) = targets[i].call(calls[j]);
                assertFalse(outsiderOk, "outsider has an unrequested administrative path");
            }
        }
        assertEq(LaunchToken(targets[0]).balanceOf(address(deployer)), 1e27 - 40);
        assertEq(LaunchToken(targets[0]).balanceOf(outsider), 0);
        for (uint256 i = 1; i < targets.length; ++i) {
            assertEq(LaunchToken(targets[0]).balanceOf(targets[i]), 10);
        }
    }

    function test_deployedRuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public {
        address[5] memory targets = new BasketDeploymentBatch().deploy();
        for (uint256 i; i < targets.length; ++i) {
            bytes memory code = targets[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }

    function test_allApplicationsUseTheSameRealItemAndConserveTheFixedSupply() public {
        vm.chainId(4663);
        vm.warp(1700000000);
        BasketDeploymentBatch deployer = new BasketDeploymentBatch();
        address[5] memory targets = deployer.deploy();
        LaunchToken item = LaunchToken(targets[0]);
        ItemStaking staking = ItemStaking(targets[1]);
        BaskUsdgGauge baskGauge = BaskUsdgGauge(targets[2]);
        ItemEthGauge ethGauge = ItemEthGauge(targets[3]);
        DevVesting vesting = DevVesting(targets[4]);
        vm.prank(address(deployer));
        item.transfer(address(this), 1e27);

        MockERC20 template = new MockERC20();
        vm.etch(BASK, address(template).code);
        vm.etch(USDG, address(template).code);
        vm.etch(WETH, address(template).code);
        vm.etch(FACTORY, address(new MockV2Factory()).code);
        MockERC20 baskLp = new MockERC20();
        MockERC20 ethLp = new MockERC20();
        MockV2Factory(FACTORY).setPair(BASK, USDG, address(baskLp));
        MockV2Factory(FACTORY).setPair(address(item), WETH, address(ethLp));
        item.approve(address(baskGauge), 490_000_000e18);
        item.approve(address(ethGauge), 210_000_000e18);
        item.approve(address(vesting), 40_000_000e18);
        baskGauge.start();
        ethGauge.start();
        vesting.fund();
        assertEq(item.balanceOf(address(this)), 260_000_000e18);
        assertEq(item.balanceOf(address(staking)), 0);

        baskLp.mint(address(this), 1);
        ethLp.mint(address(this), 1);
        baskLp.approve(address(baskGauge), 1);
        ethLp.approve(address(ethGauge), 1);
        baskGauge.stake(1);
        ethGauge.stake(1);
        item.approve(address(staking), 100e18);
        staking.stake(100e18);
        MockERC20(BASK).mint(address(staking), 7e18);
        MockERC20(USDG).mint(address(staking), 7e6);
        MockERC20(WETH).mint(address(staking), 7e18);
        staking.sync(BASK);
        staking.sync(USDG);
        staking.sync(WETH);
        vm.warp(vm.getBlockTimestamp() + 1460 days);
        staking.claim(BASK);
        staking.claim(USDG);
        staking.claim(WETH);
        assertEq(MockERC20(BASK).balanceOf(address(this)), 7e18);
        assertEq(MockERC20(USDG).balanceOf(address(this)), 7e6);
        assertEq(MockERC20(WETH).balanceOf(address(this)), 7e18);
        staking.unstake(100e18);
        // Exits return only principal, with both allocations still available to claim.
        baskGauge.withdraw(1);
        ethGauge.withdraw(1);
        assertEq(item.balanceOf(address(this)), 260_000_000e18);
        baskGauge.claim();
        ethGauge.claim();
        vesting.release();
        assertEq(item.balanceOf(address(this)), 960_000_000e18);
        assertEq(item.balanceOf(BENEFICIARY), 40_000_000e18);
        assertEq(item.totalSupply(), 1e27);
        for (uint256 i = 1; i < targets.length; ++i) {
            assertEq(item.balanceOf(targets[i]), 0);
        }
        assertEq(baskLp.balanceOf(address(this)), 1);
        assertEq(ethLp.balanceOf(address(this)), 1);
    }
}
