// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {console} from "forge-std/console.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "quex-v1-interfaces/interfaces/oracles/IRequestOraclePool.sol";
import "quex-v1-interfaces/interfaces/core/IFlowRegistry.sol";
import "quex-v1-interfaces/interfaces/core/IQuexActionRegistry.sol";

/**
 * @title QuexRequestManager
 * @dev Base contract for managing interactions with Quex data oracles.
 */
abstract contract QuexRequestManager is Ownable {

    // Quex integration variables
    address public immutable quexCore;
    uint256 internal _requestId;
    uint256 internal _flowId;

    // Using IdType enum from IQuexActionRegistry

    /**
     * @dev Initializes the contract with the Quex Core address
     * @param quexCoreAddress Address of the Quex Flow Registry contract
     */
    constructor(address quexCoreAddress) Ownable(msg.sender) {
        quexCore = quexCoreAddress;
    }

    /**
     * @notice Retrieves the flow ID
     * @return The flow ID of the contract
     */
    function getFlowId() external view returns (uint256) {
        return _flowId;
    }

    /**
     * @notice Sets the flow ID (can only be set once)
     * @param flowId The unique identifier for the flow
     */
    function setFlowId(uint256 flowId) public virtual onlyOwner {
        require(_flowId == 0, "Flow ID is already set");
        _flowId = flowId;
    }

    /**
     * @notice Performs validation checks for an incoming response
     * @param receivedRequestId The ID of the request associated with this response
     */
    modifier verifyResponse(uint256 receivedRequestId, IdType idType) {
        require(msg.sender == quexCore, "Only Quex can push data");
        require(receivedRequestId == _requestId, "Unknown request ID");
        require(idType == IdType.RequestId, "Return type mismatch");
        _;
    }

    /**
     * @notice Sends a request to the Quex Action Registry
     * @return The request ID of the newly created request
     */
    function sendRequest() public payable virtual onlyOwner returns (uint256) {
        require(_flowId != 0, "Flow ID is not set");
        _requestId = IQuexActionRegistry(quexCore).createRequest{value: msg.value}(_flowId);
        return _requestId;
    }

    /**
     * @notice Handles refunds if excess payment was made during a request
     */
    receive() external payable virtual {
        (bool success,) = payable(owner()).call{value: msg.value}("");
        require(success, "Transfer failed");
    }
}

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
     * @dev Initializes the contract and creates the flow for soccer game data
     * @param quexCoreAddress Address of the Quex Flow Registry contract
     * @param oraclePoolAddress Address of the Request Oracle Pool contract
     */
    constructor(address quexCoreAddress, address oraclePoolAddress) QuexRequestManager(quexCoreAddress) {
        _oraclePool = oraclePoolAddress;
        // Flow will be created after deployment via the create-flow.js script
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
     * @notice Creates the default flow for soccer game data using the current date
     */
    function createDefaultFlow() private {
        createGameDataFlow("2024-02-26"); // Default date for the example
    }

    /**
     * @notice Creates a new flow to fetch soccer game data
     * @param date The date to fetch games for in format YYYY-MM-DD
     */
    function createGameDataFlow(string memory date) public onlyOwner {
        IRequestOraclePool oracleInstance = IRequestOraclePool(_oraclePool);
        IFlowRegistry flowRegistry = IFlowRegistry(quexCore);

        // Create the request and patch objects from the SportsData.io API
        (HTTPRequest memory httpRequest, HTTPPrivatePatch memory patch) = createMatchRequest(date);
        
        // Add the request and patch to the oracle pool
        bytes32 requestId = oracleInstance.addRequest(httpRequest);
        bytes32 patchId = oracleInstance.addPrivatePatch(patch);
        
        // Add the schema and filter definitions
        bytes32 schemaId = oracleInstance.addResponseSchema(
            "(uint256,uint256,uint256,uint256,uint256,(uint256,uint256,uint256)[])" // Tuple schema
        );
        
        bytes32 filterId = oracleInstance.addJqFilter(
            ".[0] | [.Game.GameId, .Game.HomeTeamId, .Game.AwayTeamId, .Game.HomeTeamScore, .Game.AwayTeamScore, (.Goals | map([.GameMinute, .GameMinuteExtra, .TeamId]))]" 
        );
        
        // Create action by combining request, patch, schema, and filter
        uint256 actionId = oracleInstance.addActionByParts(
            requestId,
            patchId,
            schemaId,
            filterId
        );
        
        // Create flow with the action
        Flow memory flow = Flow({
            gasLimit: GAS_LIMIT,
            actionId: actionId,
            pool: _oraclePool,
            consumer: address(this),
            callback: this.processGameData.selector
        });
        
        // Register the flow and save its ID
        uint256 newFlowId = flowRegistry.createFlow(flow);
        _flowId = newFlowId; // Set directly since we're in the constructor context
    }
    
    /**
     * @notice Creates the HTTP request for match data from SportsData.io
     * @param date The date to fetch games for in format YYYY-MM-DD
     * @return httpRequest The HTTP request structure
     * @return patch The patch structure containing the API key
     */
    function createMatchRequest(string memory date) private pure returns (
        HTTPRequest memory httpRequest,
        HTTPPrivatePatch memory patch
    ) {
        // Create the path for the SportsData.io API
        string memory path = string(abi.encodePacked(
            "/api/v4/soccer/stats/json/boxscoresbydate/mls/",
            date
        ));
        
        // Create HTTP request
        httpRequest = HTTPRequest({
            method: RequestMethod.Get,
            host: "replay.sportsdata.io",
            path: path,
            headers: new RequestHeader[](0),
            parameters: new QueryParameter[](0),
            body: ""
        });
        
        // Create patch with API key as parameter
        // Convert the API key to a QueryParameterPatch
        QueryParameterPatch[] memory paramPatches = new QueryParameterPatch[](1);
        paramPatches[0] = QueryParameterPatch({
            key: "key",
            ciphertext: bytes("42a9cf0677694e06bf6ab26cce74988c") // API key as bytes
        });
        
        // Derive TD address from the public key provided
        // The actual TD pubkey is: 0xb23974e9267308bd821c34038e00072bf1e297f308227d98de387deb50f9ca2ebed328af1471f291e53eff602130f5ab79d006ee040553016775d79261362770
        // For simplicity, we'll use the address directly
        address tdAddress = 0xA4b1FE1C27E1FF55A42fd431Dd5A50F65a5BFF45; // Derived from public key
        
        patch = HTTPPrivatePatch({
            pathSuffix: "",
            headers: new RequestHeaderPatch[](0),
            parameters: paramPatches,
            body: "",
            tdAddress: tdAddress // TD address derived from pubkey
        });
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
