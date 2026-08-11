// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title GswapLocker
/// @notice Permissionless, non-custodial time-lock for any ERC20 - built for GSWAP LP
/// tokens (the actual "liquidity locking" use case) but works for any token, since
/// there's no real reason to special-case that. Deliberately has zero admin surface:
/// no owner, no pause, no early-release override. Nobody - not the deployer, not
/// whoever wrote this contract - can move a lock's tokens out before its unlock time.
/// That absence of a backdoor *is* the feature; a locker with an owner-only escape
/// hatch isn't meaningfully different from not locking at all.
contract GswapLocker {
    struct Lock {
        address token;
        address owner;
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
    }

    mapping(uint256 => Lock) public locks;
    uint256 public lockCount;

    mapping(address => uint256[]) private _locksByOwner;
    mapping(address => uint256[]) private _locksByToken;

    event LockCreated(uint256 indexed lockId, address indexed token, address indexed owner, uint256 amount, uint256 unlockTime);
    event LockIncreased(uint256 indexed lockId, uint256 amountAdded, uint256 newAmount);
    event LockExtended(uint256 indexed lockId, uint256 newUnlockTime);
    event LockOwnerChanged(uint256 indexed lockId, address indexed previousOwner, address indexed newOwner);
    event LockWithdrawn(uint256 indexed lockId, address indexed to, uint256 amount);

    modifier onlyLockOwner(uint256 lockId) {
        require(locks[lockId].owner == msg.sender, "Locker: not lock owner");
        _;
    }

    /// @notice Locks `amount` of `token` until `unlockTime`. Measures the actual amount
    /// received rather than trusting the parameter, so this stays correct for
    /// fee-on-transfer tokens too - a locker that under-counts what it actually holds
    /// for a tax token would be a real bug, not a theoretical one.
    function lockTokens(address token, uint256 amount, uint256 unlockTime) external returns (uint256 lockId) {
        require(token != address(0), "Locker: zero token");
        require(amount > 0, "Locker: zero amount");
        require(unlockTime > block.timestamp, "Locker: unlock time must be future");

        uint256 received = _pullTokens(token, amount);
        require(received > 0, "Locker: nothing received");

        lockId = lockCount++;
        locks[lockId] = Lock({
            token: token,
            owner: msg.sender,
            amount: received,
            unlockTime: unlockTime,
            withdrawn: false
        });
        _locksByOwner[msg.sender].push(lockId);
        _locksByToken[token].push(lockId);

        emit LockCreated(lockId, token, msg.sender, received, unlockTime);
    }

    /// @notice Adds more of the same token to an existing, not-yet-withdrawn lock.
    /// Does not change the unlock time.
    function addToLock(uint256 lockId, uint256 amount) external onlyLockOwner(lockId) {
        Lock storage l = locks[lockId];
        require(!l.withdrawn, "Locker: already withdrawn");
        require(amount > 0, "Locker: zero amount");

        uint256 received = _pullTokens(l.token, amount);
        l.amount += received;

        emit LockIncreased(lockId, received, l.amount);
    }

    /// @notice Pushes a lock's unlock time further into the future. One-directional by
    /// design - a "lock" that could be shortened isn't one.
    function extendLock(uint256 lockId, uint256 newUnlockTime) external onlyLockOwner(lockId) {
        Lock storage l = locks[lockId];
        require(!l.withdrawn, "Locker: already withdrawn");
        require(newUnlockTime > l.unlockTime, "Locker: can only extend forward");

        l.unlockTime = newUnlockTime;
        emit LockExtended(lockId, newUnlockTime);
    }

    /// @notice Reassigns who can manage/withdraw a lock - e.g. moving it from a
    /// deployer's EOA to a multisig without needing to withdraw-and-relock (which would
    /// mean a moment where the tokens aren't locked at all).
    function transferLockOwnership(uint256 lockId, address newOwner) external onlyLockOwner(lockId) {
        require(newOwner != address(0), "Locker: zero address");
        Lock storage l = locks[lockId];
        require(!l.withdrawn, "Locker: already withdrawn");

        address previousOwner = l.owner;
        l.owner = newOwner;
        _locksByOwner[newOwner].push(lockId);

        emit LockOwnerChanged(lockId, previousOwner, newOwner);
    }

    /// @notice Withdraws a lock's full balance to its owner, only once unlockTime has
    /// passed. Marks withdrawn before the external transfer (checks-effects-interactions)
    /// so this can't be re-entered into a double withdrawal.
    function withdraw(uint256 lockId) external onlyLockOwner(lockId) {
        Lock storage l = locks[lockId];
        require(!l.withdrawn, "Locker: already withdrawn");
        require(block.timestamp >= l.unlockTime, "Locker: still locked");

        uint256 amount = l.amount;
        l.withdrawn = true;

        require(IERC20(l.token).transfer(msg.sender, amount), "Locker: transfer failed");
        emit LockWithdrawn(lockId, msg.sender, amount);
    }

    function getLocksByOwner(address owner) external view returns (uint256[] memory) {
        return _locksByOwner[owner];
    }

    function getLocksByToken(address token) external view returns (uint256[] memory) {
        return _locksByToken[token];
    }

    function _pullTokens(address token, uint256 amount) private returns (uint256 received) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Locker: transferFrom failed");
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    }
}
