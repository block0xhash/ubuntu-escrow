// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {GDOGToken} from "../src/GDOGToken.sol";
import {GDOGBuybackVault} from "../src/GDOGBuybackVault.sol";
import {MockWETH} from "./mocks/MockUniswapV2.sol";
import {GDOGTestBase} from "./helpers/GDOGTestBase.sol";

contract GDOGTokenTest is GDOGTestBase {
    bytes32 constant TAX_SWAPPED_SIG = keccak256("TaxSwapped(uint256,uint256)");

    // ---------------------------------------------------------------------
    // Deployment / wiring
    // ---------------------------------------------------------------------

    function test_InitialState() public view {
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
        assertEq(token.balanceOf(owner), token.TOTAL_SUPPLY() - TREASURY_SEED);
        assertTrue(token.automatedMarketMakerPairs(token.uniswapV2Pair()));
        assertTrue(token.isExcludedFromFees(owner));
        assertTrue(token.isExcludedFromLimits(owner));
        assertTrue(token.isExcludedFromLimits(token.BURN_ADDRESS()));
        assertEq(token.buybackVault(), address(vault));
        assertEq(token.liquidityTreasury(), TREASURY_SEED);
        assertFalse(token.tradingEnabled());
    }

    function test_RevertWhen_EnableTradingWithoutVaultSet() public {
        vm.startPrank(owner);
        GDOGToken bare = new GDOGToken(address(router), marketing, address(0), lpLock, owner);
        vm.expectRevert(bytes("GDOG: buyback vault not set"));
        bare.enableTrading();
        vm.stopPrank();
    }

    function test_RevertWhen_SetBuybackVaultAfterLaunch() public {
        _launch();
        vm.prank(owner);
        vm.expectRevert(bytes("GDOG: trading already live"));
        token.setBuybackVault(address(0xBEEF));
    }

    function test_RevertWhen_EnableTradingTwice() public {
        _launch();
        vm.prank(owner);
        vm.expectRevert(bytes("GDOG: already enabled"));
        token.enableTrading();
    }

    function test_FundLiquidityTreasury() public {
        uint256 before = token.liquidityTreasury();
        vm.prank(owner);
        token.transfer(alice, 1_000_000e18);

        vm.prank(alice);
        token.fundLiquidityTreasury(500_000e18);

        assertEq(token.liquidityTreasury(), before + 500_000e18);
        assertEq(token.balanceOf(alice), 500_000e18);
    }

    // ---------------------------------------------------------------------
    // Trading gate
    // ---------------------------------------------------------------------

    function test_RevertWhen_TransferBeforeTradingEnabled() public {
        vm.prank(owner);
        token.transfer(alice, 1_000e18); // owner is exempt, always allowed

        vm.prank(alice);
        vm.expectRevert(bytes("GDOG: trading not enabled"));
        token.transfer(bob, 1e18); // neither alice nor bob is exempt
    }

    // ---------------------------------------------------------------------
    // Anti-snipe launch tax decay
    // ---------------------------------------------------------------------

    function test_LaunchTaxDecaySchedule() public {
        _launch();
        uint256 launchBlock = token.launchBlock();
        uint16[6] memory expected = [2000, 1700, 1400, 1100, 800, 500];

        for (uint256 i = 0; i < expected.length; i++) {
            vm.roll(launchBlock + i);
            assertEq(token.currentTaxBps(), expected[i], "unexpected tax bps");
        }

        vm.roll(launchBlock + 100);
        assertEq(token.currentTaxBps(), 500, "should stay flat at base tax");
    }

    // ---------------------------------------------------------------------
    // Anti-bot limits
    // ---------------------------------------------------------------------

    function test_RevertWhen_SellExceedsMaxTx() public {
        _launch();
        vm.roll(token.launchBlock() + 10);

        vm.prank(owner);
        token.transfer(alice, 11_000_000e18); // owner transfer is exempt from the cap

        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);

        vm.startPrank(alice);
        token.approve(address(router), 11_000_000e18);
        vm.expectRevert(bytes("GDOG: exceeds max tx"));
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(11_000_000e18, 0, path, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyExceedsMaxWallet() public {
        _launch();
        vm.roll(token.launchBlock() + 10);

        vm.prank(owner);
        token.transfer(bob, 19_999_000e18); // ~1,000e18 of headroom under the 2% cap

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(token);

        deal(bob, 1 ether); // 1 ETH into a 100-ETH-deep pool is far more than 1,000e18 GDOG
        vm.prank(bob);
        vm.expectRevert(bytes("GDOG: exceeds max wallet"));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(0, path, bob, block.timestamp);
    }

    function test_RaiseLimits_OnlyIncreases() public {
        uint256 tx0 = token.maxTxAmount();
        uint256 wallet0 = token.maxWalletAmount();

        vm.startPrank(owner);
        vm.expectRevert(bytes("GDOG: cannot lower maxTx"));
        token.raiseLimits(tx0 - 1, wallet0);

        vm.expectRevert(bytes("GDOG: cannot lower maxWallet"));
        token.raiseLimits(tx0, wallet0 - 1);

        token.raiseLimits(tx0 * 2, wallet0 * 2);
        vm.stopPrank();

        assertEq(token.maxTxAmount(), tx0 * 2);
        assertEq(token.maxWalletAmount(), wallet0 * 2);
    }

    function test_BurnAddress_ExemptFromMaxWalletCap() public {
        _launch();
        vm.roll(token.launchBlock() + 10);

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(token);

        // Repeated buys-to-burn (what GDOGBuybackVault does) must not start reverting
        // once the dead address's balance crosses the 2% max-wallet cap.
        for (uint256 i = 0; i < 5; i++) {
            deal(address(this), 5 ether);
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 5 ether}(
                0, path, token.BURN_ADDRESS(), block.timestamp
            );
        }

        assertGt(token.balanceOf(token.BURN_ADDRESS()), token.maxWalletAmount());
    }

    // ---------------------------------------------------------------------
    // Receiver-side tax: collection, swap, distribution
    // ---------------------------------------------------------------------

    function test_TaxDistribution_MatchesFixedRatio() public {
        _launch();
        vm.roll(token.launchBlock() + 10); // past decay, flat 5%

        vm.prank(owner);
        token.transfer(alice, 5_000_000e18);

        _sell(alice, 1_000_000e18); // collects tax into the contract; nothing to swap yet

        vm.recordLogs();
        _sell(alice, 1_000_000e18); // this trigger swaps what the first sell accrued

        uint256 ethOut = _decodeTaxSwappedEthOut(vm.getRecordedLogs());
        assertGt(ethOut, 0);

        uint256 expectedMarketing = (ethOut * 250) / 500;
        uint256 expectedDev = (ethOut * 100) / 500;

        assertEq(marketing.balance, expectedMarketing);
        assertEq(address(vault).balance, expectedDev);
    }

    function test_AutoLiquidity_ConsumesTreasuryAndMintsLP() public {
        _launch();
        vm.roll(token.launchBlock() + 10);

        IERC20 pair = IERC20(token.uniswapV2Pair());
        uint256 lpBefore = pair.balanceOf(lpLock);
        uint256 treasuryBefore = token.liquidityTreasury();

        vm.prank(owner);
        token.transfer(alice, 5_000_000e18);
        _sell(alice, 1_000_000e18);
        _sell(alice, 1_000_000e18); // swaps + adds liquidity from the treasury bucket

        assertLt(token.liquidityTreasury(), treasuryBefore);
        assertGt(pair.balanceOf(lpLock), lpBefore);
    }

    function test_LiquidityTreasuryEmpty_FallsBackToMarketing() public {
        vm.startPrank(owner);
        GDOGToken token2 = new GDOGToken(address(router), marketing, address(0), lpLock, owner);
        GDOGBuybackVault vault2 = new GDOGBuybackVault(address(router), address(token2), agent, owner);
        token2.setBuybackVault(address(vault2));
        // Deliberately skip fundLiquidityTreasury(): treasury stays at 0.
        token2.approve(address(router), INITIAL_LP_TOKENS);
        router.addLiquidityETH{value: INITIAL_LP_ETH}(
            address(token2), INITIAL_LP_TOKENS, 0, 0, lpLock, block.timestamp
        );
        token2.enableTrading();
        token2.transfer(alice, 5_000_000e18);
        vm.stopPrank();

        vm.roll(token2.launchBlock() + 10);

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(token2);
        sellPath[1] = address(weth);

        vm.startPrank(alice);
        token2.approve(address(router), 2_000_000e18);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(1_000_000e18, 0, sellPath, alice, block.timestamp);

        vm.recordLogs();
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(1_000_000e18, 0, sellPath, alice, block.timestamp);
        vm.stopPrank();

        uint256 ethOut = _decodeTaxSwappedEthOut(vm.getRecordedLogs());
        uint256 expectedDev = (ethOut * 100) / 500;

        // With no treasury to pair against, the liquidity leg falls back to marketing
        // instead of stranding ETH in the contract.
        assertEq(address(vault2).balance, expectedDev);
        assertEq(marketing.balance, ethOut - expectedDev);
    }

    // ---------------------------------------------------------------------
    // Admin surface
    // ---------------------------------------------------------------------

    function test_RescueForeignToken() public {
        deal(address(this), 1 ether);
        MockWETH foreign = new MockWETH();
        foreign.deposit{value: 1 ether}();
        foreign.transfer(address(token), 1 ether);

        vm.prank(owner);
        token.rescueForeignToken(address(foreign), owner, 1 ether);
        assertEq(foreign.balanceOf(owner), 1 ether);
    }

    function test_RevertWhen_RescueGdogItself() public {
        vm.prank(owner);
        vm.expectRevert(bytes("GDOG: cannot rescue GDOG"));
        token.rescueForeignToken(address(token), owner, 1);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _decodeTaxSwappedEthOut(Vm.Log[] memory logs) internal pure returns (uint256 ethOut) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == TAX_SWAPPED_SIG) {
                (, ethOut) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }
}
