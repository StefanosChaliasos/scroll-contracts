# Enforced Transaction Gateway - Complete Documentation

## Overview

The EnforcedTxGateway is a critical component of the Scroll L2 protocol that enables users to submit transactions from Layer 1 (L1) that are guaranteed to be included on Layer 2 (L2). This mechanism provides censorship resistance and ensures L2 liveness.

## Key Contracts

1. **[EnforcedTxGateway](src/L1/gateways/EnforcedTxGateway.sol)** - Entry point for users to submit enforced transactions
2. **[L1MessageQueueV2](src/L1/rollup/L1MessageQueueV2.sol)** - Queues and manages cross-domain messages
3. **[ScrollChain](src/L1/rollup/ScrollChain.sol)** - Handles batch commitment and finalization
4. **[SystemConfig](src/L1/SystemConfig.sol)** - Stores protocol parameters including enforced batch thresholds
5. **[L2MessageQueue](src/L2/predeploys/L2MessageQueue.sol)** - L2 contract that tracks message execution

## Transaction Flow

### 1. Transaction Submission

Users can submit enforced transactions through two methods:

#### Method A: Direct Submission
```solidity
EnforcedTxGateway.sendTransaction(address _target, uint256 _value, uint256 _gasLimit, bytes _data)
```
[Source](src/L1/gateways/EnforcedTxGateway.sol#L69-L80)

**Flow:**
1. User (EOA or contract) calls the function with ETH for fees
2. If caller is a contract, address aliasing is applied (+0x1111000000000000000000000000000000001111)
3. Transaction is forwarded to internal `_sendTransaction()`

#### Method B: Meta-Transaction with Signature
```solidity
EnforcedTxGateway.sendTransaction(
    address _sender,
    address _target, 
    uint256 _value,
    uint256 _gasLimit,
    bytes _data,
    uint256 _deadline,
    bytes _signature,
    address _refundAddress
)
```
[Source](src/L1/gateways/EnforcedTxGateway.sol#L100-L136)

**Flow:**
1. Anyone can submit on behalf of `_sender` with a valid EIP-712 signature
2. Signature is verified against the sender's address
3. Nonce is incremented to prevent replay attacks
4. Transaction is forwarded to internal `_sendTransaction()`

### 2. Fee Calculation and Payment

The internal `_sendTransaction()` function ([Source](src/L1/gateways/EnforcedTxGateway.sol#L139-L165)):

1. **Fee Calculation**: Calls `IL1MessageQueueV2.estimateCrossDomainMessageFee(_gasLimit)`
2. **Fee Validation**: Ensures `msg.value >= fee`
3. **Fee Payment**: Sends fee to the `feeVault` address
4. **Transaction Queueing**: Calls `IL1MessageQueueV2.appendEnforcedTransaction()`
5. **Refund**: Returns excess ETH to `_refundAddress`

### 3. Message Queueing in L1MessageQueueV2

The `appendEnforcedTransaction()` function ([Source](src/L1/rollup/L1MessageQueueV2.sol#L426-L441)):

1. **Access Control**: Validates caller is EnforcedTxGateway
2. **Gas Validation**: Ensures gas limit meets intrinsic gas requirements
3. **Queue Transaction**: Calls internal `_queueTransaction()`

The `_queueTransaction()` function:
- Encodes transaction in RLP format with type 0x7E
- Stores with rolling hash and timestamp
- Increments `nextCrossDomainMessageIndex`
- Emits `QueueTransaction` event

### 4. Batch Processing Modes

#### Normal Mode (Sequencer-Controlled)

**Commit Phase** ([Source](src/L1/rollup/ScrollChain.sol#L377-L429)):
- Sequencer calls `commitBatches()` or `commitBatchesWithBlobProof()`
- Only authorized sequencer can commit
- Batches include L1 messages in order

**Finalize Phase** ([Source](src/L1/rollup/ScrollChain.sol#L680-L746)):
- Prover calls `finalizeBundlePostEuclidV2()`
- Provides zero-knowledge proof of correct execution
- Updates finalized batch index

#### Enforced Batch Mode (Permissionless)

Triggered when ([Source](src/L1/rollup/ScrollChain.sol#L752-L823)):
- First unfinalized message age > `maxDelayMessageQueue`, OR
- Last finalized batch age > `maxDelayEnterEnforcedMode`

**Process:**
1. Anyone can call `commitAndFinalizeBatch()`
2. Must be top-level call (tx.origin == msg.sender)
3. Reverts all uncommitted batches if any exist
4. Commits and finalizes in single transaction
5. Sets enforced mode flag

### 5. L2 Execution

1. L2 sequencer monitors `QueueTransaction` events from L1MessageQueueV2
2. Must include enforced transactions in L2 blocks
3. Transactions execute with aliased sender address
4. Cannot skip messages - must process in order
5. Updates L2MessageQueue merkle tree

### 6. Finalization

After L2 execution:
1. `ScrollChain.finalizePoppedCrossDomainMessage()` is called
2. Updates `nextUnfinalizedQueueIndex` in L1MessageQueueV2
3. Marks messages as processed

## All Possible Scenarios

### Scenario 1: EOA Direct Submission
**Steps:**
1. EOA calls `sendTransaction()` with target, value, gasLimit, data
2. No address aliasing applied (tx.origin == msg.sender)
3. Fee calculated and paid
4. Transaction queued with original EOA as sender
5. Included in next L2 batch by sequencer

**Result:** Transaction executes on L2 with EOA as sender

### Scenario 2: Smart Contract Submission
**Steps:**
1. Smart contract calls `sendTransaction()`
2. Address aliasing applied (sender + 0x1111000000000000000000000000000000001111)
3. Fee calculated and paid
4. Transaction queued with aliased address as sender
5. Included in next L2 batch by sequencer

**Result:** Transaction executes on L2 with aliased address as sender

### Scenario 3: Meta-Transaction via Signature
**Steps:**
1. User signs transaction data off-chain (EIP-712)
2. Relayer submits transaction with signature
3. Signature verified, nonce incremented
4. Fee paid by relayer, refund sent to specified address
5. Transaction queued with original signer as sender

**Result:** Transaction executes on L2 with signer as sender

### Scenario 4: Sequencer Censorship - Enforced Mode Activation
**Steps:**
1. User submits enforced transaction
2. Sequencer refuses to include it in batches
3. Message age exceeds `maxDelayMessageQueue` threshold
4. Anyone calls `commitAndFinalizeBatch()`
5. Enforced mode activated, uncommitted batches reverted
6. New batch created with pending messages

**Result:** Transaction forcibly included despite sequencer censorship

### Scenario 5: Sequencer Offline - Enforced Mode Activation
**Steps:**
1. Multiple enforced transactions queued
2. Sequencer stops producing batches
3. Last finalized batch age exceeds `maxDelayEnterEnforcedMode`
4. Community member calls `commitAndFinalizeBatch()`
5. All pending messages included in enforced batch

**Result:** L2 continues operating without sequencer

### Scenario 6: Insufficient Fee
**Steps:**
1. User calls `sendTransaction()` with insufficient ETH
2. Fee calculation shows required amount
3. Transaction reverts with "Insufficient value for fee"

**Result:** Transaction not queued, user must retry with correct fee

### Scenario 7: Contract Paused
**Steps:**
1. Owner calls `setPause(true)` on EnforcedTxGateway
2. User attempts to submit transaction
3. Transaction reverts with "Pausable: paused"

**Result:** No transactions can be submitted until unpaused

### Scenario 8: Signature Expired
**Steps:**
1. User creates signature with deadline
2. Deadline passes before submission
3. Relayer attempts to submit
4. Transaction reverts with "signature expired"

**Result:** Transaction not queued, new signature needed

### Scenario 9: Replay Attack Prevention
**Steps:**
1. User signs and submits meta-transaction
2. Attacker captures signature
3. Attacker attempts to replay transaction
4. Transaction reverts with "Incorrect signature" (nonce mismatch)

**Result:** Replay attack prevented by nonce mechanism

### Scenario 10: Refund Failure
**Steps:**
1. User submits transaction with refund to contract
2. Contract has no receive/fallback function
3. Transaction processes successfully
4. Refund attempt reverts with "Failed to refund the fee"

**Result:** Entire transaction reverts, fee not collected

## Security Features

### 1. Address Aliasing
- **Purpose**: Prevent L1 contracts from impersonating L2 EOAs
- **Implementation**: [AddressAliasHelper](src/libraries/common/AddressAliasHelper.sol)
- **Offset**: 0x1111000000000000000000000000000000001111

### 2. Access Control
- **EnforcedTxGateway**: Ownable, only owner can pause
- **L1MessageQueueV2**: Only EnforcedTxGateway can append enforced transactions
- **ScrollChain**: Only sequencer can commit in normal mode

### 3. Reentrancy Protection
- **Modifier**: `nonReentrant` on `_sendTransaction()`
- **Purpose**: Prevent reentrancy during fee payment/refund

### 4. Signature Security
- **Standard**: EIP-712 typed data signing
- **Domain**: "EnforcedTxGateway" version "1"
- **Replay Protection**: Nonces and deadlines

### 5. Economic Security
- **Fee Mechanism**: Ensures users pay for L2 execution
- **Fee Vault**: Collects fees for protocol sustainability
- **Refund**: Excess fees returned to prevent overpayment

### 6. Liveness Guarantees
- **Enforced Mode**: Permissionless batch submission
- **Time Thresholds**: Configurable via SystemConfig
- **Top-Level Call**: Prevents contract-based attacks

## Test Coverage

### Unit Tests
- **[EnforcedTxGateway.spec.ts](hardhat-test/EnforcedTxGateway.spec.ts)** - Comprehensive TypeScript tests
- **[L1MessageQueueV2.t.sol](src/test/L1MessageQueueV2.t.sol)** - Solidity tests for queue
- **[ScrollChain.t.sol](src/test/ScrollChainTest.t.sol)** - Batch processing tests

### Integration Tests
- **[L1GatewayTestBase.t.sol](src/test/L1GatewayTestBase.t.sol)** - Gateway integration setup
- Cross-layer message flow tests

## Gas Considerations

### Fee Calculation Formula
```
fee = (gasLimit + baseFeeOverhead) * baseFeeScalar * l1BaseFee / 1e18
```

### Intrinsic Gas Requirements
- Minimum gas for transaction execution
- Additional gas for calldata (16 gas per non-zero byte, 4 per zero byte)
- Contract creation overhead if applicable

## Configuration Parameters

### SystemConfig Values
- `maxDelayEnterEnforcedMode`: Time before enforced mode activates (batch delay)
- `maxDelayMessageQueue`: Time before enforced mode activates (message delay)
- `baseFeeOverhead`: Fixed overhead for L2 execution
- `baseFeeScalar`: Multiplier for L1 base fee

### Constants
- Transaction Type: 0x7E (enforced transaction identifier)
- Address Alias Offset: 0x1111000000000000000000000000000000001111

## Events

### EnforcedTxGateway Events
- `Paused(address account)`
- `Unpaused(address account)`

### L1MessageQueueV2 Events
- `QueueTransaction(address indexed sender, address indexed target, uint256 value, uint64 queueIndex, uint256 gasLimit, bytes data)`
- `DequeueTransaction(uint256 startIndex, uint256 count, uint256 skippedBitmap)`

### ScrollChain Events
- `CommitBatch(uint256 indexed batchIndex, bytes32 indexed batchHash)`
- `FinalizeBatch(uint256 indexed batchIndex, bytes32 indexed batchHash, bytes32 stateRoot, bytes32 withdrawRoot)`
- `RevertBatch(uint256 indexed startBatchIndex, uint256 indexed endBatchIndex)`

## Error Messages

### EnforcedTxGateway Errors
- `"Pausable: paused"` - Contract is paused
- `"signature expired"` - Deadline has passed
- `"Incorrect signature"` - Invalid signature or nonce
- `"Insufficient value for fee"` - Not enough ETH sent
- `"Failed to refund the fee"` - Refund transfer failed

### L1MessageQueueV2 Errors
- `ErrorCallerIsNotEnforcedTxGateway()` - Unauthorized caller
- `ErrorInvalidGasLimit()` - Gas limit too low

### ScrollChain Errors
- `ErrorInEnforcedBatchMode()` - Cannot use normal mode functions
- `ErrorTopLevelCallRequired()` - Must be called directly
- `ErrorCallerIsNotSequencer()` - Unauthorized sequencer
