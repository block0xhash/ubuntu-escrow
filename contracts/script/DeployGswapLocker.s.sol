// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {GswapLocker} from "../src/gswap/GswapLocker.sol";

/// @dev Deploys GswapLocker - a permissionless, non-custodial time-lock usable for any
/// ERC20 (LP tokens included). No constructor args: the contract has no admin surface to
/// wire up. Run against GIWA Sepolia the same way DeployGswap.s.sol runs - see
/// contracts/README.md.
contract DeployGswapLocker is Script {
    function run() external returns (GswapLocker locker) {
        uint256 deployerPrivateKey = vm.envUint("TEST_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        locker = new GswapLocker();

        vm.stopBroadcast();

        console.log("GswapLocker deployed to:", address(locker));
        console.log("deployer:", deployer);
    }
}
