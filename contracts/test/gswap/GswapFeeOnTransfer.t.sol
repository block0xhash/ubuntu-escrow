// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {GDOGToken} from "../../src/GDOGToken.sol";
import {GDOGBuybackVault} from "../../src/GDOGBuybackVault.sol";
import {GswapTestBase} from "./helpers/GswapTestBase.sol";

/// @notice Closes the loop on GDOGToken's "must not break Uniswap/GSWAP V2
/// compatibility" requirement by running it against the real GswapRouter02/GswapPair,
/// not the standalone test mock used in GDOGToken.t.sol. In particular this is what
/// catches a router that exposes `weth()` instead of the `WETH()` GDOGToken's
/// IUniswapV2Router02 interface expects - a mismatch that would silently break every
/// GDOG trade against a live GSWAP deployment.
contract GswapFeeOnTransferTest is GswapTestBase {
    GDOGToken internal gdog;
    GDOGBuybackVault internal vault;

    address internal marketing = makeAddr("marketing");
    address internal lpLock = makeAddr("lpLock");
    address internal agent = makeAddr("agent");
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        gdog = new GDOGToken(address(router), marketing, address(0), lpLock, owner);
        vault = new GDOGBuybackVault(address(router), address(gdog), agent, owner);
        gdog.setBuybackVault(address(vault));
        gdog.fundLiquidityTreasury(50_000_000e18);

        gdog.approve(address(router), 200_000_000e18);
        router.addLiquidityETH{value: 100 ether}(address(gdog), 200_000_000e18, 0, 0, lpLock, block.timestamp);
        gdog.enableTrading();
        vm.stopPrank();

        vm.roll(gdog.launchBlock() + 10); // past the anti-snipe decay window
    }

    function test_Buy_ThroughRealRouter_AppliesTax() public {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(gdog);

        deal(trader, 1 ether);
        vm.prank(trader);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(0, path, trader, block.timestamp);

        assertGt(gdog.balanceOf(trader), 0);
        assertGt(gdog.pendingTaxTokens(), 0, "buy tax should have accrued");
    }

    function test_Sell_ThroughRealRouter_SwapsAndDistributes() public {
        vm.prank(owner);
        gdog.transfer(trader, 5_000_000e18);

        address[] memory sellPath = new address[](2);
        sellPath[0] = address(gdog);
        sellPath[1] = address(weth);

        vm.startPrank(trader);
        gdog.approve(address(router), 2_000_000e18);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(1_000_000e18, 0, sellPath, trader, block.timestamp);
        // second sell triggers the swap-and-distribute of what the first sell accrued
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(1_000_000e18, 0, sellPath, trader, block.timestamp);
        vm.stopPrank();

        assertGt(marketing.balance, 0, "marketing leg should have received ETH");
        assertGt(address(vault).balance, 0, "vault leg should have received ETH");
    }

    function test_VaultBuyback_ThroughRealRouter_Burns() public {
        // Fund the vault the way live trading would, then let the agent trigger a buyback.
        vm.deal(address(vault), 5 ether);

        uint256 burnBefore = gdog.balanceOf(gdog.BURN_ADDRESS());
        vm.prank(agent);
        vault.executeBuyback(1 ether);

        assertGt(gdog.balanceOf(gdog.BURN_ADDRESS()), burnBefore);
    }
}
