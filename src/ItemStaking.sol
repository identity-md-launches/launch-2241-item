// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {RewardMath} from "./libraries/RewardMath.sol";
import {TokenTransfer} from "./libraries/TokenTransfer.sol";

/// @title ITEM staking paying BASK, USDG and WETH
/// @notice Stake ITEM and earn the three reward tokens. Anyone may send them; the Basket vault sends BASK fees
/// here as its fee recipient without calling this contract. Each token is streamed over 7 days of staked time,
/// one stream at a time, from amounts detected by reading balanceOf(this). stake and unstake never transfer a
/// reward token and cannot be blocked by one; only claim(token) pays that token.
contract ItemStaking is ReentrancyGuard {
    using RewardMath for uint256;

    address public constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint256 public constant STREAM_DURATION = 7 days;
    uint256 public constant MAX_FRESH = 1e30;

    address public immutable item;

    uint256 public totalStaked;
    mapping(address => uint256) public staked;

    struct Reward {
        /// @dev All stream amounts minus all payments.
        uint256 accounted;
        uint256 index;
        /// @dev F of the live stream (0 before the first stream).
        uint256 streamAmount;
        /// @dev Staked seconds the live stream has run, capped at STREAM_DURATION.
        uint256 streamSeconds;
        uint256 lastSync;
    }

    mapping(address => Reward) private _rewards;
    /// @dev token => user => value
    mapping(address => mapping(address => uint256)) private _userIndex;
    mapping(address => mapping(address => uint256)) private _carry;
    mapping(address => mapping(address => uint256)) private _owed;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event StreamStarted(address indexed token, uint256 amount);
    event Synced(address indexed token, bool balanceValid, uint256 balance);

    error ZeroAmount();
    error InsufficientStake();
    error InvalidToken();
    error InvalidBalanceRead();

    constructor(address item_) {
        item = item_;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateAll(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        TokenTransfer.pull(item, msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 current = staked[msg.sender];
        if (current < amount) revert InsufficientStake();
        _updateAll(msg.sender);
        unchecked {
            staked[msg.sender] = current - amount;
            totalStaked -= amount;
        }
        TokenTransfer.push(item, msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Pays min(accrued, balance read) of one token; the unpaid rest stays owed.
    function claim(address token) external nonReentrant {
        _checkToken(token);
        (bool valid, uint256 balance) = _sync(token);
        if (!valid) revert InvalidBalanceRead();
        _updateUser(token, msg.sender);
        uint256 owed = _owed[token][msg.sender];
        uint256 amount = owed < balance ? owed : balance;
        unchecked {
            _owed[token][msg.sender] = owed - amount;
            _rewards[token].accounted -= amount;
        }
        TokenTransfer.push(token, msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    /// @notice Advances the token's live stream and starts a new one from fresh balance when none is unfinished.
    function sync(address token) external nonReentrant {
        _checkToken(token);
        (bool valid, uint256 balance) = _sync(token);
        emit Synced(token, valid, balance);
    }

    // ───────────────────────────── views ─────────────────────────────

    function earned(address user, address token) external view returns (uint256) {
        Reward storage r = _rewards[token];
        uint256 index = r.index;
        if (totalStaked > 0 && r.streamAmount > 0 && r.streamSeconds < STREAM_DURATION) {
            uint256 s = r.streamSeconds + (block.timestamp - r.lastSync);
            if (s > STREAM_DURATION) s = STREAM_DURATION;
            uint256 delta = _streamed(r.streamAmount, s) - _streamed(r.streamAmount, r.streamSeconds);
            index += delta.indexGrowth(totalStaked);
        }
        (uint256 amount,) = staked[user].accrue(index - _userIndex[token][user], _carry[token][user]);
        return _owed[token][user] + amount;
    }

    /// @notice Per-token accounting: accounted, index, live stream amount and seconds, last sync timestamp.
    function rewardInfo(address token)
        external
        view
        returns (uint256 accounted, uint256 index, uint256 streamAmount, uint256 streamSeconds, uint256 lastSync)
    {
        Reward storage r = _rewards[token];
        return (r.accounted, r.index, r.streamAmount, r.streamSeconds, r.lastSync);
    }

    // ──────────────────────────── internals ───────────────────────────

    function _checkToken(address token) private pure {
        if (token != BASK && token != USDG && token != WETH) revert InvalidToken();
    }

    function _streamed(uint256 amount, uint256 s) private pure returns (uint256) {
        return amount * s / STREAM_DURATION;
    }

    function _updateAll(address user) private {
        _sync(BASK);
        _updateUser(BASK, user);
        _sync(USDG);
        _updateUser(USDG, user);
        _sync(WETH);
        _updateUser(WETH, user);
    }

    /// @dev Advance the live stream to now (stream time passes only while totalStaked > 0), then look for fresh
    /// balance and start a stream from it when none is unfinished.
    function _sync(address token) private returns (bool valid, uint256 balance) {
        Reward storage r = _rewards[token];
        uint256 s = r.streamSeconds;
        if (totalStaked > 0 && r.streamAmount > 0 && s < STREAM_DURATION) {
            uint256 next = s + (block.timestamp - r.lastSync);
            if (next > STREAM_DURATION) next = STREAM_DURATION;
            uint256 delta = _streamed(r.streamAmount, next) - _streamed(r.streamAmount, s);
            r.index += delta.indexGrowth(totalStaked);
            r.streamSeconds = next;
            s = next;
        }
        r.lastSync = block.timestamp;

        (valid, balance) = _readBalance(token);
        if (!valid) return (false, 0);
        uint256 accounted = r.accounted;
        if (balance < accounted) return (true, balance);
        uint256 fresh = balance - accounted;
        if (fresh == 0 || fresh > MAX_FRESH) return (true, balance);
        bool unfinished = r.streamAmount > 0 && s < STREAM_DURATION;
        if (unfinished) return (true, balance);
        r.accounted = accounted + fresh;
        r.streamAmount = fresh;
        r.streamSeconds = 0;
        emit StreamStarted(token, fresh);
    }

    function _updateUser(address token, address user) private {
        uint256 index = _rewards[token].index;
        (uint256 amount, uint256 carry) = staked[user].accrue(index - _userIndex[token][user], _carry[token][user]);
        _owed[token][user] += amount;
        _carry[token][user] = carry;
        _userIndex[token][user] = index;
    }

    /// @dev balanceOf(this) by staticcall with 50,000 gas, copying at most 32 bytes; valid only on success with
    /// exactly 32 bytes returned.
    function _readBalance(address token) private view returns (bool valid, uint256 amount) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 4), address())
            let ok := staticcall(50000, token, ptr, 36, ptr, 32)
            valid := and(ok, eq(returndatasize(), 32))
            amount := mul(mload(ptr), valid)
        }
    }
}
