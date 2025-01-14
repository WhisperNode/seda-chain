#!/bin/bash
set -euxo pipefail

#
# This script dumps wasm states after storing and instantiating contracts.
# Then, it adds these states to a given original genesis file.
# The final genesis file is placed in the current directory as genesis.json.
#

# download_contract_release() downloads a file from seda-chain-contracts repo.
# Argument:
#   $1: Wasm contract file name
function download_contract_release() {
  local repo="sedaprotocol/seda-chain-contracts"
  local url="https://api.github.com"

  mkdir -p $WASM_DIR

  function gh_curl() {
    set +x
    curl -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3.raw" \
         $@
    set -x
  }

  if [ "$CONTRACTS_VERSION" = "latest" ]; then
    # Github should return the latest release first.
    parser=".[0].assets | map(select(.name == \"${1}\"))[0].id"
  else
    parser=". | map(select(.tag_name == \"$CONTRACTS_VERSION\"))[0].assets | map(select(.name == \"${1}\"))[0].id"
  fi;

  asset_id=`gh_curl -s $url/repos/$repo/releases | jq "$parser"`
  if [ "$asset_id" = "null" ]; then
    >&2 echo "ERROR: asset not found: version $CONTRACTS_VERSION, file $1"
    exit 1
  fi;

  set +x
  curl -sL --header "Authorization: token $GITHUB_TOKEN" \
    --header 'Accept: application/octet-stream' \
    https://$GITHUB_TOKEN:@api.github.com/repos/$repo/releases/assets/$asset_id \
    --output-dir $WASM_DIR --output ${1}
  set -x
}

# store_and_instantiate() stores and instantiates a contract and returns its address
# Arguments:
#   $1: Contract file name
#   $2: Initial state
function store_and_instantiate() {
    local TX_OUTPUT=$($LOCAL_BIN tx wasm store $WASM_DIR/$1 --from $ADDR --keyring-backend test --gas auto --gas-adjustment 1.2 --home $TMP_HOME --chain-id $TEMP_CHAIN_ID -y --output json)
    [[ -z "$TX_OUTPUT" ]] && { echo "failed to get tx output" ; exit 1; }
    local TX_HASH=$(echo $TX_OUTPUT | jq -r .txhash)
    sleep 10;

    local STORE_TX_OUTPUT=$($LOCAL_BIN query tx $TX_HASH  --home $TMP_HOME --output json)
    local CODE_ID=$(echo $STORE_TX_OUTPUT | jq -r '.events[] | select(.type | contains("store_code")).attributes[] | select(.key | contains("code_id")).value')
    [[ -z "$CODE_ID" ]] && { echo "failed to get code ID" ; exit 1; }

    local INSTANTIATE_OUTPUT=$($LOCAL_BIN tx wasm instantiate $CODE_ID "$2" --no-admin --from $ADDR --keyring-backend test --label $CODE_ID --gas auto --gas-adjustment 1.2 --home $TMP_HOME --chain-id $TEMP_CHAIN_ID -y --output json)
    TX_HASH=$(echo "$INSTANTIATE_OUTPUT" | jq -r '.txhash')
    sleep 10;

    local INSTANTIATE_TX_OUTPUT=$($LOCAL_BIN query tx $TX_HASH  --home $TMP_HOME --output json)
    local CONTRACT_ADDRESS=$(echo $INSTANTIATE_TX_OUTPUT | jq -r '.events[] | select(.type == "instantiate") | .attributes[] | select(.key == "_contract_address") | .value')
    [[ -z "$CONTRACT_ADDRESS" ]] && { echo "failed to get contract address for ${1}" ; exit 1; }
    
    echo $CONTRACT_ADDRESS
}


source config.sh

# flags: add-wasm-contracts and add-groups
ADD_WASM_CONTRACTS=false
ADD_GROUPS=false

while [ ! $# -eq 0 ]
do
	case "$1" in
		--add-wasm-contracts)
			ADD_WASM_CONTRACTS=true
			;;
		--add-groups)
			ADD_GROUPS=true
			;;
	esac
	shift
done

# at least one flag should be on
if [ $ADD_WASM_CONTRACTS = false ] && [ $ADD_GROUPS = false ]; then
    echo "add at least one flag: --add-wasm-contracts or --add-groups"
    exit 1
fi

#
#   PRELIMINARY CHECKS AND DOWNLOADS
#
ORIGINAL_GENESIS=$NODE_DIR/genesis.json
if [ ! -f "$ORIGINAL_GENESIS" ]; then
  echo "Original genesis file not found inside node directory."
  exit 1
fi

TMP_HOME=./tmp
rm -rf $TMP_HOME

if [ $ADD_WASM_CONTRACTS = true ]; then
  rm -rf $WASM_DIR
  download_contract_release proxy_contract.wasm
  download_contract_release staking.wasm
  download_contract_release data_requests.wasm
fi

TEMP_CHAIN_ID=temp-seda-chain

#
#   SCRIPT BEGINS - START CHAIN
#
$LOCAL_BIN init node0 --home $TMP_HOME --chain-id $TEMP_CHAIN_ID --default-denom aseda

$LOCAL_BIN keys add deployer --home $TMP_HOME --keyring-backend test
ADDR=$($LOCAL_BIN keys show deployer --home $TMP_HOME --keyring-backend test -a)
$LOCAL_BIN add-genesis-account $ADDR 100000000000000000seda --home $TMP_HOME --keyring-backend test

if [ $ADD_GROUPS = true ]; then
  echo $ADMIN_SEED | $LOCAL_BIN keys add admin --home $TMP_HOME --keyring-backend test --recover
  ADMIN_ADDR=$($LOCAL_BIN keys show admin --home $TMP_HOME --keyring-backend test -a)
  $LOCAL_BIN add-genesis-account $ADMIN_ADDR 100000000000000000seda --home $TMP_HOME --keyring-backend test
fi

$LOCAL_BIN gentx deployer 10000000000000000seda --home $TMP_HOME --keyring-backend test --chain-id $TEMP_CHAIN_ID
$LOCAL_BIN collect-gentxs --home $TMP_HOME

$LOCAL_BIN start --home $TMP_HOME > chain_output.log 2>&1 & disown

sleep 20


#
#   SEND TRANSACTIONS WHILE CHAIN IS RUNNING
#

# Create group and group policy
if [ $ADD_GROUPS = true ]; then
  $LOCAL_BIN tx group create-group-with-policy $ADMIN_ADDR "ipfs://not_real_metadata" "{\"name\":\"quick turnaround\",\"description\":\"\"}" $MEMBERS_JSON_FILE $POLICY_JSON_FILE --home $TMP_HOME --from $ADMIN_ADDR --keyring-backend test --chain-id $TEMP_CHAIN_ID -y
  sleep 10
fi


if [ $ADD_WASM_CONTRACTS = true ]; then
  # Store and instantiate three contracts
  PROXY_ADDR=$(store_and_instantiate proxy_contract.wasm '{"token":"aseda"}')
  ARG='{"token":"aseda", "proxy": "'$PROXY_ADDR'" }'
  STAKING_ADDR=$(store_and_instantiate staking.wasm "$ARG")
  DR_ADDR=$(store_and_instantiate data_requests.wasm "$ARG")

  # Call SetStaking and SetDataRequests on Proxy contract to set circular dependency
  $LOCAL_BIN tx wasm execute $PROXY_ADDR '{"set_staking":{"contract":"'$STAKING_ADDR'"}}' --from $ADDR --gas auto --gas-adjustment 1.2 --keyring-backend test  --home $TMP_HOME --chain-id $TEMP_CHAIN_ID -y
  sleep 10
  $LOCAL_BIN tx wasm execute $PROXY_ADDR '{"set_data_requests":{"contract":"'$DR_ADDR'"}}' --from $ADDR --gas auto --gas-adjustment 1.2 --keyring-backend test  --home $TMP_HOME --chain-id $TEMP_CHAIN_ID -y
  sleep 10
fi

#
#   TERMINATE CHAIN PROCESS, EXPORT, AND MODIFY GIVEN GENESIS
#
pkill sedad
sleep 5

$LOCAL_BIN export --home $TMP_HOME > $TMP_HOME/exported
python3 -m json.tool $TMP_HOME/exported > $TMP_HOME/genesis.json
rm $TMP_HOME/exported


EXPORTED_GENESIS=$TMP_HOME/genesis.json
TMP_GENESIS=$TMP_HOME/tmp_genesis.json
TMP_TMP_GENESIS=$TMP_HOME/tmp_tmp_genesis.json

cp $ORIGINAL_GENESIS $TMP_GENESIS # make adjustments on TMP_GENESIS until replacing original genesis in the last step

# Modify group state and wasm code upload params
if [ $ADD_GROUPS = true ]; then
  jq '.app_state["group"]' $EXPORTED_GENESIS > $TMP_HOME/group.tmp
  GROUP_POLICY_ADDR=$(jq '.app_state["group"]["group_policies"][0]["address"]' $EXPORTED_GENESIS)

  jq --slurpfile group $TMP_HOME/group.tmp '.app_state["group"] = $group[0]' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
  jq '.app_state["wasm"]["params"]["code_upload_access"]["permission"]="AnyOfAddresses"' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
  jq '.app_state["wasm"]["params"]["instantiate_default_permission"]="AnyOfAddresses"' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
  jq '.app_state["wasm"]["params"]["code_upload_access"]["addresses"]=['$GROUP_POLICY_ADDR']' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
fi

# Modify wasm codes, contracts, and sequences. 
# Also modify wasm-storage's proxy contract registery.
if [ $ADD_WASM_CONTRACTS = true ]; then
  jq '.app_state["wasm"]["codes"]' $EXPORTED_GENESIS > $TMP_HOME/codes.tmp
  jq '.app_state["wasm"]["contracts"]' $EXPORTED_GENESIS > $TMP_HOME/contracts.tmp
  jq '.app_state["wasm"]["sequences"]' $EXPORTED_GENESIS > $TMP_HOME/sequences.tmp

  jq '.app_state["wasm-storage"]["proxy_contract_registry"]="'$PROXY_ADDR'"' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
  jq --slurpfile codes $TMP_HOME/codes.tmp '.app_state["wasm"]["codes"] = $codes[0]' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
  jq --slurpfile contracts $TMP_HOME/contracts.tmp '.app_state["wasm"]["contracts"] = $contracts[0]' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
  jq --slurpfile sequences $TMP_HOME/sequences.tmp '.app_state["wasm"]["sequences"] = $sequences[0]' $TMP_GENESIS > $TMP_TMP_GENESIS && mv $TMP_TMP_GENESIS $TMP_GENESIS
fi

mv $TMP_GENESIS $ORIGINAL_GENESIS

# clean up
rm -rf $TMP_HOME
rm chain_output.log
