// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {WETH9} from "../../../src/gswap/WETH9.sol";
import {GswapFactory} from "../../../src/gswap/GswapFactory.sol";
import {GswapRouter02} from "../../../src/gswap/GswapRouter02.sol";
import {TestERC20} from "../mocks/TestERC20.sol";

abstract contract GswapTestBase is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeCollector = makeAddr("feeCollector");

    WETH9 internal weth;
    GswapFactory internal factory;
    GswapRouter02 internal router;

    TestERC20 internal tokenA;
    TestERC20 internal tokenB;

    uint256 internal constant INITIAL_SUPPLY = 10_000_000e18;

    function setUp() public virtual {
        vm.startPrank(owner);
        weth = new WETH9();
        factory = new GswapFactory(owner);
        router = new GswapRouter02(address(factory), address(weth));

        tokenA = new TestERC20("Token A", "TKA", INITIAL_SUPPLY);
        tokenB = new TestERC20("Token B", "TKB", INITIAL_SUPPLY);
        vm.stopPrank();

        deal(owner, 1_000 ether);
        deal(alice, 1_000 ether);
        deal(bob, 1_000 ether);
    }

    function _seedPool(TestERC20 t0, TestERC20 t1, uint256 amount0, uint256 amount1) internal {
        vm.startPrank(owner);
        t0.approve(address(router), amount0);
        t1.approve(address(router), amount1);
        router.addLiquidity(address(t0), address(t1), amount0, amount1, 0, 0, owner, block.timestamp);
        vm.stopPrank();
    }

    function _seedPoolETH(TestERC20 t, uint256 amountToken, uint256 amountEth) internal {
        vm.startPrank(owner);
        t.approve(address(router), amountToken);
        router.addLiquidityETH{value: amountEth}(address(t), amountToken, 0, 0, owner, block.timestamp);
        vm.stopPrank();
    }
}
