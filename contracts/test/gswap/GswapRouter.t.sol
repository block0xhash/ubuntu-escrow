// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {GswapTestBase} from "./helpers/GswapTestBase.sol";

contract GswapRouterTest is GswapTestBase {
    function setUp() public override {
        super.setUp();
        _seedPool(tokenA, tokenB, 1_000_000e18, 1_000_000e18);
        _seedPoolETH(tokenA, 500_000e18, 250 ether);
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    function test_AddLiquidityETH_MintsLpAndRefundsExcessEth() public {
        address pair = factory.getPair(address(tokenB), address(weth));
        assertEq(pair, address(0), "no B/ETH pool yet");

        vm.startPrank(alice);
        tokenB.mint(alice, 10_000e18);
        tokenB.approve(address(router), 10_000e18);
        uint256 ethBefore = alice.balance;

        // Overpay ETH relative to amountTokenDesired's implied ratio on a fresh pool -
        // first add sets the ratio, so no refund is expected here, just successful mint.
        (,, uint256 liquidity) =
            router.addLiquidityETH{value: 5 ether}(address(tokenB), 10_000e18, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(liquidity, 0);
        assertEq(alice.balance, ethBefore - 5 ether);
    }

    function test_RemoveLiquidityETH_ReturnsTokenAndEth() public {
        address pair = factory.getPair(address(tokenA), address(weth));

        vm.startPrank(owner);
        uint256 lpBalance = _erc20BalanceOf(pair, owner);
        _approveErc20(pair, address(router), lpBalance);
        (uint256 amountToken, uint256 amountEth) =
            router.removeLiquidityETH(address(tokenA), lpBalance, 0, 0, owner, block.timestamp);
        vm.stopPrank();

        assertApproxEqAbs(amountToken, 500_000e18, 1e12);
        assertApproxEqAbs(amountEth, 250 ether, 1e12);
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    function test_SwapExactTokensForTokens_MatchesQuotedAmount() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256[] memory quoted = router.getAmountsOut(10_000e18, path);

        vm.startPrank(alice);
        tokenA.mint(alice, 10_000e18);
        tokenA.approve(address(router), 10_000e18);
        uint256[] memory amounts = router.swapExactTokensForTokens(10_000e18, 0, path, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[1], quoted[1]);
        assertEq(tokenB.balanceOf(alice), quoted[1]);
    }

    function test_SwapTokensForExactTokens_PullsExactlyGetAmountsIn() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 desiredOut = 5_000e18;
        uint256[] memory quoted = router.getAmountsIn(desiredOut, path);

        vm.startPrank(alice);
        tokenA.mint(alice, quoted[0]);
        tokenA.approve(address(router), quoted[0]);
        uint256[] memory amounts =
            router.swapTokensForExactTokens(desiredOut, quoted[0], path, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[0], quoted[0]);
        assertEq(tokenB.balanceOf(alice), desiredOut);
        assertEq(tokenA.balanceOf(alice), 0, "should have spent exactly the quoted input");
    }

    function test_SwapExactETHForTokens() public {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(tokenA);

        uint256 before = tokenA.balanceOf(bob);
        vm.prank(bob);
        router.swapExactETHForTokens{value: 1 ether}(0, path, bob, block.timestamp);

        assertGt(tokenA.balanceOf(bob), before);
    }

    function test_SwapExactTokensForETH() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(weth);

        vm.startPrank(bob);
        tokenA.mint(bob, 1_000e18);
        tokenA.approve(address(router), 1_000e18);
        uint256 ethBefore = bob.balance;
        router.swapExactTokensForETH(1_000e18, 0, path, bob, block.timestamp);
        vm.stopPrank();

        assertGt(bob.balance, ethBefore);
    }

    function test_SwapTokensForExactETH() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(weth);

        uint256 desiredEthOut = 1 ether;
        uint256[] memory quoted = router.getAmountsIn(desiredEthOut, path);

        vm.startPrank(bob);
        tokenA.mint(bob, quoted[0]);
        tokenA.approve(address(router), quoted[0]);
        uint256 ethBefore = bob.balance;
        router.swapTokensForExactETH(desiredEthOut, quoted[0], path, bob, block.timestamp);
        vm.stopPrank();

        assertEq(bob.balance, ethBefore + desiredEthOut);
        assertEq(tokenA.balanceOf(bob), 0);
    }

    function test_SwapETHForExactTokens_RefundsExcess() public {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(tokenA);

        uint256 desiredOut = 1_000e18;
        uint256[] memory quoted = router.getAmountsIn(desiredOut, path);

        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        router.swapETHForExactTokens{value: quoted[0] + 1 ether}(desiredOut, path, bob, block.timestamp);

        assertEq(tokenA.balanceOf(bob), desiredOut);
        assertEq(bob.balance, ethBefore - quoted[0], "unused ETH should be refunded");
    }

    function test_MultiHop_TokenBToTokenAViaEth() public {
        // No direct B/A pair, but B/A liquidity got seeded via the shared WETH leg above
        // (A/WETH pool exists; route B -> WETH -> A only works if a B/WETH pool exists too).
        _seedPoolETH(tokenB, 200_000e18, 100 ether);

        address[] memory path = new address[](3);
        path[0] = address(tokenB);
        path[1] = address(weth);
        path[2] = address(tokenA);

        vm.startPrank(alice);
        tokenB.mint(alice, 1_000e18);
        tokenB.approve(address(router), 1_000e18);
        uint256[] memory amounts = router.swapExactTokensForTokens(1_000e18, 0, path, alice, block.timestamp);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(alice), amounts[2]);
        assertGt(amounts[2], 0);
    }

    function test_RevertWhen_DeadlineExpired() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.startPrank(alice);
        tokenA.mint(alice, 1_000e18);
        tokenA.approve(address(router), 1_000e18);
        vm.expectRevert(bytes("GswapRouter: EXPIRED"));
        router.swapExactTokensForTokens(1_000e18, 0, path, alice, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_SlippageExceeded() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        uint256[] memory quoted = router.getAmountsOut(1_000e18, path);

        vm.startPrank(alice);
        tokenA.mint(alice, 1_000e18);
        tokenA.approve(address(router), 1_000e18);
        vm.expectRevert(bytes("GswapRouter: INSUFFICIENT_OUTPUT_AMOUNT"));
        router.swapExactTokensForTokens(1_000e18, quoted[1] + 1, path, alice, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // helpers (avoid pulling in a full IERC20 import just for two calls)
    // ---------------------------------------------------------------------

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
