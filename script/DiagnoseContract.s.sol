// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/GameDataReceiver.sol";
import "quex-v1-interfaces/interfaces/oracles/IRequestOraclePool.sol";

/**
 * @title DiagnoseContractScript
 * @dev Script to diagnose issues with the GameDataReceiver contract
 */
contract DiagnoseContractScript is Script {
    function run() external {
        vm.createSelectFork("arbitrum-sepolia");

        // Get parameters from environment
        uint256 privateKey = vm.envUint("SECRET");
        address payable contractAddress = payable(vm.envAddress("CONTRACT_ADDRESS"));
        
        // Log information about the contract
        console.log("Diagnosing GameDataReceiver");
        console.log("Contract address:", contractAddress);
        console.log("Sender address:", vm.addr(privateKey));

        // Start broadcast
        vm.startBroadcast(privateKey);
        
        // Get oracle pool address
        GameDataReceiver game = GameDataReceiver(contractAddress);
        address oraclePoolAddress = game.getOraclePool();
        console.log("Oracle Pool address:", oraclePoolAddress);
        
        // Simply log the oracle pool address for now
        console.log("Attempting to use Oracle Pool at address:", oraclePoolAddress);
        
        // Check quexCore address
        address quexCoreAddress = game.quexCore();
        console.log("Quex Core address:", quexCoreAddress);
        
        // Try adding a simplified HTTP request to diagnose the issue
        try IRequestOraclePool(oraclePoolAddress).addRequest(
            HTTPRequest({
                method: RequestMethod.Get,
                host: "example.com",
                path: "/",
                headers: new RequestHeader[](0),
                parameters: new QueryParameter[](0),
                body: ""
            })
        ) returns (bytes32 requestId) {
            console.log("Basic HTTP request added successfully, ID:", vm.toString(requestId));
        } catch Error(string memory reason) {
            console.log("Error adding HTTP request:", reason);
        } catch (bytes memory) {
            console.log("Unknown error adding HTTP request");
        }
        
        vm.stopBroadcast();
    }
}
