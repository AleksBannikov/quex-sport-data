export default {
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
    "td_pubkey": "0xb23974e9267308bd821c34038e00072bf1e297f308227d98de387deb50f9ca2ebed328af1471f291e53eff602130f5ab79d006ee040553016775d79261362770",
    "consumer": process.env.CONSUMER_ADDRESS || "",
    "callback": "0x8f0b0698"
}