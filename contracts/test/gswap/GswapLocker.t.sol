// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {GswapLocker} from "../../src/gswap/GswapLocker.sol";
import {GswapTestBase} from "./helpers/GswapTestBase.sol";

contract GswapLockerTest is GswapTestBase {
    GswapLocker internal locker;

    function setUp() public override {
        super.setUp();
        locker = new GswapLocker();
        vm.prank(owner);
        tokenA.mint(alice, 1_000e18);
    }

    // ---------------------------------------------------------------------
    // Locking
    // ---------------------------------------------------------------------

    function test_LockTokens_TransfersAndRecordsLock() public {
        uint256 unlockTime = block.timestamp + 30 days;

        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, unlockTime);
        vm.stopPrank();

        (address token, address lockOwner, uint256 amount, uint256 unlock, bool withdrawn) = locker.locks(lockId);
        assertEq(token, address(tokenA));
        assertEq(lockOwner, alice);
        assertEq(amount, 100e18);
        assertEq(unlock, unlockTime);
        assertFalse(withdrawn);

        assertEq(tokenA.balanceOf(address(locker)), 100e18);
        assertEq(tokenA.balanceOf(alice), 900e18);
    }

    function test_RevertWhen_UnlockTimeInPast() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        vm.expectRevert(bytes("Locker: unlock time must be future"));
        locker.lockTokens(address(tokenA), 100e18, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_LockingZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Locker: zero amount"));
        locker.lockTokens(address(tokenA), 0, block.timestamp + 1 days);
    }

    function test_RevertWhen_LockingZeroToken() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Locker: zero token"));
        locker.lockTokens(address(0), 100e18, block.timestamp + 1 days);
    }

    // ---------------------------------------------------------------------
    // Adding to a lock
    // ---------------------------------------------------------------------

    function test_AddToLock_IncreasesAmountWithoutChangingUnlockTime() public {
        uint256 unlockTime = block.timestamp + 30 days;
        vm.startPrank(alice);
        tokenA.approve(address(locker), 200e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, unlockTime);

        locker.addToLock(lockId, 50e18);
        vm.stopPrank();

        (,, uint256 amount, uint256 unlock,) = locker.locks(lockId);
        assertEq(amount, 150e18);
        assertEq(unlock, unlockTime, "adding to a lock must not change its unlock time");
    }

    function test_RevertWhen_NonOwnerAddsToLock() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(bytes("Locker: not lock owner"));
        locker.addToLock(lockId, 1e18);
    }

    // ---------------------------------------------------------------------
    // Extending
    // ---------------------------------------------------------------------

    function test_ExtendLock_PushesUnlockTimeForward() public {
        uint256 originalUnlock = block.timestamp + 10 days;
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, originalUnlock);

        locker.extendLock(lockId, originalUnlock + 10 days);
        vm.stopPrank();

        (,,, uint256 unlock,) = locker.locks(lockId);
        assertEq(unlock, originalUnlock + 10 days);
    }

    function test_RevertWhen_ExtendingBackward() public {
        uint256 originalUnlock = block.timestamp + 10 days;
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, originalUnlock);

        vm.expectRevert(bytes("Locker: can only extend forward"));
        locker.extendLock(lockId, originalUnlock - 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Ownership transfer
    // ---------------------------------------------------------------------

    function test_TransferLockOwnership_NewOwnerCanWithdrawAfterUnlock() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        locker.transferLockOwnership(lockId, bob);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        locker.withdraw(lockId);

        assertEq(tokenA.balanceOf(bob), 100e18);
    }

    function test_RevertWhen_OldOwnerActsAfterTransfer() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        locker.transferLockOwnership(lockId, bob);

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(bytes("Locker: not lock owner"));
        locker.withdraw(lockId);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Withdrawing
    // ---------------------------------------------------------------------

    function test_RevertWhen_WithdrawBeforeUnlockTime() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 30 days);

        vm.expectRevert(bytes("Locker: still locked"));
        locker.withdraw(lockId);
        vm.stopPrank();
    }

    function test_Withdraw_AfterUnlockTime_TransfersAndMarksWithdrawn() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        locker.withdraw(lockId);

        (,,,, bool withdrawn) = locker.locks(lockId);
        assertTrue(withdrawn);
        assertEq(tokenA.balanceOf(alice), 1_000e18); // back to the pre-lock balance
    }

    function test_RevertWhen_WithdrawingTwice() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        uint256 lockId = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(alice);
        locker.withdraw(lockId);

        vm.expectRevert(bytes("Locker: already withdrawn"));
        locker.withdraw(lockId);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Enumeration
    // ---------------------------------------------------------------------

    function test_GetLocksByOwner_ReturnsAllOfThatOwnersLocks() public {
        vm.startPrank(alice);
        tokenA.approve(address(locker), 300e18);
        uint256 lockId1 = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        uint256 lockId2 = locker.lockTokens(address(tokenA), 100e18, block.timestamp + 2 days);
        vm.stopPrank();

        uint256[] memory aliceLocks = locker.getLocksByOwner(alice);
        assertEq(aliceLocks.length, 2);
        assertEq(aliceLocks[0], lockId1);
        assertEq(aliceLocks[1], lockId2);
    }

    function test_GetLocksByToken_ReturnsLocksAcrossOwners() public {
        vm.prank(owner);
        tokenA.mint(bob, 100e18);

        vm.startPrank(alice);
        tokenA.approve(address(locker), 100e18);
        locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(locker), 100e18);
        locker.lockTokens(address(tokenA), 100e18, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(locker.getLocksByToken(address(tokenA)).length, 2);
    }

    // ---------------------------------------------------------------------
    // Real end-to-end use case: locking actual GSWAP LP tokens
    // ---------------------------------------------------------------------

    function test_LockRealGswapLpTokens_EndToEnd() public {
        _seedPool(tokenA, tokenB, 100_000e18, 100_000e18);
        address pair = factory.getPair(address(tokenA), address(tokenB));
        uint256 lpBalance = _erc20BalanceOf(pair, owner);
        assertGt(lpBalance, 0);

        vm.startPrank(owner);
        _approveErc20(pair, address(locker), lpBalance);
        uint256 lockId = locker.lockTokens(pair, lpBalance, block.timestamp + 365 days);
        vm.stopPrank();

        assertEq(_erc20BalanceOf(pair, owner), 0, "LP tokens should have left the owner's wallet");
        assertEq(_erc20BalanceOf(pair, address(locker)), lpBalance);

        vm.prank(owner);
        vm.expectRevert(bytes("Locker: still locked"));
        locker.withdraw(lockId);
    }

    function _erc20BalanceOf(address token, address account) internal view returns (uint256 result) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(ok, "balanceOf failed");
        result = abi.decode(data, (uint256));
    }

    function _approveErc20(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }
}
