// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/GameDataReceiver.sol";

/**
 * @title DeployGameDataReceiverScript
 * @dev Script to deploy the GameDataReceiver contract to Arbitrum Sepolia
 */
contract Deploy is Script {
    // Quex contract addresses on Arbitrum Sepolia
    address private constant QUEX_CORE = 0xD8a37e96117816D43949e72B90F73061A868b387;
    address private constant ORACLE_POOL = 0x957E16D5bfa78799d79b86bBb84b3Ca34D986439;
    
    function run() external {
        // Setup network fork
        vm.createSelectFork("arbitrum-sepolia");

        // Get deployer credentials
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        
        // Log deployment information
        console.log("\n=== Deployment Information ===");
        console.log("Network: Arbitrum Sepolia");
        console.log("Deployer: %s", deployer);
        console.log("Quex Core: %s", QUEX_CORE);
        console.log("Oracle Pool: %s", ORACLE_POOL);
        
        // Deploy the contract
        vm.startBroadcast(privateKey);
        GameDataReceiver gameDataReceiver = new GameDataReceiver(QUEX_CORE, ORACLE_POOL);
        vm.stopBroadcast();
        
        // Log deployment results
        console.log("\n=== Deployment Successful ===");
        console.log("GameDataReceiver deployed at: %s", address(gameDataReceiver));
        
        console.log("\n=== Next Steps ===");
        console.log("1. Set the contract address in your environment:");
        console.log("   export CONTRACT_ADDRESS=%s", address(gameDataReceiver));
        console.log("2. Make a request to fetch game data:");
        console.log("   forge script script/Request.s.sol --broadcast");
    }
}
