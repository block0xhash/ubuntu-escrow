// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {GDOGTestBase} from "./helpers/GDOGTestBase.sol";

contract GDOGBuybackVaultTest is GDOGTestBase {
    function setUp() public override {
        super.setUp();
        _launch();
        vm.roll(token.launchBlock() + 10); // clear of the anti-snipe decay window
        vm.deal(address(vault), 10 ether);
    }

    // ---------------------------------------------------------------------
    // Funding / access control
    // ---------------------------------------------------------------------

    function test_Receive_AcceptsEth() public {
        uint256 before = address(vault).balance;
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, before + 1 ether);
    }

    function test_RevertWhen_NonAgentCallsExecuteBuyback() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Vault: not agent"));
        vault.executeBuyback(1 ether);
    }

    // ---------------------------------------------------------------------
    // Guardrails: this is the load-bearing behavior - a compromised or
    // malfunctioning agent key can only spend at a bounded rate, never drain
    // the vault in one call.
    // ---------------------------------------------------------------------

    function test_ExecuteBuyback_ClampsToMaxBuybackBps() public {
        uint256 balBefore = address(vault).balance;
        uint256 cap = (balBefore * vault.maxBuybackBps()) / 10_000;

        vm.prank(agent);
        vault.executeBuyback(balBefore); // agent asks for the whole balance

        assertEq(address(vault).balance, balBefore - cap, "spend should be clamped to the per-call cap");
    }

    function test_ExecuteBuyback_BurnsGdog() public {
        uint256 burnBefore = token.balanceOf(token.BURN_ADDRESS());
        vm.prank(agent);
        vault.executeBuyback(1 ether);
        assertGt(token.balanceOf(token.BURN_ADDRESS()), burnBefore);
    }

    function test_RevertWhen_BuybackDuringCooldown() public {
        vm.startPrank(agent);
        vault.executeBuyback(0.1 ether);
        vm.expectRevert(bytes("Vault: cooldown active"));
        vault.executeBuyback(0.1 ether);
        vm.stopPrank();
    }

    function test_Buyback_AllowedAfterCooldownElapses() public {
        vm.prank(agent);
        vault.executeBuyback(0.1 ether);

        vm.warp(block.timestamp + vault.buybackCooldown());
        vm.prank(agent);
        vault.executeBuyback(0.1 ether); // must not revert
    }

    function test_RevertWhen_PausedBlocksExecuteBuyback() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(agent);
        vm.expectRevert();
        vault.executeBuyback(0.1 ether);
    }

    // ---------------------------------------------------------------------
    // Owner-side manual override
    // ---------------------------------------------------------------------

    function test_RevertWhen_NonOwnerCallsManualBuyback() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.manualBuyback(0.1 ether);
    }

    function test_ManualBuyback_BurnsGdog() public {
        uint256 burnBefore = token.balanceOf(token.BURN_ADDRESS());
        vm.prank(owner);
        vault.manualBuyback(0.1 ether);
        assertGt(token.balanceOf(token.BURN_ADDRESS()), burnBefore);
    }

    function test_ManualBuyback_NotBlockedByAgentCooldown() public {
        vm.prank(agent);
        vault.executeBuyback(0.1 ether); // starts the agent-path cooldown clock

        vm.prank(owner);
        vault.manualBuyback(0.1 ether); // owner path ignores buybackCooldown by design
    }

    // ---------------------------------------------------------------------
    // Ops withdrawal rate-limiting
    // ---------------------------------------------------------------------

    function test_WithdrawOps_RespectsEpochCap() public {
        uint256 cap = (address(vault).balance * vault.opsWithdrawBps()) / 10_000;

        vm.startPrank(owner);
        vault.withdrawOps(marketing, cap);

        vm.expectRevert(bytes("Vault: exceeds ops cap"));
        vault.withdrawOps(marketing, 1);
        vm.stopPrank();
    }

    function test_WithdrawOps_CapResetsNextEpoch() public {
        uint256 cap = (address(vault).balance * vault.opsWithdrawBps()) / 10_000;

        vm.prank(owner);
        vault.withdrawOps(marketing, cap);

        vm.warp(block.timestamp + 7 days);

        uint256 newCap = (address(vault).balance * vault.opsWithdrawBps()) / 10_000;
        vm.prank(owner);
        vault.withdrawOps(marketing, newCap); // new epoch, cap has reset - must not revert
    }

    function test_RevertWhen_NonOwnerCallsWithdrawOps() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawOps(alice, 0.1 ether);
    }

    // ---------------------------------------------------------------------
    // Admin surface
    // ---------------------------------------------------------------------

    function test_SetAgent_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setAgent(alice);

        vm.prank(owner);
        vault.setAgent(bob);
        assertEq(vault.agent(), bob);
    }

    function test_RevertWhen_GuardrailsOutOfBounds() public {
        vm.startPrank(owner);

        vm.expectRevert(bytes("Vault: cooldown too short"));
        vault.setGuardrails(1 minutes, 2500, 2000);

        vm.expectRevert(bytes("Vault: max buyback too high"));
        vault.setGuardrails(1 hours, 5001, 2000);

        vm.expectRevert(bytes("Vault: max ops withdraw too high"));
        vault.setGuardrails(1 hours, 2500, 3001);

        vm.stopPrank();
    }

    function test_SetGuardrails_UpdatesState() public {
        vm.prank(owner);
        vault.setGuardrails(2 hours, 1000, 1000);

        assertEq(vault.buybackCooldown(), 2 hours);
        assertEq(vault.maxBuybackBps(), 1000);
        assertEq(vault.opsWithdrawBps(), 1000);
    }

    function test_PauseUnpause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }
}
