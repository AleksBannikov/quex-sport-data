// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/GameDataReceiver.sol";

/**
 * @title SetFlowIdScript
 * @dev Script to set the flow ID on the deployed GameDataReceiver contract
 */
contract SetFlowId is Script {
    function run() external {
        // Setup network fork
        vm.createSelectFork("arbitrum-sepolia");

        // Get deployer credentials
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        
        // Get contract address from environment
        address payable contractAddress = payable(vm.envAddress("CONSUMER_ADDRESS"));
        
        // Get flow ID from environment
        uint256 flowId = vm.envUint("FLOW_ID");
        
        // Log operation information
        console.log("\n=== SetFlowId Operation ===");
        console.log("Network: Arbitrum Sepolia");
        console.log("Caller: %s", deployer);
        console.log("Contract: %s", contractAddress);
        console.log("Flow ID: %d (0x%x)", flowId, flowId);
        
        // Call setFlowId on the contract
        vm.startBroadcast(privateKey);
        GameDataReceiver gameReceiver = GameDataReceiver(contractAddress);
        gameReceiver.setFlowId(flowId);
        vm.stopBroadcast();
        
        // Verify flow ID was set
        uint256 setFlowId = gameReceiver.getFlowId();
        
        // Log results
        console.log("\n=== Operation Result ===");
        console.log("Flow ID successfully set: %s", setFlowId == flowId ? "Yes" : "No");
        console.log("Current Flow ID: %d", setFlowId);
        
        console.log("\n=== Next Steps ===");
        console.log("Make a request to fetch game data:");
        console.log("forge script script/Request.s.sol --broadcast");
    }
} 