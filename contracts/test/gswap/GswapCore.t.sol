// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {GswapPair} from "../../src/gswap/GswapPair.sol";
import {GswapTestBase} from "./helpers/GswapTestBase.sol";

contract GswapCoreTest is GswapTestBase {
    function test_CreatePair_SortsTokensAndRegistersBothDirections() public {
        vm.prank(owner);
        address pair = factory.createPair(address(tokenA), address(tokenB));

        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
        assertEq(factory.allPairsLength(), 1);

        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        assertEq(GswapPair(pair).token0(), token0);
        assertEq(GswapPair(pair).token1(), token1);
    }

    function test_RevertWhen_CreatingDuplicatePair() public {
        vm.startPrank(owner);
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(bytes("Gswap: PAIR_EXISTS"));
        factory.createPair(address(tokenB), address(tokenA)); // order shouldn't matter
        vm.stopPrank();
    }

    function test_Mint_LocksMinimumLiquidityPermanently() public {
        _seedPool(tokenA, tokenB, 100_000e18, 100_000e18);

        address pair = factory.getPair(address(tokenA), address(tokenB));
        uint256 minLiq = GswapPair(pair).MINIMUM_LIQUIDITY();
        assertEq(IERC20(pair).balanceOf(GswapPair(pair).DEAD()), minLiq);

        // sqrt(100_000e18 * 100_000e18) - MINIMUM_LIQUIDITY
        uint256 expectedOwnerLiquidity = 100_000e18 - minLiq;
        assertEq(IERC20(pair).balanceOf(owner), expectedOwnerLiquidity);
    }

    function test_Burn_ReturnsProportionalTokens() public {
        _seedPool(tokenA, tokenB, 100_000e18, 100_000e18);
        address pair = factory.getPair(address(tokenA), address(tokenB));
        uint256 lpBalance = IERC20(pair).balanceOf(owner);

        vm.startPrank(owner);
        IERC20(pair).approve(address(router), lpBalance);
        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(address(tokenA), address(tokenB), lpBalance, 0, 0, owner, block.timestamp);
        vm.stopPrank();

        // Owner held effectively the whole pool (minus the permanently locked minimum),
        // so withdrawing it all returns close to the full deposit.
        assertApproxEqAbs(amountA, 100_000e18, 1e12);
        assertApproxEqAbs(amountB, 100_000e18, 1e12);
    }

    function test_Swap_RevertsOnKViolation() public {
        _seedPool(tokenA, tokenB, 100_000e18, 100_000e18);
        address pair = factory.getPair(address(tokenA), address(tokenB));

        // Send tokens in directly (bypassing the router) then demand an output that
        // would break the constant-product invariant net of the 0.3% fee.
        vm.prank(owner);
        tokenA.transfer(pair, 1_000e18);

        (address token0,) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        bool aIsToken0 = token0 == address(tokenA);

        vm.expectRevert(bytes("Gswap: K"));
        if (aIsToken0) {
            GswapPair(pair).swap(0, 999e18, address(this)); // way more than 1,000 tokens in should buy
        } else {
            GswapPair(pair).swap(999e18, 0, address(this));
        }
    }

    function test_ProtocolFee_MintsLpSharesToFeeTo() public {
        vm.prank(owner);
        factory.setFeeTo(feeCollector);

        _seedPool(tokenA, tokenB, 1_000_000e18, 1_000_000e18);
        address pair = factory.getPair(address(tokenA), address(tokenB));

        // Generate swap volume so sqrt(k) grows between liquidity events.
        tokenA.mint(alice, 100_000e18);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        for (uint256 i; i < 5; i++) {
            router.swapExactTokensForTokens(10_000e18, 0, path, alice, block.timestamp);
            address[] memory back = new address[](2);
            back[0] = address(tokenB);
            back[1] = address(tokenA);
            tokenB.approve(address(router), type(uint256).max);
            router.swapExactTokensForTokens(tokenB.balanceOf(alice), 0, back, alice, block.timestamp);
        }
        vm.stopPrank();

        assertEq(IERC20(pair).balanceOf(feeCollector), 0, "no fee minted until the next liquidity event");

        // Any further mint/burn triggers _mintFee against the accumulated growth.
        _seedPool(tokenA, tokenB, 1_000e18, 1_000e18);

        assertGt(IERC20(pair).balanceOf(feeCollector), 0, "protocol fee should have minted LP shares");
    }

    function test_RevertWhen_NonFeeToSetterChangesFeeTo() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Gswap: FORBIDDEN"));
        factory.setFeeTo(alice);
    }
}
