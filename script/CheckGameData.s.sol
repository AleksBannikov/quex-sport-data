// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "../contracts/GameDataReceiver.sol";

/**
 * @title CheckGameDataScript
 * @dev Script to check game data stored in the GameDataReceiver contract
 */
contract CheckGameDataScript is Script {
    function run() external {
        vm.createSelectFork("arbitrum-sepolia");

        // Get parameters from environment
        uint256 privateKey = vm.envUint("SECRET");
        address payable contractAddress = payable(vm.envAddress("CONTRACT_ADDRESS"));
        
        // Log information
        console.log("=== Checking Soccer Game Data ===");
        console.log("Contract address: ", contractAddress);
        console.log("Requester address: ", vm.addr(privateKey));

        // Check game count
        GameDataReceiver game = GameDataReceiver(contractAddress);
        uint256 gameCount;
        
        try game.gameCount() returns (uint256 count) {
            gameCount = count;
            console.log("Total games processed: ", gameCount);
            
            if (gameCount == 0) {
                console.log("No games have been processed yet.");
                console.log("The oracle may still be processing the request or hasn't delivered data yet.");
                console.log("Try again in a few minutes.");
                return;
            }
            
            // Display game details for each game
            for (uint256 i = 0; i < gameCount; i++) {
                try game.games(i) returns (
                    uint256 gameId,
                    uint256 homeTeamId,
                    uint256 awayTeamId,
                    uint256 homeScore,
                    uint256 awayScore,
                    uint256 timestamp
                ) {
                    console.log("Game ", i, " Details:");
                    console.log("  Game ID: ", gameId);
                    console.log("  Home Team ID: ", homeTeamId);
                    console.log("  Away Team ID: ", awayTeamId);
                    console.log("  Score: "); // Split the score logging
                    console.log("    Home: ", homeScore);
                    console.log("    Away: ", awayScore);
                    console.log("  Timestamp: ", timestamp);
                    
                    // Get goals
                    try game.getGameGoals(i) returns (GameDataReceiver.Goal[] memory goals) {
                        console.log("  Goals scored: ", goals.length);
                        
                        for (uint256 j = 0; j < goals.length; j++) {
                            string memory teamType = goals[j].teamId == homeTeamId ? "Home" : "Away";
                            console.log("    Goal ", j+1);
                            console.log("      Minute: ", goals[j].minute);
                            console.log("      Extra Minute: ", goals[j].extraMinute);
                            console.log("      Team: ", teamType);
                        }
                    } catch {
                        console.log("    Could not retrieve goals for this game.");
                    }
                } catch {
                    console.log("Error retrieving details for game ", i);
                }
            }
        } catch {
            console.log("Error: Could not retrieve game count. The contract may not have received data yet.");
        }
    }
}