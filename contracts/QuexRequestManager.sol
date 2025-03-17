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