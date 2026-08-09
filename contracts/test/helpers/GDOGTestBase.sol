// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GDOGToken} from "../../src/GDOGToken.sol";
import {GDOGBuybackVault} from "../../src/GDOGBuybackVault.sol";
import {MockWETH, MockUniswapV2Factory, MockUniswapV2Router02} from "../mocks/MockUniswapV2.sol";

/// @dev Shared deploy + launch helper for the GDOG test suites. Deploys a real
/// (mock) constant-product AMM, wires token <-> vault around the circular
/// constructor dependency the way the roadmap's Phase 3 deploy script does, and
/// exposes a one-call `_launch()` that seeds liquidity and flips trading on.
abstract contract GDOGTestBase is Test {
    address internal owner = makeAddr("owner");
    address internal marketing = makeAddr("marketing");
    address internal lpLock = makeAddr("lpLock");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockWETH internal weth;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Router02 internal router;

    GDOGToken internal token;
    GDOGBuybackVault internal vault;

    uint256 internal constant INITIAL_LP_TOKENS = 200_000_000e18; // 20% of supply seeds the pool
    uint256 internal constant INITIAL_LP_ETH = 100 ether;
    uint256 internal constant TREASURY_SEED = 50_000_000e18; // 5% of supply backs auto-liquidity

    function setUp() public virtual {
        weth = new MockWETH();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(factory, weth);

        vm.startPrank(owner);
        token = new GDOGToken(address(router), marketing, address(0), lpLock, owner);
        vault = new GDOGBuybackVault(address(router), address(token), agent, owner);
        token.setBuybackVault(address(vault));
        token.fundLiquidityTreasury(TREASURY_SEED);
        vm.stopPrank();

        deal(owner, 10_000 ether);
    }

    /// @dev Seeds the pair with opening liquidity and flips tradingEnabled - both from
    /// `owner`, which is exempt from limits, exactly like the real launch script.
    function _launch() internal {
        vm.startPrank(owner);
        token.approve(address(router), INITIAL_LP_TOKENS);
        router.addLiquidityETH{value: INITIAL_LP_ETH}(
            address(token), INITIAL_LP_TOKENS, 0, 0, lpLock, block.timestamp
        );
        token.enableTrading();
        vm.stopPrank();
    }

    function _buy(address buyer, uint256 ethIn) internal {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(token);
        deal(buyer, ethIn);
        vm.prank(buyer);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, path, buyer, block.timestamp
        );
    }

    function _sell(address seller, uint256 tokenIn) internal {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(weth);
        vm.startPrank(seller);
        token.approve(address(router), tokenIn);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(tokenIn, 0, path, seller, block.timestamp);
        vm.stopPrank();
    }
}
