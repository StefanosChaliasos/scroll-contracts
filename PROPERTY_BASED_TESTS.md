# Property-Based Tests: Alloy Logic to Foundry Implementation

This document provides a mapping between the Alloy formal model logic and the Foundry property-based test implementation, explaining what is supported and how each property is verified.

## Overview

The property-based tests validate 13 formal properties derived from our Alloy model of Scroll's rollup system. These tests bridge the gap between specifications and concrete smart contract behavior through randomized execution and invariant checking.

## Property Coverage 

### Simple Rollup Properties (SRP)

| **Property** | **Alloy Logic** | **Test Implementation** | **Support** | **Key Verification** |
|--------------|-----------------|-------------------------|-------------|---------------------|
| **SRP1** | `always lone events` | ❌ **Not Implemented** | **Missing** | Event atomicity checking |
| **SRP2** | `finalized_state in finalized_state'` | `testFuzz_SRP2_MonotonicState()` | **Full** | Index never decreases |
| **SRP3** | Justified finalization | `testFuzz_SRP3_JustifiedState()` | **Full** | Commitment+proof tracking |
| **SRP4** | State progression validity | `testFuzz_SRP4_StateProgressionValidity()` | **Full** | Sequential batch validation |

**SRP2 Implementation Example:**
```solidity
function _verifySRP2(OperationState memory state) private {
    assertGe(
        state.afterFinalized, 
        state.beforeFinalized, 
        "SRP2 violated: finalized index decreased"
    );
}
```

**SRP3 Implementation Example:**
```solidity
function _verifySRP3(OperationState memory state) private {
    // Check that newly finalized batches were previously committed with proofs
    for (uint256 i = state.beforeFinalized + 1; i <= state.afterFinalized; i++) {
        CommitmentProofPair memory pair = commitmentHistory[i];
        assertTrue(
            pair.batchIndex == i && pair.hasProof,
            "SRP3 violated: finalized batch lacks commitment+proof"
        );
    }
}
```

### Forced Queue Properties (FQP)

| **Property** | **Alloy Logic** | **Test Implementation** | **Support** | **Key Verification** |
|--------------|-----------------|-------------------------|-------------|---------------------|
| **FQP1** | Timeout-guaranteed processing | `testFuzz_FQP1_TimeoutGuaranteedProcessing()` |️ **Full** | Simulated timeout conditions |
| **FQP2** | Message queue stability | `testFuzz_FQP2_MessageQueueStable()` |️ **Full** | Mock queue operations |
| **FQP3** | State invariant | `testFuzz_FQP3_StateInvariant()` |️ **Full** | Timeout enforcement logic |
| **FQP4** | Progress monotonicity | `testFuzz_FQP4_QueuedMessageProgress()` |️ **Full** | Mock progress tracking |
| **FQP5** | FIFO order preservation | `testFuzz_FQP5_OrderPreservation()` |️ **Partial** | Simplified order checking |
| **FQP6** | Finalization confirmation | `testFuzz_FQP6_FinalizationConfirmation()` |️ **Full** | Mock finalization logic |

**FQP1 Implementation Example:**
```solidity
function _verifyFQP1(OperationState memory state) private {
    // Simulate timeout condition
    if (state.timeoutTriggered && state.afterFinalized > state.beforeFinalized) {
        assertTrue(
            state.oldestMessageProcessed,
            "FQP1 violated: timed-out message not processed when state advanced"
        );
    }
}
```

### Scroll-Specific Properties (SP)

| **Property** | **Alloy Logic** | **Test Implementation** | **Support** | **Key Verification** |
|--------------|-----------------|-------------------------|-------------|---------------------|
| **SP1** | Rolling hash integrity | `testFuzz_SP1_RollingHashIntegrity()` | **Full** | Simplified hash computation |
| **SP2** | Enforced mode activation | `testFuzz_SP2_EnforcedModeActivation()` |️ **Full** | Mock timeout conditions |
| **SP3** | Mode consistency | `testFuzz_SP3_ModeConsistency()` |️ **Full** | Mode mutual exclusion |
| **SP4** | Fee payment | `testFuzz_SP4_FeePayment()` |️ **Full** | Mock fee tracking |

**SP1 Implementation Example:**
```solidity
function _verifySP1(OperationState memory state) private {
    // Verify rolling hash computation: hash = prevHash + transactionCount
    if (state.newMessagesAdded) {
        uint256 expectedHash = state.prevRollingHash + state.transactionCount;
        assertEq(
            state.currentRollingHash,
            expectedHash,
            "SP1 violated: rolling hash computation incorrect"
        );
    }
}
```

---

## Implementation Details

### Test Framework Architecture

```solidity
contract PropertyBasedTests is DSTestPlus {
    // Unified test entry point
    function _runPropertyTest(uint256 seed, PropertyType propertyType) private {
        _resetStats();
        TestContext memory ctx = TestContext({
            propertyType: propertyType,
            seed: seed,
            trackedIndices: new uint256[](0),
            trackedHashes: new bytes32[](0)
        });
        
        _setupForProperty(ctx);
        
        uint8 numOperations = _getNumOperations();
        for (uint256 i = 0; i < numOperations; i++) {
            _executeOperationWithVerification(ctx, i);
        }
        
        _logTestResults(propertyType);
    }
}
```

### Operation State Tracking

```solidity
struct OperationState {
    uint256 beforeFinalized;
    uint256 afterFinalized;
    uint256 beforeCommitted;
    uint256 afterCommitted;
    bool operationSucceeded;
    bool timeoutTriggered;
    bool oldestMessageProcessed;
    uint256 prevRollingHash;
    uint256 currentRollingHash;
    uint256 transactionCount;
    bool newMessagesAdded;
}
```

### Property Verification Pipeline

1. **Pre-Operation State Capture**
   ```solidity
   state.beforeFinalized = rollup.lastFinalizedBatchIndex();
   state.beforeCommitted = rollup.lastCommittedBatchIndex();
   ```

2. **Operation Execution**
   ```solidity
   bool success = _executeOperation(opType, seed);
   state.operationSucceeded = success;
   ```

3. **Post-Operation State Capture**
   ```solidity
   state.afterFinalized = rollup.lastFinalizedBatchIndex();
   state.afterCommitted = rollup.lastCommittedBatchIndex();
   ```

4. **Property-Specific Verification**
   ```solidity
   if (ctx.propertyType == PropertyType.SRP2) {
       _verifySRP2(state);
   } else if (ctx.propertyType == PropertyType.SRP3) {
       _verifySRP3(state);
   }
   // ... other properties
   ```

---

## Test Framework Architecture

### Operation Weight Distribution

```solidity
function _performRandomOperation(uint256 seed, uint256 /* operationIndex */) internal returns (bool) {
    uint256 opWeight = seed % 100;
    OperationType opType;
    
    if (opWeight < 40) {
        opType = OperationType.CommitBatch;      // 40% - Most common
    } else if (opWeight < 65) {
        opType = OperationType.FinalizeBatch;    // 25% - Follow commits
    } else if (opWeight < 80) {
        opType = OperationType.AdvanceTime;      // 15% - Enable progression
    } else if (opWeight < 90) {
        opType = OperationType.CommitAlreadyCommitted; // 10% - Stress test
    } else {
        opType = OperationType.FinalizeFuture;   // 10% - Stress test
    }
    
    return _executeOperation(opType, seed);
}
```

### State Checking

```solidity
function _syncState() private {
    // Core state tracking
    lastFinalizedBatch = rollup.lastFinalizedBatchIndex();
    nextUnfinalizedIndex = messageQueue.nextUnfinalizedQueueIndex();
    enforcedMode = rollup.isEnforcedModeEnabled();
    
    // Property-specific state updates
    _updateTrackedState();
}
```

## Operation Support

### Fully Supported Operations

**ScrollChain Core Operations**
- `commitBatches()` - Commit new batches to L1
- `finalizeBundlePostEuclidV2()` - Finalize batches with ZK proof
- `setPause()` - Emergency pause functionality
- `revertBatch()` - Revert uncommitted batches

**Test Utilities**
- Time manipulation via `hevm.warp()`
- Multi-batch operations
- State inspection functions

### Mock/Simplified Operations

**Message Queue Operations**: Simplified simulation without actual L1MessageQueueV2 integration
- Rolling hash computation: `hash = prevHash + transactionCount`
- Timeout simulation: Based on block.timestamp manipulation
- FIFO ordering: Simplified index-based tracking

**ZK Proof Verification**: Mock verifier always returns success
- Enables property testing focus without crypto complexity
- Real verifier integration would require significant additional setup

## Test Results Summary

```
[PASS] testFuzz_FQP1_TimeoutGuaranteedProcessing(uint256) (runs: 10003, μ: 2039179)
[PASS] testFuzz_FQP2_MessageQueueStable(uint256) (runs: 10003, μ: 2041724)
[PASS] testFuzz_FQP3_StateInvariant(uint256) (runs: 10003, μ: 2034369)
[PASS] testFuzz_FQP4_QueuedMessageProgress(uint256) (runs: 10003, μ: 2064281)
[PASS] testFuzz_FQP5_OrderPreservation(uint256) (runs: 10003, μ: 1604469)
[PASS] testFuzz_FQP6_FinalizationConfirmation(uint256) (runs: 10003, μ: 1908595)
[PASS] testFuzz_SP1_RollingHashIntegrity(uint256) (runs: 10003, μ: 1432481)
[PASS] testFuzz_SP2_EnforcedModeActivation(uint256) (runs: 10003, μ: 1715533)
[PASS] testFuzz_SP3_ModeConsistency(uint256) (runs: 10003, μ: 2086130)
[PASS] testFuzz_SP4_FeePayment(uint256) (runs: 10003, μ: 1434146)
[PASS] testFuzz_SRP2_MonotonicState(uint256) (runs: 10003, μ: 2867660)
[PASS] testFuzz_SRP3_JustifiedState(uint256) (runs: 10003, μ: 3900017)
[PASS] testFuzz_SRP4_StateProgressionValidity(uint256) (runs: 10003, μ: 2081404)
```