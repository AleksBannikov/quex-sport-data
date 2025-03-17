// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/GameDataReceiver.sol";

/**
 * @title CreateFlowScript
 * @dev Script to create a flow in the GameDataReceiver contract
 */
contract CreateFlowScript is Script {
    function run() external {
        vm.createSelectFork("arbitrum-sepolia");

        // Get parameters from environment
        uint256 privateKey = vm.envUint("SECRET");
        address payable contractAddress = payable(vm.envAddress("CONTRACT_ADDRESS"));
        
        // Log information about the request
        console.log("\n=== Creating Flow for Soccer Game Oracle ===\n");
        console.log("Contract address: %s", contractAddress);
        console.log("Sender address: %s", vm.addr(privateKey));

        // Start broadcast and create the flow
        vm.startBroadcast(privateKey);
        
        // Check if contract has a flow already
        try GameDataReceiver(contractAddress).getFlowId() returns (uint256 flowId) {
            if (flowId != 0) {
                console.log("\nFlow already exists with ID: %d", flowId);
                console.log("No need to create a new flow.\n");
                vm.stopBroadcast();
                return;
            }
        } catch {}
        
        // Attempt to create the flow
        console.log("\nAttempting to create a new flow...");
        
        try GameDataReceiver(contractAddress).createGameDataFlow("2024-02-26") {
            console.log("Flow created successfully!");
            
            // Get the flow ID
            try GameDataReceiver(contractAddress).getFlowId() returns (uint256 newFlowId) {
                console.log("New Flow ID: %d\n", newFlowId);
            } catch {
                console.log("Flow created but could not retrieve Flow ID.\n");
            }
        } catch Error(string memory reason) {
            console.log("Error creating flow: %s\n", reason);
        } catch (bytes memory err) {
            console.log("Unknown error creating flow. Raw error data:\n");
            console.logBytes(err);
        }
        
        vm.stopBroadcast();
    }
}
