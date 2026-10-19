// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {RewardMath} from "./libraries/RewardMath.sol";
import {TokenTransfer} from "./libraries/TokenTransfer.sol";

interface IV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title Abstract v2 LP gauge paying ITEM
/// @notice Stake the canonical v2 LP of (tokenA, tokenB) and earn ITEM from a fixed allocation released over
/// T = 4 years of staked time: released(t) = ALLOCATION * t * (2T - t) / T^2, where t only advances while
/// something is staked. Rewards are paid pro rata to staked LP through a 1e36 index, rounding down.
abstract contract LpGauge is ReentrancyGuard {
    using RewardMath for uint256;

    address public constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    uint256 public constant T = 4 * 365 days;

    address public immutable item;
    address public immutable tokenA;
    address public immutable tokenB;
    uint256 public immutable ALLOCATION;

    address public pair;
    bool public started;
    uint256 public totalStaked;
    mapping(address => uint256) public staked;

    /// @dev Staked seconds credited so far, capped at T.
    uint256 private _stakedSeconds;
    /// @dev Timestamp of the last index update after start.
    uint256 private _lastUpdate;
    uint256 private _index;
    mapping(address => uint256) private _userIndex;
    mapping(address => uint256) private _carry;
    mapping(address => uint256) private _owed;

    event Started(address indexed pair, uint256 allocation);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    error AlreadyStarted();
    error NotStarted();
    error NoPair();
    error ZeroAmount();
    error InsufficientStake();

    constructor(address item_, address tokenA_, address tokenB_, uint256 allocation_) {
        item = item_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        ALLOCATION = allocation_;
    }

    /// @notice Once: looks up the canonical pair, stores it and pulls exactly ALLOCATION of ITEM from the caller.
    function start() external nonReentrant {
        if (started) revert AlreadyStarted();
        address pair_ = IV2Factory(V2_FACTORY).getPair(tokenA, tokenB);
        if (pair_ == address(0)) revert NoPair();
        pair = pair_;
        started = true;
        _lastUpdate = block.timestamp;
        TokenTransfer.pull(item, msg.sender, ALLOCATION);
        emit Started(pair_, ALLOCATION);
    }

    function stake(uint256 amount) external nonReentrant {
        if (!started) revert NotStarted();
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        TokenTransfer.pull(pair, msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Moves only the LP back to the caller; earned ITEM stays owed until claim().
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 current = staked[msg.sender];
        if (current < amount) revert InsufficientStake();
        _update(msg.sender);
        unchecked {
            staked[msg.sender] = current - amount;
            totalStaked -= amount;
        }
        TokenTransfer.push(pair, msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Pays everything the caller has accrued in ITEM; a failed transfer reverts the whole claim.
    function claim() external nonReentrant {
        _update(msg.sender);
        uint256 amount = _owed[msg.sender];
        _owed[msg.sender] = 0;
        TokenTransfer.push(item, msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice Seconds since start during which totalStaked > 0, capped at T, as of now.
    function stakedSeconds() public view returns (uint256) {
        uint256 t = _stakedSeconds;
        if (totalStaked > 0) t += block.timestamp - _lastUpdate;
        return t > T ? T : t;
    }

    /// @notice ITEM released so far: ALLOCATION * t * (2T - t) / T^2 at t = stakedSeconds().
    function released() public view returns (uint256) {
        return _released(stakedSeconds());
    }

    /// @notice Current release rate per second, 2 * ALLOCATION * (T - t) / T^2, or 0 while nothing is staked.
    function rate() external view returns (uint256) {
        if (totalStaked == 0) return 0;
        return 2 * ALLOCATION * (T - stakedSeconds()) / (T * T);
    }

    function remaining() external view returns (uint256) {
        return ALLOCATION - released();
    }

    function earned(address user) external view returns (uint256) {
        uint256 index = _index;
        if (totalStaked > 0) {
            uint256 t = stakedSeconds();
            index += (_released(t) - _released(_stakedSeconds)).indexGrowth(totalStaked);
        }
        (uint256 amount,) = staked[user].accrue(index - _userIndex[user], _carry[user]);
        return _owed[user] + amount;
    }

    // ──────────────────────────── internals ───────────────────────────

    function _released(uint256 t) internal view returns (uint256) {
        return ALLOCATION * t * (2 * T - t) / (T * T);
    }

    /// @dev Global index first, then the caller, before any stake change.
    function _update(address user) private {
        if (started) {
            if (totalStaked > 0) {
                uint256 t = _stakedSeconds + (block.timestamp - _lastUpdate);
                if (t > T) t = T;
                uint256 delta = _released(t) - _released(_stakedSeconds);
                _index += delta.indexGrowth(totalStaked);
                _stakedSeconds = t;
            }
            _lastUpdate = block.timestamp;
        }
        (uint256 amount, uint256 carry) = staked[user].accrue(_index - _userIndex[user], _carry[user]);
        _owed[user] += amount;
        _carry[user] = carry;
        _userIndex[user] = _index;
    }
}
