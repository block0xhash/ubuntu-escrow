// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {WETH9} from "../src/gswap/WETH9.sol";
import {GswapFactory} from "../src/gswap/GswapFactory.sol";
import {GswapRouter02} from "../src/gswap/GswapRouter02.sol";

/// @dev Deploys the GSWAP core: WETH9, GswapFactory (feeToSetter = deployer, feeTo left
/// unset so the protocol fee starts off), GswapRouter02 wired to both. Run against GIWA
/// Sepolia the same way DeployEscrow.s.sol runs - see contracts/README.md.
contract DeployGswap is Script {
    function run() external returns (WETH9 weth, GswapFactory factory, GswapRouter02 router) {
        uint256 deployerPrivateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        weth = new WETH9();
        factory = new GswapFactory(deployer);
        router = new GswapRouter02(address(factory), address(weth));

        vm.stopBroadcast();

        console.log("WETH9 deployed to:", address(weth));
        console.log("GswapFactory deployed to:", address(factory));
        console.log("GswapRouter02 deployed to:", address(router));
        console.log("feeToSetter (deployer):", deployer);
    }
}
