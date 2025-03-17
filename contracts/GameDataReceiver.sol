// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./QuexRequestManager.sol";
import "quex-v1-interfaces/interfaces/oracles/IRequestOraclePool.sol";

/**
 * @title GameDataReceiver
 * @dev This contract receives soccer game data through the Quex oracle.
 * It fetches soccer match results from SportsData.io and stores them on-chain.
 */
contract GameDataReceiver is QuexRequestManager {
    // Constants
    uint256 private constant GAS_LIMIT = 700000;
    
    // Quex integration variables
    address private immutable _oraclePool;
    
    // Game data storage
    struct Goal {
        uint256 minute;
        uint256 extraMinute;
        uint256 teamId;
    }
    
    struct GameResult {
        uint256 gameId;
        uint256 homeTeamId;
        uint256 awayTeamId;
        uint256 homeScore;
        uint256 awayScore;
        Goal[] goals;
        uint256 timestamp;
    }
    
    mapping(uint256 => GameResult) public games;
    mapping(uint256 => bool) public processedGameIds;
    uint256 public gameCount;
    
    // Events
    event GameDataReceived(
        uint256 indexed gameId,
        uint256 homeTeamId,
        uint256 awayTeamId,
        uint256 homeScore,
        uint256 awayScore,
        uint256 timestamp
    );
    event RequestSent(uint256 requestId);
    event GoalScored(
        uint256 indexed gameId,
        uint256 minute,
        uint256 extraMinute,
        uint256 teamId
    );

    /**
     * @dev Initializes the contract with required addresses. Flow must be created post-deployment using create-flow.ts script.
     * @param quexCoreAddress Address of the Quex Flow Registry contract
     * @param oraclePoolAddress Address of the Request Oracle Pool contract
     */
    constructor(address quexCoreAddress, address oraclePoolAddress) QuexRequestManager(quexCoreAddress) {
        _oraclePool = oraclePoolAddress;
    }
    
    /**
     * @notice Override setFlowId with additional authorization checks
     * @param flowId The ID of the flow to use
     */
    function setFlowId(uint256 flowId) public override onlyOwner {
        // The onlyOwner modifier already checks if msg.sender is the contract owner
        // Since this function overrides the base one which also has onlyOwner,
        // we're already ensuring proper authorization
        super.setFlowId(flowId);
    }
    
    /**
     * @notice Sends a request to get game data
     * @return The request ID of the newly created request
     */
    function request() public payable onlyOwner returns (uint256) {
        require(_flowId != 0, "Flow ID is not set");
        _requestId = IQuexActionRegistry(quexCore).createRequest{value: msg.value}(_flowId);
        emit RequestSent(_requestId);
        return _requestId;
    }
    
    /**
     * @notice Processes the response from Quex and stores the game data
     * @param receivedRequestId The ID of the request being processed
     * @param response The response data from Quex
     */
    function processGameData(uint256 receivedRequestId, DataItem memory response, IdType idType) external verifyResponse(receivedRequestId, idType) {
        // Authorization handled by verifyResponse modifier
        
        // Decode the response data - it's already in the right type format
        (
            uint256 gameId,
            uint256 homeTeamId,
            uint256 awayTeamId,
            uint256 homeScore,
            uint256 awayScore,
            Goal[] memory goals
        ) = abi.decode(response.value, (uint256, uint256, uint256, uint256, uint256, Goal[]));
        
        // Only process each game once
        if (!processedGameIds[gameId]) {
            // Store the game result
            storeGameResult(gameId, homeTeamId, awayTeamId, homeScore, awayScore, goals);
            processedGameIds[gameId] = true;
        }
    }
    
    /**
     * @notice Stores a new game result
     * @param gameId ID of the game from the API
     * @param homeTeamId ID of the home team
     * @param awayTeamId ID of the away team
     * @param homeScore Score of the home team
     * @param awayScore Score of the away team
     * @param goals Array of goal data
     */
    function storeGameResult(
        uint256 gameId,
        uint256 homeTeamId,
        uint256 awayTeamId,
        uint256 homeScore,
        uint256 awayScore,
        Goal[] memory goals
    ) private {
        uint256 newGameId = gameCount++;
        
        // Create a new storage array for goals
        games[newGameId].gameId = gameId;
        games[newGameId].homeTeamId = homeTeamId;
        games[newGameId].awayTeamId = awayTeamId;
        games[newGameId].homeScore = homeScore;
        games[newGameId].awayScore = awayScore;
        games[newGameId].timestamp = block.timestamp;
        
        // Store each goal
        for (uint256 i = 0; i < goals.length; i++) {
            games[newGameId].goals.push(Goal({
                minute: goals[i].minute,
                extraMinute: goals[i].extraMinute,
                teamId: goals[i].teamId
            }));
            
            emit GoalScored(
                gameId,
                goals[i].minute,
                goals[i].extraMinute,
                goals[i].teamId
            );
        }
        
        emit GameDataReceived(
            gameId,
            homeTeamId,
            awayTeamId,
            homeScore,
            awayScore,
            block.timestamp
        );
    }
    
    /**
     * @notice Gets the result of a game
     * @param gameId The ID of the game to get the result for
     * @return The game result
     */
    function getGameResult(uint256 gameId) external view returns (GameResult memory) {
        require(gameId < gameCount, "Game does not exist");
        return games[gameId];
    }
    
    /**
     * @notice Gets the goals for a specific game
     * @param gameId The ID of the game
     * @return Array of goals for the game
     */
    function getGameGoals(uint256 gameId) external view returns (Goal[] memory) {
        require(gameId < gameCount, "Game does not exist");
        return games[gameId].goals;
    }
    
    /**
     * @notice Gets the address of the oracle pool being used
     * @return The address of the oracle pool
     */
    function getOraclePool() external view returns (address) {
        return _oraclePool;
    }
}
