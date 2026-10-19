// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LpGauge} from "./LpGauge.sol";

/// @title BASK/USDG LP gauge: 490,000,000 ITEM over 4 years of staked time
contract BaskUsdgGauge is LpGauge {
    address public constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    constructor(address item_) LpGauge(item_, BASK, USDG, 490_000_000e18) {}
}
