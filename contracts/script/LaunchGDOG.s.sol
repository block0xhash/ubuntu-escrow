// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {GDOGToken} from "../src/GDOGToken.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";

/// @dev Seeds the opening GDOG/WETH pool and flips trading on, in that order, in the
/// same broadcast - non-exempt transfers revert until enableTrading() is called
/// regardless of whether the pool already holds liquidity, so there's no window where
/// a bot can trade against the pool before the owner intends it to be live. This is the
/// one-way step: once enableTrading() lands, the 20%->5% anti-snipe decay clock starts
/// and there's no going back to "not launched."
contract LaunchGDOG is Script {
    uint256 internal constant INITIAL_LP_GDOG = 200_000_000e18; // 20% of supply
    uint256 internal constant INITIAL_LP_ETH = 10 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("TEST_PRIVATE_KEY");
        address router = vm.envAddress("GSWAP_ROUTER_ADDRESS");
        address gdogToken = vm.envAddress("GDOG_TOKEN_ADDRESS");
        address lpLockRecipient = vm.envAddress("GDOG_LP_LOCK_WALLET");

        GDOGToken token = GDOGToken(payable(gdogToken));

        vm.startBroadcast(deployerPrivateKey);

        token.approve(router, INITIAL_LP_GDOG);
        IUniswapV2Router02(router).addLiquidityETH{value: INITIAL_LP_ETH}(
            gdogToken, INITIAL_LP_GDOG, INITIAL_LP_GDOG, INITIAL_LP_ETH, lpLockRecipient, block.timestamp + 600
        );
        token.enableTrading();

        vm.stopBroadcast();

        console.log("Seeded pool with GDOG:", INITIAL_LP_GDOG);
        console.log("Seeded pool with ETH:", INITIAL_LP_ETH);
        console.log("LP tokens sent to:", lpLockRecipient);
        console.log("Trading ENABLED. Launch block:", block.number);
        console.log("Implied opening price: 1 ETH =", INITIAL_LP_GDOG / INITIAL_LP_ETH, "GDOG");
    }
}
