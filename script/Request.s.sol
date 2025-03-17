// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/GameDataReceiver.sol";

/**
 * @title RequestScript
 * @dev Script to send a request to the GameDataReceiver contract
 */
contract RequestScript is Script {
    // Gas fee for oracle request
    uint256 private constant ORACLE_FEE = 5000000000000000; // 0.005 ETH

    function run() external {
        vm.createSelectFork("arbitrum-sepolia");

        // Get deployer credentials
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        
        // Get contract address from environment
        address payable contractAddress = payable(vm.envAddress("CONSUMER_ADDRESS"));
        
        // Log information about the request
        console.log("\n=== Sending Request to Soccer Game Oracle ===\n");
        console.log("Contract address: %s", contractAddress);
        console.log("Oracle fee: %d wei (%f ETH)", ORACLE_FEE, ORACLE_FEE / 1e18);
        console.log("Sender address: %s", deployer);

        // Check the flow ID first to ensure we have an active flow
        vm.startBroadcast(privateKey);
        
        try GameDataReceiver(contractAddress).getFlowId() returns (uint256 flowId) {
            if (flowId == 0) {
                console.log("\nError: No active flow found. Please create a flow first.\n");
                vm.stopBroadcast();
                return;
            }
            
            console.log("\nUsing flow ID: %d", flowId);
            
            // Send the request with the oracle fee
            try GameDataReceiver(contractAddress).request{value: ORACLE_FEE}() returns (uint256 requestId) {
                console.log("Request sent successfully!");
                console.log("Request ID: %d\n", requestId);
                console.log("The oracle will now fetch the data from SportsData.io");
                console.log("Check your contract for the game data in a few minutes.\n");
            } catch Error(string memory reason) {
                console.log("\nError sending request: %s\n", reason);
            } catch (bytes memory err) {
                console.log("\nUnknown error sending request. Raw error data:\n");
                console.logBytes(err);
            }
        } catch {
            console.log("\nError: Could not retrieve flow ID.\n");
        }
        
        vm.stopBroadcast();
    }
}
