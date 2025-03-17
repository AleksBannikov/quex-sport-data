# Overview

Quex implements the unified protocol of TEE-based data transfer to the blockchain. Currently, Quex supports EVM-compatible
chains, and its TEE backbone is based on Intel TDX technology providing secure, fast, reliable and scalable environment for
arbitrary logic execution and verification.

Intel TDX allows one to create hardware-isolated virtual machines (Trust Domains, TDs), which can be verifiably protected
from intervention both from host and VM creator. The authenticity of the TD output can be verified by leveraging remote
attestation protocols, resulting in the output data being signed with a key, with
+ Private key being bound to the particular Trust Domain on a particular CPU
+ Public key effectively certified with chain of trust rooting in Intel SGX Root of Trust CA
+ Protected from reading by any party including the TD creator, and the hardware owner

TD itself can perform any actions an ordinary VM can. For example, if the network interface is present, the TD can issue
the HTTP requests to external resources via TLS, verify the TLS certificates and post-process the data. Or, it can
contain the software running as a light node in a blockchain, capturing events from the chain. Or, it can perform some
heavy data manipulation, such as running LLM, which is prohibitively computation-intense for the on-chain execution (or
even on-chain verification of the corresponding ZK proofs).

In all these cases, the result of the TD execution for Quex is the output data structure, conveniently packed for the
on-chain usage and signed with a unique key known solely by TD itself. 

The public counter-part of the key is written on the blockchain once per TD together with all the necessary information
regarding the TD (including hashed measurements of the memory layout, firmware, kernel image, initramfs, certificate
chain, CPU information). This public key is later used for the on-chain signature verification of the data received from
the TD. We call these TDs **Oracles**.

Any oracle can perform a prescribed set of **actions**. For example, querying and external REST endpoint and
post-processing the result is an action. An oracle receives **command** for an action, executes it and returns the signed
result.

To provide flexibility and fault tolerance, the oracles are united in **Oracle Pools**, normally by the set of actions
they can perform. When the end user needs some data, they address the command to the Oracle Pool. Any oracle from the
pool can execute the command, and the signed result is shipped to the chain. Quex Core on-chain logic verifies the
signature, checks the permissions of the responding oracle, and delivers the result to the customer-defined receiving
smart contract.

For common scenarios the action ID, the oracle pool ID, and the receiver address are reused multiple times. To
simplify the usage and reduce the fees in the long run, Quex uses **data flows**. A data flow is a combination of
recipient contract address, recipient contract callback, callback gas limit, oracle pool address, and ID of the action to be
performed by the oracle. Once created, the data flow is stored on-chain, and the subsequent requests to the oracle pools
are done solely by flow ID without any extra data.


# Contract addresses

## Arbitrum Sepolia

| Contract | Address | Notes |
|----------|---------|-------|
| Quex Core | `0xD8a37e96117816D43949e72B90F73061A868b387` | |
| Request Oracle Pool | `0x957E16D5bfa78799d79b86bBb84b3Ca34D986439` | TD pubkey: `0xd54a40ed58733b4aa39fd819b51656ab0812c825280216580ba0fd0ffbfd655074d63410e510885ec7966bfa85f5ba76f9641380ce3d8b7cc6ac2bffbc1f7fd6` |


# Getting started with Quex

## Project overview

In this tutorial we are creating a DApp on Arbitrum Sepolia, which consumes the data from Binance public API. To see the
basic capabilities, we are also going to use the post-processing of the data on the Quex Data Oracle Side making a
simple script (or filter in `jq` terms) for this purpose, and illustrate the non-trivial return structure.

Suppose the DApp collects the order books for BTC/USDT pair for its logic. It needs the following data from Binance:
+ The sequential number of the update to keep track of the ordering (Binance returns it as `lastUpdateId`)
+ Five best bids 
+ Five best asks

Both bid and ask are required to be tuples of integer numbers (price, quantity). The precision is required to be 8th digit
after decimal point. That is, the prices are to be multiplied by 100,000,000 and returned as `uint256`.

## Design the data structures

In line with the problem statement, our contract will work with the following data structures:
```solidity
struct Order {
    uint256 price;
    uint256 quantity;
}

struct OrderBook {
    uint256 lastUpdateId;
    Order[5] bids;
    Order[5] asks;
}
```

## Deploy receiving contract

Here is an example of a simple contract keeping track of the last created request and storing the response data.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Import IQuexActionRegistry interface and DataItem structure
import "https://github.com/quex-tech/quex-v1-interfaces/blob/fad2ceb5bff350b1eece52bdb74a2e01984f333e/interfaces/core/IQuexActionRegistry.sol";
import "@openzeppelin/contracts@4.5.0/access/Ownable.sol";

address constant QUEX_CORE = 0xD8a37e96117816D43949e72B90F73061A868b387;
IQuexActionRegistry constant quexCore = IQuexActionRegistry(QUEX_CORE);

struct Order {
    uint256 price;
    uint256 quantity;
}

struct OrderBook {
    uint256 lastUpdateId;
    Order[5] bids;
    Order[5] asks;
}

contract C is Ownable {
    uint256 requestId;
    OrderBook[] orderBooks;

    // We will track the requests performed by the unique request Id assigned by Quex
    // Only keep the latest request Id
    function request(uint256 flowId) public payable onlyOwner returns(uint256) {
        requestId = quexCore.createRequest{value:msg.value}(flowId);
        return requestId;
    }

    // On request() call this contract may receive the change from Quex Core.
    // Therefore, receive() method must be implemented
    receive() external payable {
        payable(owner()).call{value: msg.value}("");
    }

    // Callback handling the data processing logic
    function processResponse(uint256 receivedRequestId, DataItem memory response, IdType idType) external {
        // Verify that the sender is indeed Quex
        require(msg.sender == QUEX_CORE, "Only Quex Proxy can push data");
        // Verify that the request was initiated on-chain, rather than off-chain
        require(idType == IdType.RequestId, "Return type mismatch");
        // Verify that the response corresponds to our request
        require(receivedRequestId == requestId, "Unknown request ID");
        // Use the data. In this case we just store them
        orderBooks.push(abi.decode(response.value, (OrderBook)));
        return;
    }

    // Simple view function to see the results
    function getOrderBooks() external view returns (OrderBook[] memory) {
        return orderBooks;
    }

    // Another convenience view
    function getLastBid() external view returns (Order memory) {
        require(orderBooks.length >= 1, "No order books recorded");
        return orderBooks[orderBooks.length - 1].bids[0];
    }
}
```

As we are passing the arrays of nested structures, we need to compile the contract with the intermediate representation.
For example, if you are using [Remix IDE](https://remix.ethereum.org/), go to compiler settings, enable `Use Configuration File` 
in the `Advanced configurations`, and add `"viaIR": true` to your `compiler_config.json`:
```
{
	"language": "Solidity",
	"settings": {
		"viaIR": true,
        ...
	}
}
```

## Register action

According to the Quex architecture, the two things need to be done for data to be shipped. First, get the Action Id from
the oracle pool. In our case, the pool is the Quex Request Pool. The action must consist in performing HTTPS request to
Binance open API. Since this action is quite specific, the pool does not know it in advance. So we need to register this action
on the pool contract and get its id. If you are interested in the specifics of this process, consult the [Request Pool
Description](../https_pool/https_pool.md). In this tutorial we use the helper tool to create both action and flow
simultaneously, so let us go through the idea behind the flow creation first.

## Create flow

After the action id is known, it is time to define the route of data delivery. That is, to tell Quex Core what oracle
pool is the data supplier, what action is expected to be performed by it for the particular demand, what is the address
of the data consumer (including callback selector), and what gas consumption to expect from the callback (for relayer
reimbursement). As a result, we will get flow id which can be used for making requests and pushing the data without
passing the specific details every time. For the structures involved, please consult [Flow Creation](flow_creation.md).

To save time on these contract interactions, we will use the [Flow Creation
Tool](https://github.com/quex-tech/quex-v1-interfaces/tree/master/tools/create_flow). So, let us pass to this part

## Use flow creation script

### Configure settings
First, edit `config.json`. Compare the addresses of oracle pool and Quex Core with the ones you can find
[here](../general/addresses). Verify that `rpc_url` indeed points to Arbitrum Sepolia RPC. We can see from Remix IDE
that gas limit of 700k should be more than enough for `processResponse` call. The value of `td_pubkey` can be found
either in our Core Contract (see [`ITrustDomainRegistry`](../provider/td_registration), `REPORT_DATA` field of the TD
Quote), or on [addresses](../general/addresses) page. In case your request will not have private data, the `td_pubkey`
does not matter.

Make sure that `consumer` points to your contract, and the callback selector points to your method. If you use Remix
IDE, you can find the selectors in `Solidity Compiler->Compilation Details->Function Hashes`.

### Configure request

Now, we edit `request.json`. It defines the structure that will be passed to `addAction` call. The `request` field has
the general structure of HTTP request that will be performed by the oracle. However, there is also similarly looking
`patch` field. This field contains the private data which will be added to the request inside the TD. The TD accepts it
in encrypted form. Why is it in plaintext here then? The flow creation script encrypts it prior to sending using the
`td_pubkey` previously specified in the config. The `pathSuffix` is concatenated to the path in the `request`, the
headers and parameters are added to those of `request`, the body in `patch`. In case the body in `patch` is non-empty,
it will replace the `body` from the `request`.

The query we are tailoring accesses the host `www.binance.com`, path `/api/v3/depth`, has header `Content-Type:
application/json`, and parameters `limit=5` and `symbol=BTCUSDT`. If one tries this query, the response from Binance API
is like
```
{
  "lastUpdateId": 62019703469,
  "bids": [
    [
      "86319.98000000",
      "2.90207000"
    ],
  ...
  ],
  "asks": [
    [
      "86319.99000000",
      "0.58125000"
    ],
  ...
  ]
}
```
Now, we need to let the oracle know how to convert this JSON file to solidity structs used by our contract. To do so,
first define `responseSchema` as Solidity ABI schema for the `OrderBook` structure. Namely,
`(uint256,(uint256,uint256)[5],(uint256,uint256)[5])`.  Now we need to instruct the oracle to post-process response in a
mixed-type array which can be cast to this type. Quex Request Oracle Pool uses a subset of [jq](https://jqlang.org)
language for JSON post-processing. Jq programs are also called filters. We start building the filter step by step.
1. To cast a number from string to desired format, `tonumber*100000000 | floor` can be used.
2. Now, the filter `.bids[0] | map(tonumber*100000000 | floor)` would yield the first bid converted to the
right format
3. To convert all the bids to the necessary format, apply this map as nested: `.bids | map(map(tonumber*100000000 | floor))`
4. To reuse this filter for asks, process bids and asks as an array:
`[.bids, .asks] | map(map(map(tonumber*100000000 | floor)))`. Now we have two arrays adhering to the encoding.
5. Finally, prepend it with the value of `lastUpdateId`:
`[.lastUpdateId] + ([.bids, .asks] | map(map(map(tonumber*100000000|floor))))`

Combining it all together, the `request.json` file may now look as follows:
```json
{
    "request": {
        "method": "GET",
        "host": "www.binance.com",
        "path": "/api/v3/depth",
        "headers": [
            {
                "key": "Content-Type",
                "value": "application/json"
            }
        ],
        "body": "",
        "parameters": [
            {
                "key": "limit",
                "value": "5"
            },
            {
                "key": "symbol",
                "value": "BTCUSDT"
            }
        ]
    },
    "jqFilter": "[.lastUpdateId]+([.bids,.asks]|map(map(map(tonumber*100000000|floor))))",
    "responseSchema": "(uint256,(uint256,uint256)[5],(uint256,uint256)[5])",
}
```

Note that we did not include any patch as we do not need the private data in this particular case.

### Run the flow creation script

In order to initiate the transactions, the script needs access to the secret key. It is easiest to pass it as an
environment variable. However, you can also add it to `.env` or to `config.json` (see readme for the script)
```bash
SECRET_KEY=deadbeef... python create_flow.py config.json
```

The script will output the id of registered action; flow id, the fee per request in native coins, and the amount of gas
to be covered per request.

## Estimate fee

In our case, the tool has already shown the fee values (constituent in native currency and another constituent in gas). 
However, if we needed to access them from other project, we
could use `getRequestFee(uint256 flowId)` method of the Quex Core which returns this tuple. The value which must be
attached to the transaction is `nativeFee + gasPrice*gas`. Suppose, the call returned `30000000000000` Wei as
`nativeFee` and `810000` as gas. Suppose also that gas price is 0.1 GWei That means, the request creating transaction
must have at least `110000` GWei in value. It is safe to round this value up, as Quex Core returns the change.

## Send request

Once the value is estimated, the request can be created by calling `request` function on our contract with the value
taken from the first step. This transaction submits the on-chain request that is captured by the pool relayer, and
transferred to the oracle in the pool. After the oracle completes the task, the post-processed data are relayed to Quex
Core contract. Quex Core verifies the authority of the signing Trust Domain for this particular action, checks the
signature, and sends the data to our callback.

## Check the result

Check out your view functions to see that order books are indeed delivered.

{
    "chain": {
        "rpc_url": "https://sepolia-rollup.arbitrum.io/rpc"
    },
    "oracle_pool": {
        "address": "0x957E16D5bfa78799d79b86bBb84b3Ca34D986439",
        "abi": "RequestOraclePoolABI.json"
    },
    "quex_core": {
        "address": "0xD8a37e96117816D43949e72B90F73061A868b387",
        "abi": "QuexFlowRegistryABI.json"
    },
    "request_file": "request.json",
    "gas_limit": 700000,
    "td_pubkey": "0xd54a40ed58733b4aa39fd819b51656ab0812c825280216580ba0fd0ffbfd655074d63410e510885ec7966bfa85f5ba76f9641380ce3d8b7cc6ac2bffbc1f7fd6",
    "consumer": "0x39d28D1eB9e9429C91553e447e9C73E154B17005",
    "callback": "0x8f0b0698"
}

{
    "request": {
        "method": "GET",
        "host": "www.binance.com",
        "path": "/api",
        "headers": [],
        "body": "",
        "parameters": [
            {
                "key": "limit",
                "value": "5"
            }
        ]
    },
    "jqFilter": "[.lastUpdateId]+([.bids, .asks] | map(map(map(tonumber*100000000|floor))))",
    "responseSchema": "(uint256,(uint256,uint256)[5],(uint256,uint256)[5])",
    "patch": {
        "pathSuffix": "/v3/depth",
        "headers": [
            {
                "key": "Content-Type",
                "value": "application/json"
            }
        ],
        "parameters": [
            {
                "key": "symbol",
                "value": "BTCUSDT"
            }
        ],
        "body": ""
    }
}


#!/usr/bin/env python
import json
import os
import sys
from dotenv import load_dotenv, find_dotenv
from hexbytes import HexBytes

from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware, SignAndSendRawMiddlewareBuilder

from Crypto.Cipher import AES
from Crypto.Hash import SHA256, keccak
from Crypto.Protocol.KDF import HKDF
from ecdsa import SECP256k1, SigningKey, VerifyingKey
from ecdsa.ellipticcurve import Point
from Crypto.Random import get_random_bytes

action_topic = HexBytes('0x6ea08420309a5e903e7ff3f87843a579a9ceeed7c42dea42b08ba966da56ee01')
flow_topic = HexBytes('0xab4c08448aca89f38b8d830858d16c0d9b674b0b1a1154412c4a2b79778ef5d6')

http_methods = {
   "GET"    : 0,
   "POST"   : 1,
   "PUT"    : 2,
   "PATCH"  : 3,
   "DELETE" : 4,
   "OPTIONS": 5,
   "TRACE"  : 6
}

empty_patch = {
        "pathSuffix" : b'',
        "headers": [],
        "parameters": [],
        "body": b'',
        "tdAddress": b'\x00'*20
        }

def pk_to_address(pk_bytes):
    h = keccak.new(digest_bits=256, data=pk_bytes)
    return h.digest()[-20:]

def encrypt(plaintext, pk):
    nonce = get_random_bytes(16)
    r = int.from_bytes(get_random_bytes(32),'little')
    ephemeral_priv = SigningKey.from_secret_exponent(r, curve=SECP256k1)
    shared_point = pk * r
    ephemeral = ephemeral_priv.verifying_key.pubkey.point
    symm_key = HKDF(b'\x04' + ephemeral.to_bytes() + b'\x04' + shared_point.to_bytes(), 32, salt=None, hashmod=SHA256)
    cipher = AES.new(symm_key, AES.MODE_GCM, nonce=nonce)
    ciphertext, tag = cipher.encrypt_and_digest(plaintext)
    return ephemeral.to_bytes() + nonce + tag + ciphertext

def encrypt_pairs(pairs, encr_fun):
    return [{"key": x["key"], "ciphertext": encr_fun(x["value"])}  for x in pairs]

def init_web3(config):
    w3 = Web3(Web3.HTTPProvider(config["chain"]["rpc_url"]))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    account: LocalAccount = Account.from_key(config["chain"]["secret_key"])
    w3.middleware_onion.add(SignAndSendRawMiddlewareBuilder.build(account))

    w3.eth.default_account = account.address

    return w3


def init_contract(contract_config, w3):
    with open(contract_config["abi"], 'r') as f:
        abi = json.load(f)
    return w3.eth.contract(address=contract_config["address"], abi=abi)

def create_action(w3, contract, action):
    tx_hash = contract.functions.addAction(action).transact()
    tx_receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    return [x["data"] for x in tx_receipt["logs"] if action_topic in x["topics"]][0]

def create_flow(w3, contract, flow):
    tx_hash = contract.functions.createFlow(flow).transact()
    tx_receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    return [x["data"] for x in tx_receipt["logs"] if flow_topic in x["topics"]][0]

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: create_flow <path_to_config_json>")
        sys.exit(1)

    load_dotenv(find_dotenv())
    with open(sys.argv[1], "r") as f:
        config = json.loads(f.read())

    with open(config["request_file"], 'r') as f:
        request = json.load(f)

    if "secret_key" not in config["chain"]:
        config["chain"]["secret_key"] = os.environ.get("SECRET_KEY")

    pk_bytes = bytes.fromhex(config['td_pubkey'][2:])
    pk = Point.from_bytes(SECP256k1.curve, pk_bytes)

    w3 = init_web3(config)

    core_contract = init_contract(config["quex_core"], w3)
    pool_contract = init_contract(config["oracle_pool"], w3)

    request["request"]["method"] = http_methods[request["request"]["method"].upper()]

    encr = lambda x: encrypt(x.encode(), pk) if x != "" else b''

    if "patch" in request:
        p = request["patch"]
        patch = { x : encr(p[x]) for x in ["body", "pathSuffix"] } | \
                { x : encrypt_pairs(p[x], encr) for x in ["headers", "parameters"] } | \
                {"tdAddress": pk_to_address(pk_bytes) }
    else:
        patch = empty_patch
    request = {
            "patch" : patch\
    } | {x : request[x] for x in ["request", "jqFilter", "responseSchema"]}
    request["request"]["body"] = request["request"]["body"].encode()

    action_id = create_action(w3, pool_contract, request)
    print("action_id:    0x" + action_id.hex())

    flow = {
            "gasLimit": config["gas_limit"],
            "actionId": int.from_bytes(action_id, 'big'),
            "pool" : pool_contract.address,
            "consumer" : config["consumer"],
            "callback" : config["callback"]
            }

    flow_id = create_flow(w3, core_contract, flow)

    print("flow_id:      0x" + flow_id.hex())

    native_fee, gas = core_contract.functions.getRequestFee(int.from_bytes(flow_id, 'big')).call()

    print(f"Native fee:   {native_fee}")
    print(f"Gas to cover: {gas}")


# Data consumer callback

The callback for data consuming contract must have the following type signature (the method name can be arbitrary)
```solidity
function processResponse(uint256 receivedRequestId, DataItem memory response, IdType idType) external;
```

Here `receivedRequestId` is either id of the previously created request (in case of on-chain initiation), or id of the
data flow (in case of off-chain initiation). These two cases can be distinguished by looking at the `idType`. `response`
contains the data from the oracle. As a data consumer, upon the data receiving, one must ensure that
+ The method was called by the Quex Core contract
+ `idType` has the expected value
+ `receivedRequestId` has the expected value

The optional checks include
+ Verify that `error` code in `response` is zero (depending on the particular oracle pool capabilities)
+ Verify that the `timestamp` in the `response` is within tolerance bound (depending on the oracle pool policies, data
  transfer mode, and business logic)


# Flow creation

The data flow corresponds to the route the specific action takes from the pool to the data consumer contract. In Quex,
the general flow structure is the following

```solidity
struct Flow {
    uint256 gasLimit;
    uint256 actionId;
    address pool;
    address consumer;
    bytes4 callback;
}
```

Here the `gasLimit` is the gas limit for the `callback` function on the consumer contract. Once created, the flow will
be used every time your contract needs to consume the data corresponding to the `actionId` from the oracle `pool`. Note
that for request-based processing, the `gasLimit` contributes to amount which must be attached to the subsequent
requests. All the data is verified by Quex Core prior to the delivery, and the `callback` on `consumer` contract is
invoked with the designated `gasLimit`.

The flow can be created on Quex Core with `createFlow(Flow memory flow)` call which returns `flowId` for later
reference. This id can also be recorded from the `FlowAdded(uint256 flowId)` event emitted at flow creation.

# Quex request oracle pool descriptive guide

## Pool actions

The actions of this pool represent the combination of the public part of the
request, its private encrypted part, post-processing filter and ABI schema for the post-processed result:

```solidity
struct RequestAction {
    HTTPRequest request;
    HTTPPrivatePatch patch;
    string responseSchema;
    string jqFilter;
}
```

The actions are normally added with `addAction(RequestAction memory requestAction)` call. This method returns the id of the
action recorded. However, if you have multiple actions with reusable constituents, you may choose adding it by parts via
`addActionByParts(bytes32 requestId, bytes32 patchId, bytes32 schemaId, bytes32 filterId)`. In order to register the
parts of the action and obtain their ids, use the methods
+ `addRequest(HTTPRequest memory request)`
+ `addPrivatePatch(HTTPPrivatePatch memory privatePatch)`
+ `addJqFilter(string memory jqFilter)`
+ `addResponseSchema(string memory responseSchema)`

## HTTPRequest

Below is the list of the structures needed to define an `HTTPRequest`
```solidity
enum RequestMethod {
    Get,
    Post,
    Put,
    Patch,
    Delete,
    Options,
    Trace
}

struct RequestHeader {
    string key;
    string value;
}

struct QueryParameter {
    string key;
    string value;
}

struct HTTPRequest {
    RequestMethod method;
    string host;
    string path;
    RequestHeader[] headers;
    QueryParameter[] parameters;
    bytes body;
}
```
These structures bear common HTTP semantics

## HTTPPrivatePatch

`HTTPPrivatePatch` is the structure used to hold the data encrypted per TD, such as API keys or security tokens.

```solidity
struct RequestHeaderPatch {
    string key;
    bytes ciphertext;
}

struct QueryParameterPatch {
    string key;
    bytes ciphertext;
}

struct HTTPPrivatePatch {
    bytes pathSuffix;
    RequestHeaderPatch[] headers;
    QueryParameterPatch[] parameters;
    bytes body;
    address tdAddress;
}
```
The byte field are encrypted for the TD using DHKE in combination with AES-GCM. The format of the ciphertexts is
```
ephemeral_key | nonce | tag | ciphertext
```

Here `ephemeral_key` is x-coordinate of the point followed by the y-coordinate of the point.

The symmetric key for the ciphertext is generated as 32-byte SHA256-HKDF of concatenation of ephemeral key and shared EC point.
Both elliptic curve points are encoded and uncompressed (prefixed with `0x04` byte).

## jqFilter

`jqFilter` is the string representing the filter in the language `jq` to be applied to the response prior to data return. Quex Request
Oracles support a subset of `jq`, which is described on the corresponding [page](jq_subset.md)

## responseSchema

`responseSchema` field contains a plaintext description of the ABI schema for the returned data. The data post-processed
with `jq` must represent the mixed-type array. This array is interpreted by the oracle as tuple to be encoded with
`responseSchema`

## Action IDs

Action Ids for Request Oracle Pool are computed as `keccak256` of the ABI-encoded `RequestAction`

# Supported filters

Quex Request Oracles support the subset of [jq](https://jqlang.github.io/jq/manual/) language for response post-processing. The supported operations are

+ `+`, `-`, `*`, `/`, `%`
+ Selecting field by key or index via `.` or `[]`
+ Array slicing `[n:m]`
+ Pipe `|`
+ Array construction `[]`
+ `map`
+ `floor`, `abs`, `round`, `sqrt`
+ `split`, `join`
+ `todate`, `fromdate`
+ `tonumber`




