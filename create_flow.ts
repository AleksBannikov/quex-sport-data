import { Web3 } from 'web3';
import { ec as EC } from 'elliptic';
import config from './config.ts';
import request from './request.json';
import QuexFlowRegistryABI from './QuexFlowRegistryABI.json';
import RequestOraclePoolABI from './RequestOraclePoolABI.json';

// Initialize secp256k1 elliptic curve
const secp256k1 = new EC('secp256k1');

// Constants for event topics
const actionTopic = '0x6ea08420309a5e903e7ff3f87843a579a9ceeed7c42dea42b08ba966da56ee01';
const flowTopic = '0xab4c08448aca89f38b8d830858d16c0d9b674b0b1a1154412c4a2b79778ef5d6';

// HTTP method mappings
const httpMethods: { [key: string]: number } = {
    "GET": 0,
    "POST": 1,
    "PUT": 2,
    "PATCH": 3,
    "DELETE": 4,
    "OPTIONS": 5,
    "TRACE": 6
};

// Default empty patch object
const emptyPatch = {
    pathSuffix: Buffer.alloc(0),
    headers: [],
    parameters: [],
    body: Buffer.alloc(0),
    tdAddress: '0x0000000000000000000000000000000000000000'
};

// Interfaces for configuration and request
interface Config {
    chain: {
        rpc_url: string;
    };
    quex_core: {
        abi: string;
        address: string;
    };
    oracle_pool: {
        abi: string;
        address: string;
    };
    td_pubkey: string;
    request_file: string;
    gas_limit: number;
    consumer: string;
    callback: string;
}

interface Patch {
    pathSuffix: Buffer;
    body: Buffer;
    headers: { key: string; ciphertext: Buffer }[];
    parameters: { key: string; ciphertext: Buffer }[]; // Adjust if parameters differ
    tdAddress: string;
}

interface Request {
    request: {
        method: string;
        body: string;
        // Add other properties as needed
    };
    jqFilter: string;
    responseSchema: string;
    patch?: {
        pathSuffix: string;
        headers: { key: string; value: string }[];
        parameters: { key: string; value: string }[];
        body: string;
    };
}

/**
 * Computes an Ethereum address from a public key by hashing it with keccak256 and taking the last 20 bytes.
 * @param pkBytes Public key bytes (65 bytes, uncompressed format)
 * @returns 20-byte address
 */
function pkToAddress(pkBytes: Buffer): string {
    const hash = Web3.utils.keccak256(pkBytes);
    return '0x' + hash.slice(2).slice(-40);
}

/**
 * Derives a symmetric key using HKDF from the shared secret.
 * @param ephemeral Ephemeral key pair
 * @param pk Recipient's public key
 * @returns 32-byte symmetric key
 */
function deriveSymmetricKey(ephemeral: EC.KeyPair, pk: EC.KeyPair): Buffer {
    const sharedPoint = pk.getPublic().mul(ephemeral.getPrivate());
    const ephemeralBytes = Buffer.from(ephemeral.getPublic().encode('hex', false), 'hex');
    const sharedBytes = Buffer.from(sharedPoint.encode('hex', false), 'hex');
    const master = Buffer.concat([Buffer.from([0x04]), ephemeralBytes, Buffer.from([0x04]), sharedBytes]);
    
    // Use Bun's native HMAC functionality
    const salt = Buffer.alloc(32, 0);
    const hasher = new Bun.CryptoHasher("sha256", salt);
    const prk = hasher.update(master).digest();
    
    const finalHasher = new Bun.CryptoHasher("sha256", prk);
    return Buffer.from(finalHasher.update(Buffer.from([0x01])).digest()).slice(0, 32);
}

/**
 * Encrypts plaintext using ECDSA to derive a shared secret and AES-GCM for encryption.
 * @param plaintext Data to encrypt
 * @param pk Recipient's public key (EC key object)
 * @returns Encrypted data (ephemeral pubkey + nonce + tag + ciphertext)
 */
async function encrypt(plaintext: Buffer, pk: EC.KeyPair): Promise<Buffer> {
    const ephemeral = secp256k1.genKeyPair();
    const symmKey = deriveSymmetricKey(ephemeral, pk);
    const nonce = crypto.getRandomValues(new Uint8Array(16));
    
    // Use Web Crypto API for AES-GCM encryption
    const encoder = new TextEncoder();
    const data = encoder.encode(plaintext.toString());
    
    const cryptoKey = await crypto.subtle.importKey(
        "raw",
        symmKey,
        { name: "AES-GCM" },
        false,
        ["encrypt"]
    );
    
    const encrypted = await crypto.subtle.encrypt(
        {
            name: "AES-GCM",
            iv: nonce
        },
        cryptoKey,
        data
    );
    
    const ciphertext = new Uint8Array(encrypted);
    const tag = ciphertext.slice(-16);
    const actualCiphertext = ciphertext.slice(0, -16);
    
    const ephemeralBytes = Buffer.from(ephemeral.getPublic().encode('hex', false), 'hex');
    return Buffer.concat([ephemeralBytes, Buffer.from(nonce), Buffer.from(tag), Buffer.from(actualCiphertext)]);
}

/**
 * Encrypts values in an array of key-value pairs.
 * @param pairs Array of key-value pairs
 * @param encrFun Encryption function
 * @returns Array of key-ciphertext pairs
 */
async function encryptPairs(pairs: { key: string, value: string }[], encrFun: (x: string) => Promise<Buffer>): Promise<{ key: string, ciphertext: Buffer }[]> {
    return Promise.all(pairs.map(async x => ({ key: x.key, ciphertext: await encrFun(x.value) })));
}

/**
 * Initializes Web3 instance with provider and account signing.
 * @param config Configuration object
 * @returns Web3 instance
 */
function initWeb3(config: Config): Web3 {
    const w3 = new Web3(config.chain.rpc_url);
    
    // Make sure the private key exists and is properly formatted
    let privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) {
        throw new Error("Missing private key in configuration");
    }
    
    // Ensure it has the 0x prefix which Web3.js expects
    if (!privateKey.startsWith('0x')) {
        privateKey = '0x' + privateKey;
    }
    
    try {
        const account = w3.eth.accounts.privateKeyToAccount(privateKey);
        w3.eth.accounts.wallet.add(account);
        w3.eth.defaultAccount = account.address;
        return w3;
    } catch (error) {
        throw new Error(`Failed to initialize Web3 with private key: ${(error as Error).message}`);
    }
}

/**
 * Prepares the request data, including encryption of patch fields if present.
 * @param config Configuration object
 * @param pk Recipient's public key
 * @returns Prepared request object
 */
async function prepareRequest(config: Config, pk: EC.KeyPair): Promise<any> {
    const encr = (x: string): Promise<Buffer> => x ? encrypt(Buffer.from(x, 'utf-8'), pk) : Promise.resolve(Buffer.alloc(0));
    let patch: Patch = {
        pathSuffix: Buffer.alloc(0),
        body: Buffer.alloc(0),
        headers: [] as { key: string; ciphertext: Buffer }[],
        parameters: [] as { key: string; ciphertext: Buffer }[],
        tdAddress: pkToAddress(Buffer.from(config.td_pubkey.slice(2), 'hex'))
    };
    if (request.patch) {
        patch = {
            pathSuffix: Buffer.from(request.patch.pathSuffix),
            body: Buffer.from(request.patch.body),
            headers: await encryptPairs(request.patch.headers, encr),
            parameters: await encryptPairs(request.patch.parameters, encr),
            tdAddress: patch.tdAddress
        };
    }
    
    // Convert HTTP method from string to its numeric representation
    const methodString = request.request.method;
    if (!(methodString in httpMethods)) {
        throw new Error(`Unsupported HTTP method: ${methodString}`);
    }
    const methodNumber = httpMethods[methodString];
    
    return {
        patch,
        request: { 
            ...request.request, 
            method: methodNumber, // Use the numeric method code instead of the string
            body: Buffer.from(request.request.body, 'utf-8') 
        },
        jqFilter: request.jqFilter,
        responseSchema: request.responseSchema
    };
}

/**
 * Creates an action by calling addAction on the pool contract and retrieves the action ID from logs.
 * @param w3 Web3 instance
 * @param contract Pool contract instance
 * @param action Action data
 * @returns Action ID (hex string)
 */
async function createAction(w3: Web3, contract: any, action: any): Promise<string> {
    // Debug the action object (convert Buffer to hex strings for better readability)
    const debugAction = JSON.stringify(action, (key, value) => {
        if (value && value.type === 'Buffer') {
            return '0x' + Buffer.from(value.data).toString('hex');
        }
        return value;
    }, 2);
    
    console.log("Action data being sent:", debugAction);
    
    const tx = await contract.methods.addAction(action).send({ from: w3.eth.defaultAccount });
    console.log("Transaction hash:", tx.transactionHash);
    
    const logs = tx.logs.filter((log: any) => log.topics.includes(actionTopic));
    if (!logs.length) {
        throw new Error("No action created - missing action topic in logs");
    }
    return logs[0].data;
}

/**
 * Creates a flow by calling createFlow on the core contract and retrieves the flow ID from logs.
 * @param w3 Web3 instance
 * @param contract Core contract instance
 * @param flow Flow data
 * @returns Flow ID (hex string)
 */
async function createFlow(w3: Web3, contract: any, flow: any): Promise<string> {
    console.log("Flow data:", JSON.stringify(flow, (key, value) => 
        typeof value === 'bigint' ? value.toString() : value, 2));
        
    const tx = await contract.methods.createFlow(flow).send({ from: w3.eth.defaultAccount });
    const logs = tx.logs.filter((log: any) => log.topics.includes(flowTopic));
    if (!logs.length) {
        throw new Error("No flow created - missing flow topic in logs");
    }
    return logs[0].data;
}

/**
 * Main function to execute the script.
 */
async function main() {
    try {
        // Check environment variables
        if (!process.env.PRIVATE_KEY) {
            throw new Error("Missing PRIVATE_KEY environment variable");
        }
        
        if (!process.env.CONSUMER_ADDRESS) {
            throw new Error("Missing CONSUMER_ADDRESS environment variable");
        }
        
        // Load and parse public key
        const pkBytes = Buffer.from(config.td_pubkey.slice(2), 'hex');
        
        // Add the '04' prefix for uncompressed public key format if not present
        const formattedPkBytes = pkBytes[0] === 0x04 ? pkBytes : Buffer.concat([Buffer.from([0x04]), pkBytes]);
        
        let pk: EC.KeyPair;
        try {
            pk = secp256k1.keyFromPublic(formattedPkBytes);
        } catch (error) {
            throw new Error("Invalid public key: " + (error as Error).message);
        }

        // Initialize Web3 and contracts
        const w3 = initWeb3(config);
        console.log("Web3 initialized with account:", w3.eth.defaultAccount);

        const coreContract = new w3.eth.Contract(QuexFlowRegistryABI, config.quex_core.address);
        const poolContract = new w3.eth.Contract(RequestOraclePoolABI, config.oracle_pool.address);

        console.log("Preparing request data...");
        // Prepare request data
        const actionRequest = await prepareRequest(config, pk);

        console.log("Creating action...");
        // Create action and retrieve action ID
        const actionId = await createAction(w3, poolContract, actionRequest);
        console.log("action_id:    " + actionId);

        console.log("Creating flow...");
        // Create flow and retrieve flow ID
        const flow = {
            gasLimit: BigInt(config.gas_limit),
            actionId: BigInt(actionId),
            pool: poolContract.options.address,
            consumer: config.consumer,
            callback: config.callback
        };
        
        // Debug info
        console.log("Flow data before sending:");
        console.log("- gasLimit:", flow.gasLimit.toString());
        console.log("- actionId:", flow.actionId.toString());
        console.log("- pool:", flow.pool);
        console.log("- consumer:", flow.consumer);
        console.log("- callback:", flow.callback);
        
        const flowId = await createFlow(w3, coreContract, flow);
        console.log("flow_id:      " + flowId);

        // Retrieve and display fee information
        try {
            console.log("Getting request fee...");
            
            // First, log the raw return value to see its structure
            const requestFeeResult = await coreContract.methods.getRequestFee(BigInt(flowId)).call();
            console.log("Raw request fee result:", requestFeeResult);
            
            // Handle different possible return structures
            if (Array.isArray(requestFeeResult)) {
                const [nativeFee, gas] = requestFeeResult;
                console.log(`Native fee:   ${nativeFee}`);
                console.log(`Gas to cover: ${gas}`);
            } else if (typeof requestFeeResult === 'object' && requestFeeResult !== null) {
                // Access properties in a type-safe way
                const resultObj: Record<string | number, any> = requestFeeResult;
                const nativeFee = resultObj[0] ?? resultObj['nativeFee'] ?? resultObj['_nativeFee'] ?? 'unknown';
                const gas = resultObj[1] ?? resultObj['gas'] ?? resultObj['_gas'] ?? 'unknown';
                console.log(`Native fee:   ${nativeFee}`);
                console.log(`Gas to cover: ${gas}`);
            } else {
                console.log(`Request fee result: ${requestFeeResult}`);
            }
        } catch (error) {
            console.error("Failed to get request fee:", (error as Error).message);
            // Continue execution since we already created the flow successfully
        }
        
        console.log("Workflow completed successfully!");
    } catch (error) {
        console.error("Workflow failed:", (error as Error).message);
        process.exit(1);
    }
}

// Execute main function
main();