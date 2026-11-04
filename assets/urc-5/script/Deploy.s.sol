// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {VenueGatedToken} from "../src/VenueGatedToken.sol";

contract Deploy is Script {
    address constant BLOCKED = address(0xB10C);
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        address pm = deployCode("PoolManager.sol:PoolManager", abi.encode(deployer));
        VenueGatedToken token = new VenueGatedToken(pm, BLOCKED);
        console.log("PoolManager deployed at:", pm);
        console.log("VenueGatedToken deployed at:", address(token));
        vm.stopBroadcast();
    }
}
