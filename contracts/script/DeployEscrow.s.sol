// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";

contract DeployEscrow is Script {
    function run() external returns (Escrow) {
        uint256 deployerPrivateKey = vm.envUint("TEST_PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        Escrow escrow = new Escrow(treasury);

        vm.stopBroadcast();

        console.log("Escrow deployed to:", address(escrow));
        console.log("Treasury configured as:", treasury);

        return escrow;
    }
}
