# 📋 Complete List of Scroll Contract Operations

This document provides a comprehensive list of all operations (functions) that can be performed on Scroll contracts, organized by contract type and functionality.

## 1. **L1 Rollup Core Operations** 

### ScrollChain (Main Rollup Contract)
**Location**: `src/L1/rollup/ScrollChain.sol`

#### Batch Lifecycle Operations
- `commitBatches(uint8 version, bytes32 parentBatchHash, bytes32 lastBatchHash)` - **Sequencer Only** - Commit one or more batches to L1
- `finalizeBundlePostEuclidV2(bytes calldata batchHeader, uint256 totalL1Messages, bytes32 postStateRoot, bytes32 withdrawRoot, bytes calldata aggrProof)` - **Prover Only** - Finalize batches with ZK proof
- `commitAndFinalizeBatch(uint8 version, bytes32 parentBatchHash, FinalizeStruct calldata finalizeStruct)` - **Anyone** - Permissionless batch finalization (enforced mode)
- `revertBatch(bytes calldata batchHeader)` - **Owner Only** - Revert pending batches
- `importGenesisBatch(bytes calldata _batchHeader, bytes32 _stateRoot)` - **Anyone** - Import L2 genesis block

#### Access Control Management
- `addSequencer(address _account)` - **Owner Only** - Add account to sequencer list
- `removeSequencer(address _account)` - **Owner Only** - Remove account from sequencer list
- `addProver(address _account)` - **Owner Only** - Add account to prover list
- `removeProver(address _account)` - **Owner Only** - Remove account from prover list

#### System Control
- `setPause(bool _status)` - **Owner Only** - Pause/unpause contract
- `disableEnforcedBatchMode()` - **Owner Only** - Exit enforced batch mode
- `initializeV2()` - **Reinitializer** - Contract upgrade initialization

#### View Functions
- `isBatchFinalized(uint256 _batchIndex)` - **Anyone** - Check if batch is finalized
- `lastFinalizedBatchIndex()` - **Anyone** - Get latest finalized batch index
- `committedBatches(uint256 batchIndex)` - **Anyone** - Get batch hash
- `finalizedStateRoots(uint256 batchIndex)` - **Anyone** - Get state root
- `withdrawRoots(uint256 batchIndex)` - **Anyone** - Get withdraw root
- `isEnforcedModeEnabled()` - **Anyone** - Check enforced mode status

## 2. **L1 Message Queue Operations**

### L1MessageQueueV2 (Current Message Queue)
**Location**: `src/L1/rollup/L1MessageQueueV2.sol`

#### Message Operations
- `appendCrossDomainMessage(address _target, uint256 _gasLimit, bytes calldata _data)` - **Messenger Only** - Queue cross-domain message
- `appendEnforcedTransaction(address _sender, address _target, uint256 _value, uint256 _gasLimit, bytes calldata _data)` - **EnforcedTxGateway Only** - Queue enforced transaction
- `finalizePoppedCrossDomainMessage(uint256 _nextUnfinalizedQueueIndex)` - **ScrollChain Only** - Finalize processed messages

#### Fee Estimation & View Functions
- `getFirstUnfinalizedMessageEnqueueTime()` - **Anyone** - Get timestamp of first unfinalized message
- `getMessageRollingHash(uint256 queueIndex)` - **Anyone** - Get rolling hash at index
- `getMessageEnqueueTimestamp(uint256 queueIndex)` - **Anyone** - Get message timestamp
- `estimateL2BaseFee()` - **Anyone** - Estimate L2 base fee
- `estimateCrossDomainMessageFee(uint256 _gasLimit)` - **Anyone** - Estimate cross-domain fee
- `calculateIntrinsicGasFee(bytes calldata _calldata)` - **Anyone** - Calculate intrinsic gas
- `computeTransactionHash(...)` - **Anyone** - Compute L1 message transaction hash

### L1MessageQueueV1 (Legacy Message Queue)
**Location**: `src/L1/rollup/L1MessageQueueV1.sol`

#### Legacy Operations
- `resetPoppedCrossDomainMessage(uint256 _startIndex)` - **ScrollChain Only** - Reset popped messages
- `dropCrossDomainMessage(uint256 _index)` - **Messenger Only** - Drop expired message
- `updateGasOracle(address _newGasOracle)` - **Owner Only** - Update gas oracle
- `updateMaxGasLimit(uint256 _newMaxGasLimit)` - **Owner Only** - Update max gas limit

#### View Functions
- `getCrossDomainMessage(uint256 _queueIndex)` - **Anyone** - Get message hash
- `isMessageSkipped(uint256 _queueIndex)` - **Anyone** - Check if message is skipped
- `isMessageDropped(uint256 _queueIndex)` - **Anyone** - Check if message is dropped

## 3. **Cross-Chain Messaging**

### L1ScrollMessenger
**Location**: `src/L1/L1ScrollMessenger.sol`

#### Message Operations
- `sendMessage(address _to, uint256 _value, bytes memory _message, uint256 _gasLimit)` - **Anyone** - Send L1→L2 message
- `sendMessage(address _to, uint256 _value, bytes calldata _message, uint256 _gasLimit, address _refundAddress)` - **Anyone** - Send L1→L2 message with refund address
- `relayMessageWithProof(address _from, address _to, uint256 _value, uint256 _nonce, bytes memory _message, L2MessageProof memory _proof)` - **Anyone** - Relay L2→L1 message with proof
- `replayMessage(address _from, address _to, uint256 _value, uint256 _messageNonce, bytes memory _message, uint32 _newGasLimit, address _refundAddress)` - **Anyone** - Replay failed message with new gas limit

### L2ScrollMessenger
**Location**: `src/L2/L2ScrollMessenger.sol`

#### Message Operations
- `sendMessage(address _to, uint256 _value, bytes memory _message, uint256 _gasLimit)` - **Anyone** - Send L2→L1 message
- `sendMessage(address _to, uint256 _value, bytes calldata _message, uint256 _gasLimit, address)` - **Anyone** - Send message (overload)
- `relayMessage(address _from, address _to, uint256 _value, uint256 _nonce, bytes memory _message)` - **L1ScrollMessenger Only** - Relay L1→L2 message

## 4. **Gateway Operations (Asset Bridging)**

### L1ETHGateway / L2ETHGateway
**Location**: `src/L1/gateways/L1ETHGateway.sol` / `src/L2/gateways/L2ETHGateway.sol`

#### ETH Bridging Operations
- `depositETH(uint256 _amount, uint256 _gasLimit)` - **Anyone** - Deposit ETH to L2
- `depositETH(address _to, uint256 _amount, uint256 _gasLimit)` - **Anyone** - Deposit ETH to specific recipient
- `depositETHAndCall(address _to, uint256 _amount, bytes calldata _data, uint256 _gasLimit)` - **Anyone** - Deposit ETH and call contract
- `finalizeWithdrawETH(address _from, address _to, uint256 _amount, bytes calldata _data)` - **Counterpart Only** - Finalize ETH withdrawal

### L1StandardERC20Gateway / L2StandardERC20Gateway
**Location**: `src/L1/gateways/L1StandardERC20Gateway.sol` / `src/L2/gateways/L2StandardERC20Gateway.sol`

#### ERC20 Token Bridging
- `depositERC20(address _token, uint256 _amount, uint256 _gasLimit)` - **Anyone** - Deposit ERC20 tokens
- `depositERC20(address _token, address _to, uint256 _amount, uint256 _gasLimit)` - **Anyone** - Deposit to specific recipient
- `depositERC20AndCall(address _token, address _to, uint256 _amount, bytes calldata _data, uint256 _gasLimit)` - **Anyone** - Deposit and call contract
- `finalizeWithdrawERC20(address _l1Token, address _l2Token, address _from, address _to, uint256 _amount, bytes calldata _data)` - **Counterpart Only** - Finalize ERC20 withdrawal

### L1CustomERC20Gateway / L2CustomERC20Gateway
**Location**: `src/L1/gateways/L1CustomERC20Gateway.sol` / `src/L2/gateways/L2CustomERC20Gateway.sol`

#### Custom ERC20 Operations
- `updateTokenMapping(address _l1Token, address _l2Token)` - **Owner Only** - Update token mapping
- Standard ERC20 bridging operations (same as above)

### L1ERC721Gateway / L2ERC721Gateway
**Location**: `src/L1/gateways/L1ERC721Gateway.sol` / `src/L2/gateways/L2ERC721Gateway.sol`

#### NFT Bridging Operations
- `depositERC721(address _token, uint256 _tokenId, uint256 _gasLimit)` - **Anyone** - Deposit NFT
- `depositERC721(address _token, address _to, uint256 _tokenId, uint256 _gasLimit)` - **Anyone** - Deposit NFT to recipient
- `depositERC721AndCall(address _token, address _to, uint256 _tokenId, bytes calldata _data, uint256 _gasLimit)` - **Anyone** - Deposit NFT and call
- `finalizeWithdrawERC721(address _l1Token, address _l2Token, address _from, address _to, uint256 _tokenId, bytes calldata _data)` - **Counterpart Only** - Finalize NFT withdrawal
- `updateTokenMapping(address _l1Token, address _l2Token)` - **Owner Only** - Update token mapping

### L1ERC1155Gateway / L2ERC1155Gateway
**Location**: `src/L1/gateways/L1ERC1155Gateway.sol` / `src/L2/gateways/L2ERC1155Gateway.sol`

#### Multi-Token Operations
- `depositERC1155(address _token, uint256 _tokenId, uint256 _amount, uint256 _gasLimit)` - **Anyone** - Deposit ERC1155 token
- `depositERC1155(address _token, address _to, uint256 _tokenId, uint256 _amount, uint256 _gasLimit)` - **Anyone** - Deposit to recipient
- `batchDepositERC1155(address _token, uint256[] calldata _tokenIds, uint256[] calldata _amounts, uint256 _gasLimit)` - **Anyone** - Batch deposit
- `finalizeWithdrawERC1155(...)` - **Counterpart Only** - Finalize withdrawal
- `updateTokenMapping(address _l1Token, address _l2Token)` - **Owner Only** - Update mapping

### L1GatewayRouter / L2GatewayRouter
**Location**: `src/L1/gateways/L1GatewayRouter.sol` / `src/L2/gateways/L2GatewayRouter.sol`

#### Routing Operations
- `depositETH(uint256 _amount, uint256 _gasLimit)` - **Anyone** - Route ETH deposit
- `depositERC20(address _token, uint256 _amount, uint256 _gasLimit)` - **Anyone** - Route ERC20 deposit
- `finalizeWithdrawETH(address _from, address _to, uint256 _amount, bytes calldata _data)` - **Counterpart Only** - Route ETH withdrawal
- `finalizeWithdrawERC20(address _l1Token, address _l2Token, address _from, address _to, uint256 _amount, bytes calldata _data)` - **Counterpart Only** - Route ERC20 withdrawal

#### Gateway Management
- `setETHGateway(address _newEthGateway)` - **Owner Only** - Set ETH gateway
- `setDefaultERC20Gateway(address _newDefaultERC20Gateway)` - **Owner Only** - Set default ERC20 gateway
- `setERC20Gateway(address[] memory _tokens, address[] memory _gateways)` - **Owner Only** - Set custom ERC20 gateways

#### View Functions
- `getERC20Gateway(address _token)` - **Anyone** - Get gateway for token
- `getL2ERC20Address(address _l1Address)` - **Anyone** - Get L2 token address

## 5. **L2 System Contract Operations**

### L1GasPriceOracle
**Location**: `src/L2/predeploys/L1GasPriceOracle.sol`

#### Gas Price Operations
- `getL1Fee(bytes memory _data)` - **Anyone** - Calculate L1 data fee
- `setL1BaseFee(uint256 _l1BaseFee)` - **Whitelisted Sender Only** - Update L1 base fee

#### Configuration (Owner Only)
- `setOverhead(uint256 _overhead)` - Set overhead parameter
- `setScalar(uint256 _scalar)` - Set scalar parameter
- `setCommitScalar(uint256 _scalar)` - Set commit scalar
- `setBlobScalar(uint256 _scalar)` - Set blob scalar
- `setPenaltyThreshold(uint256 _threshold)` - Set penalty threshold
- `setPenaltyFactor(uint256 _factor)` - Set penalty factor
- `updateWhitelist(address _newWhitelist)` - Update whitelist
- `enableCurie()` - Enable Curie upgrade
- `enableFeynman()` - Enable Feynman upgrade

### L1BlockContainer
**Location**: `src/L2/predeploys/L1BlockContainer.sol`

#### L1 Block Information
- `latestBaseFee()` - **Anyone** - Get latest L1 base fee
- `latestBlockNumber()` - **Anyone** - Get latest L1 block number
- `latestBlockTimestamp()` - **Anyone** - Get latest L1 timestamp
- `getStateRoot(bytes32 _blockHash)` - **Anyone** - Get L1 state root
- `getBlockTimestamp(bytes32 _blockHash)` - **Anyone** - Get L1 block timestamp
- `updateWhitelist(address _newWhitelist)` - **Owner Only** - Update whitelist

### L2MessageQueue
**Location**: `src/L2/predeploys/L2MessageQueue.sol`

#### Queue Operations
- `initialize(address _messenger)` - **Owner Only** - Initialize queue
- `appendMessage(bytes32 _messageHash)` - **Messenger Only** - Add message to queue

### WrappedEther (WETH)
**Location**: `src/L2/predeploys/WrappedEther.sol`

#### WETH Operations
- `withdraw(uint256 wad)` - **Anyone** - Unwrap ETH to native ETH

## 6. **Verification Operations**

### ZK Verifiers (Multiple Versions)
**Locations**: Various verifier contracts (V1, V2, PostEuclid, PostFeynman)

#### Proof Verification
- `verify(bytes calldata proof, bytes calldata publicInput)` - **Anyone** - Verify ZK proof
- `verifyBundleProof(uint256 version, uint256 batchIndex, bytes calldata aggrProof, bytes calldata publicInputs)` - **Anyone** - Verify bundle proof

## 7. **Token Factory Operations**

### ScrollStandardERC20Factory
**Location**: `src/libraries/token/ScrollStandardERC20Factory.sol`

#### Token Deployment
- `computeL2TokenAddress(address _gateway, address _l1Token)` - **Anyone** - Compute L2 token address
- `deployL2Token(address _gateway, address _l1Token)` - **Anyone** - Deploy L2 token

## 8. **Specialized Gateway Operations**

### L1USDCGateway / L2USDCGateway (USDC Specific)
**Location**: `src/L1/gateways/usdc/L1USDCGateway.sol` / `src/L2/gateways/usdc/L2USDCGateway.sol`

#### USDC Operations
- `burnAllLockedUSDC()` - **Anyone** - Burn all locked USDC (emergency)
- `updateCircleCaller(address _caller)` - **Owner Only** - Update Circle caller
- `pauseDeposit(bool _paused)` - **Owner Only** - Control deposit pause
- `pauseWithdraw(bool _paused)` - **Owner Only** - Control withdraw pause
- Standard ERC20 bridging operations

### L1LidoGateway / L2LidoGateway (Lido Integration)
**Location**: `src/L1/gateways/lido/` / `src/L2/gateways/lido/`

#### Lido Staking Operations
- Specialized wstETH bridging operations
- Lido liquid staking integration functions

### L1BatchBridgeGateway / L2BatchBridgeGateway
**Location**: `src/L1/gateways/L1BatchBridgeGateway.sol` / `src/L2/gateways/L2BatchBridgeGateway.sol`

#### Batch Bridging Operations
- Batch deposit/withdrawal functions for efficient multi-token transfers

## 9. **System Administration**

### ScrollOwner (Multi-signature)
**Location**: `src/misc/ScrollOwner.sol`

#### Governance Operations
- Multi-signature transaction execution and management functions
- Critical system parameter changes

### SystemConfig
**Location**: `src/L1/system-contract/SystemConfig.sol`

#### System Configuration
- Various parameter update functions (Owner/Admin only)
- System configuration getters (Anyone)

### PauseController
**Location**: `src/misc/PauseController.sol`

#### Emergency Controls
- System-wide pause/unpause operations
- Emergency response functions

## 10. **Enforced Transaction Operations**

### EnforcedTxGateway
**Location**: `src/L1/gateways/EnforcedTxGateway.sol`

#### Enforced Transaction Operations
- `sendTransaction(address _target, uint256 _value, uint256 _gasLimit, bytes calldata _data)` - **Anyone** - Send enforced transaction
- Functions for censorship resistance and forced inclusion

---

## 🔐 **Access Control Summary**

| **Role** | **Can Perform** |
|----------|----------------|
| **Anyone** | View functions, deposits, withdrawals, message sending, proof verification, enforced transactions |
| **Owner** | Configuration changes, gateway management, access control updates, emergency pause |
| **Sequencer** | Batch commitment operations on ScrollChain |
| **Prover** | Batch finalization with ZK proofs |
| **Messenger** | Cross-chain message relay operations |
| **Counterpart** | Cross-chain finalization operations (L1↔L2) |
| **Whitelisted** | Specific system parameter updates (e.g., L1 gas price) |
| **Multi-sig** | Critical governance operations via ScrollOwner |
| **Contract-Specific** | Some functions restricted to specific contract addresses |

---

## 📊 **Operation Categories**

### **Core Rollup Operations**
- Batch commitment, finalization, and verification
- State root management and fraud proof systems

### **Cross-Chain Communication**
- Message passing between L1 and L2
- Cross-domain transaction execution

### **Asset Bridging**
- ETH, ERC20, ERC721, ERC1155 token transfers
- Specialized integrations (USDC, Lido, etc.)

### **System Management**
- Access control and role management
- Protocol configuration and upgrades
- Emergency controls and pause mechanisms

### **Fee Management**
- Gas price estimation and fee calculation
- L1 data availability cost computation

### **Censorship Resistance**
- Enforced transaction inclusion
- Alternative execution paths when sequencer is unavailable

---

This comprehensive documentation covers all major operational functions across the entire Scroll ecosystem, providing developers, operators, and users with complete visibility into available contract interactions and their access requirements.