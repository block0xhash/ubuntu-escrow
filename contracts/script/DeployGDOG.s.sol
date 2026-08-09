// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {GDOGToken} from "../src/GDOGToken.sol";
import {GDOGBuybackVault} from "../src/GDOGBuybackVault.sol";

/// @dev Deploys GDOGToken + GDOGBuybackVault against an already-deployed GSWAP router
/// (see DeployGswap.s.sol) and wires them together, resolving the circular constructor
/// dependency exactly as documented in GDOGToken's header: token first with a zero
/// vault address, then the vault, then setBuybackVault() before trading ever opens.
///
/// Deliberately stops short of adding initial liquidity or calling enableTrading() -
/// that requires deciding how much ETH to commit and at what implied price, which is a
/// launch decision for a human to make explicitly, not something to default in a script.
contract DeployGDOG is Script {
    uint256 internal constant TREASURY_SEED = 50_000_000e18; // 5% of supply, backs auto-liquidity

    function run() external returns (GDOGToken token, GDOGBuybackVault vault) {
        uint256 deployerPrivateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address router = vm.envAddress("GSWAP_ROUTER_ADDRESS");
        address marketingWallet = vm.envAddress("GDOG_MARKETING_WALLET");
        address agent = vm.envAddress("GDOG_AGENT_WALLET");
        address liquidityLockRecipient = vm.envAddress("GDOG_LP_LOCK_WALLET");

        vm.startBroadcast(deployerPrivateKey);

        token = new GDOGToken(router, marketingWallet, address(0), liquidityLockRecipient, deployer);
        vault = new GDOGBuybackVault(router, address(token), agent, deployer);
        token.setBuybackVault(address(vault));
        token.fundLiquidityTreasury(TREASURY_SEED);

        vm.stopBroadcast();

        console.log("GDOGToken deployed to:", address(token));
        console.log("GDOGBuybackVault deployed to:", address(vault));
        console.log("Owner (deployer):", deployer);
        console.log("Marketing wallet:", marketingWallet);
        console.log("Buyback agent:", agent);
        console.log("Liquidity lock recipient:", liquidityLockRecipient);
        console.log("Liquidity treasury seeded:", TREASURY_SEED);
        console.log("");
        console.log("Trading is NOT enabled yet. Next: add initial LP via the router and");
        console.log("call token.enableTrading() once you've decided the launch amounts.");
    }
}
