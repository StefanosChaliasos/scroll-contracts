// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageQueueV1} from "../L1/rollup/L1MessageQueueV1.sol";
import {L1MessageQueueV2} from "../L1/rollup/L1MessageQueueV2.sol";
import {ScrollChain, IScrollChain} from "../L1/rollup/ScrollChain.sol";
import {ScrollChainMockBlob} from "../mocks/ScrollChainMockBlob.sol";
import {SystemConfig} from "../L1/system-contract/SystemConfig.sol";
import {BatchHeaderV0Codec} from "../libraries/codec/BatchHeaderV0Codec.sol";
import {BatchHeaderV1Codec} from "../libraries/codec/BatchHeaderV1Codec.sol";
import {BatchHeaderV3Codec} from "../libraries/codec/BatchHeaderV3Codec.sol";
import {BatchHeaderV7Codec} from "../libraries/codec/BatchHeaderV7Codec.sol";
import {ChunkCodecV0} from "../libraries/codec/ChunkCodecV0.sol";
import {ChunkCodecV1} from "../libraries/codec/ChunkCodecV1.sol";
import {EmptyContract} from "../misc/EmptyContract.sol";

import {ScrollChainMockBlob} from "../mocks/ScrollChainMockBlob.sol";
import {MockRollupVerifier} from "./mocks/MockRollupVerifier.sol";

// solhint-disable no-inline-assembly

/// @title PropertyBasedTests
/// @notice Property-based testing for Scroll contracts using Foundry fuzzing
/// @dev This contract tests properties derived from our Alloy formal model
/// 
/// The tests implement property-based testing to verify fundamental invariants:
/// - SRP2 (Monotonic State): The finalized batch index should never decrease
/// 
/// This approach validates that the smart contract implementation maintains
/// the same properties proven in our formal Alloy model.
contract PropertyBasedTests is DSTestPlus {
    
    /*************
     * Constants *
     *************/
    
    // Maximum number of operations in a single fuzz test
    uint256 private constant MAX_OPERATIONS = 30;
    
    // Maximum number of chunks per batch for testing
    uint256 private constant MAX_CHUNKS_PER_BATCH = 10;
    
    /*************
     * Variables *
     *************/
    
    Vm private constant vm = Vm(HEVM_ADDRESS);
    
    ProxyAdmin internal admin;
    EmptyContract private placeholder;

    SystemConfig private system;
    ScrollChain private rollup;
    L1MessageQueueV1 internal messageQueueV1;
    L1MessageQueueV2 internal messageQueueV2;
    MockRollupVerifier internal verifier;
    
    // Track the initial state for property verification
    uint256 private initialFinalizedBatchIndex;
    
    // Track the next batch to commit/finalize for better success rate
    uint256 private nextBatchToCommit = 1;
    uint256 private lastCommittedBatch = 0;
    
    // Store the test EOA for operations
    address private testEOA;
    
    // Store batch headers for finalization (batchIndex => batchHeaderData)
    mapping(uint256 => bytes) private committedBatchHeaders;
    
    // Statistics tracking
    uint256 public totalOperations;
    uint256 public successfulOperations;
    uint256 public failedOperations;
    
    // Operation-specific statistics
    uint256 public commitAttempts;
    uint256 public commitSuccesses;
    uint256 public finalizeAttempts;
    uint256 public finalizeSuccesses;
    uint256 public timeAdvanceAttempts;
    uint256 public timeAdvanceSuccesses;
    
    // Stress test operation statistics
    uint256 public commitAlreadyCommittedAttempts;
    uint256 public commitAlreadyCommittedSuccesses; // should be 0
    uint256 public finalizeFutureAttempts;
    uint256 public finalizeFutureSuccesses; // should be 0
    uint256 public commitFutureAttempts;
    uint256 public commitFutureSuccesses; // should be 0
    uint256 public finalizeAlreadyFinalizedAttempts;
    uint256 public finalizeAlreadyFinalizedSuccesses; // should be 0
    uint256 public revertAttempts;
    uint256 public revertSuccesses;
    
    // Enum for operation types
    enum OperationType {
        CommitBatch,
        FinalizeBatch, 
        AdvanceTime,
        // Stress test operations (expected to fail)
        CommitAlreadyCommitted,
        FinalizeFuture,
        CommitFuture,
        FinalizeAlreadyFinalized,
        RevertBatch
    }
    
    /*************
     * Setup     *
     *************/
    
    function setUp() public {
        placeholder = new EmptyContract();
        admin = new ProxyAdmin();
        system = SystemConfig(_deployProxy(address(0)));
        messageQueueV1 = L1MessageQueueV1(_deployProxy(address(0)));
        messageQueueV2 = L1MessageQueueV2(_deployProxy(address(0)));
        rollup = ScrollChain(_deployProxy(address(0)));
        verifier = new MockRollupVerifier();

        // Upgrade the SystemConfig implementation and initialize
        admin.upgrade(ITransparentUpgradeableProxy(address(system)), address(new SystemConfig()));
        system.initialize(
            address(this),
            address(uint160(1)),
            SystemConfig.MessageQueueParameters({maxGasLimit: 1000000, baseFeeOverhead: 0, baseFeeScalar: 0}),
            SystemConfig.EnforcedBatchParameters({maxDelayEnterEnforcedMode: 86400, maxDelayMessageQueue: 86400})
        );

        // Upgrade the L1MessageQueueV1 implementation and initialize
        admin.upgrade(
            ITransparentUpgradeableProxy(address(messageQueueV1)),
            address(new L1MessageQueueV1(address(this), address(rollup), address(1)))
        );
        messageQueueV1.initialize(address(this), address(rollup), address(0), address(0), 10000000);

        // Upgrade the L1MessageQueueV2 implementation
        admin.upgrade(
            ITransparentUpgradeableProxy(address(messageQueueV2)),
            address(
                new L1MessageQueueV2(
                    address(this),
                    address(rollup),
                    address(1),
                    address(messageQueueV1),
                    address(system)
                )
            )
        );

        // Upgrade to ScrollChainMockBlob for better testing
        admin.upgrade(
            ITransparentUpgradeableProxy(address(rollup)),
            address(
                new ScrollChainMockBlob(
                    233,
                    address(messageQueueV1),
                    address(messageQueueV2),
                    address(verifier),
                    address(1)
                )
            )
        );
        rollup.initialize(address(this), address(this), 1);
        
        // Import genesis batch (use the working format from other tests)
        bytes memory batchHeader = new bytes(89);
        assembly {
            mstore(add(batchHeader, add(0x20, 25)), 1) // set dataHash to non-zero
        }
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));
        
        // Record initial state
        initialFinalizedBatchIndex = rollup.lastFinalizedBatchIndex();
        lastCommittedBatch = 0; // genesis is batch 0
        
        // Add test EOAs as provers and sequencers
        uint256 testPrivateKey = 0x888;
        testEOA = vm.addr(testPrivateKey);
        rollup.addProver(testEOA);
        rollup.addSequencer(testEOA);
    }
    
    function _deployProxy(address _logic) internal returns (address) {
        if (_logic == address(0)) _logic = address(placeholder);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(_logic, address(admin), new bytes(0));
        return address(proxy);
    }
    
    /***********************
     * Property Tests      *
     ***********************/
    
    /// @notice SRP2: Monotonic State Property Test
    /// @dev Tests that finalized batch index never decreases
    /// @param seed Single seed for all operations
    function testFuzz_SRP2_MonotonicState(uint256 seed) external {
        // Reset statistics
        totalOperations = 0;
        successfulOperations = 0;
        failedOperations = 0;
        
        // Reset operation-specific statistics
        commitAttempts = 0;
        commitSuccesses = 0;
        finalizeAttempts = 0;
        finalizeSuccesses = 0;
        timeAdvanceAttempts = 0;
        timeAdvanceSuccesses = 0;
        
        // Reset stress test statistics
        commitAlreadyCommittedAttempts = 0;
        commitAlreadyCommittedSuccesses = 0;
        finalizeFutureAttempts = 0;
        finalizeFutureSuccesses = 0;
        commitFutureAttempts = 0;
        commitFutureSuccesses = 0;
        finalizeAlreadyFinalizedAttempts = 0;
        finalizeAlreadyFinalizedSuccesses = 0;
        revertAttempts = 0;
        revertSuccesses = 0;
        
        // Use 30 operations as requested  
        uint8 numOperations = 30;
        
        uint256 prevFinalizedIndex = rollup.lastFinalizedBatchIndex();
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeFinalized = rollup.lastFinalizedBatchIndex();
            
            // Perform a random valid operation using derived seeds
            _performRandomOperation(uint256(keccak256(abi.encode(seed, i))), i);
            
            // Record state after operation
            uint256 afterFinalized = rollup.lastFinalizedBatchIndex();
            
            // SRP2: Monotonic State Invariant
            // The finalized batch index should never decrease
            assertGe(
                afterFinalized, 
                beforeFinalized, 
                string(abi.encodePacked("SRP2 violated at operation ", i, ": finalized index decreased"))
            );
            
            // Update tracking
            prevFinalizedIndex = afterFinalized;
        }
        
        // Final check: overall monotonicity
        assertGe(
            rollup.lastFinalizedBatchIndex(),
            initialFinalizedBatchIndex,
            "SRP2 violated: final finalized index less than initial"
        );
        
        // Log statistics using emit log (works reliably in Foundry)
        emit log("=== SRP2 Property Test Results (LAST TEST CASE) ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Successful operations", successfulOperations);
        emit log_named_uint("Failed operations", failedOperations);
        if (totalOperations > 0) {
            emit log_named_uint("Success rate %", (successfulOperations * 100) / totalOperations);
        }
        
        // Detailed operation statistics
        emit log("--- Operation Breakdown ---");
        if (commitAttempts > 0) {
            emit log_named_uint("Commit attempts", commitAttempts);
            emit log_named_uint("Commit successes", commitSuccesses);
            emit log_named_uint("Commit success rate %", (commitSuccesses * 100) / commitAttempts);
        }
        if (finalizeAttempts > 0) {
            emit log_named_uint("Finalize attempts", finalizeAttempts);
            emit log_named_uint("Finalize successes", finalizeSuccesses);
            emit log_named_uint("Finalize success rate %", (finalizeSuccesses * 100) / finalizeAttempts);
        }
        if (timeAdvanceAttempts > 0) {
            emit log_named_uint("Time advance attempts", timeAdvanceAttempts);
            emit log_named_uint("Time advance successes", timeAdvanceSuccesses);
            emit log_named_uint("Time advance success rate %", (timeAdvanceSuccesses * 100) / timeAdvanceAttempts);
        }
        
        // Stress test operation statistics
        emit log("--- Stress Test Operations ---");
        if (commitAlreadyCommittedAttempts > 0) {
            emit log_named_uint("CommitAlreadyCommitted attempts", commitAlreadyCommittedAttempts);
            emit log_named_uint("CommitAlreadyCommitted successes (should be 0)", commitAlreadyCommittedSuccesses);
        }
        if (finalizeFutureAttempts > 0) {
            emit log_named_uint("FinalizeFuture attempts", finalizeFutureAttempts);
            emit log_named_uint("FinalizeFuture successes (should be 0)", finalizeFutureSuccesses);
        }
        if (finalizeAlreadyFinalizedAttempts > 0) {
            emit log_named_uint("FinalizeAlreadyFinalized attempts", finalizeAlreadyFinalizedAttempts);
            emit log_named_uint("FinalizeAlreadyFinalized successes (should be 0)", finalizeAlreadyFinalizedSuccesses);
        }
        
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log("=== End Results ===");
        
        // Note: We don't fail the test if no operations succeeded
        // The property test should only fail if SRP2 (monotonicity) is violated
        // Failed operations are logged but don't indicate property violation
    }
    
    /***********************
     * Helper Functions    *
     ***********************/
    
    /// @notice Performs a random valid operation on the ScrollChain
    /// @param seed Random seed for choosing operation type and parameters
    function _performRandomOperation(uint256 seed, uint256 /* operationIndex */) internal {
        totalOperations++;
        
        // Choose operation type with weighted distribution optimized for gas efficiency
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 40) {
            // 40% chance: Normal commit batch
            opType = OperationType.CommitBatch;
        } else if (opWeight < 70) {
            // 30% chance: Normal finalize batch  
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 85) {
            // 15% chance: Time advancement (low gas)
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 92) {
            // 7% chance: Try to commit already committed batch (should fail)
            opType = OperationType.CommitAlreadyCommitted;
        } else if (opWeight < 97) {
            // 5% chance: Try to finalize future batch (should fail)
            opType = OperationType.FinalizeFuture;
        } else {
            // 3% chance: Try to finalize already finalized batch (should fail)
            opType = OperationType.FinalizeAlreadyFinalized;
        }
        
        // Execute the chosen operation
        bool success = false;
        
        if (opType == OperationType.CommitBatch) {
            commitAttempts++;
            success = _commitNextBatch(seed);
            if (success) commitSuccesses++;
        } else if (opType == OperationType.FinalizeBatch) {
            finalizeAttempts++;
            success = _finalizeNextBatch(seed);
            if (success) finalizeSuccesses++;
        } else if (opType == OperationType.AdvanceTime) {
            timeAdvanceAttempts++;
            success = _advanceTime(seed);
            if (success) timeAdvanceSuccesses++;
        } else if (opType == OperationType.CommitAlreadyCommitted) {
            commitAlreadyCommittedAttempts++;
            success = _commitAlreadyCommittedBatch(seed);
            assertFalse(success); // Must fail - cannot commit already committed batch
            if (success) commitAlreadyCommittedSuccesses++;
        } else if (opType == OperationType.FinalizeFuture) {
            finalizeFutureAttempts++;
            success = _finalizeFutureBatch(seed);
            assertFalse(success); // Must fail - cannot finalize out of order
            if (success) finalizeFutureSuccesses++;
        } else if (opType == OperationType.FinalizeAlreadyFinalized) {
            finalizeAlreadyFinalizedAttempts++;
            success = _finalizeAlreadyFinalizedBatch(seed);
            assertFalse(success); // Must fail - cannot finalize already finalized batch
            if (success) finalizeAlreadyFinalizedSuccesses++;
        }
        
        if (success) {
            successfulOperations++;
        } else {
            failedOperations++;
        }
    }
    
    /// @notice Commits the next sequential batch
    function _commitNextBatch(uint256 seed) internal returns (bool success) {
        // Don't try to commit if paused
        if (rollup.paused()) return false;
        
        // Get current state
        (uint64 lastCommittedIndex,,,,) = rollup.miscData();
        bytes32 parentBatchHash = rollup.committedBatches(lastCommittedIndex);
        uint64 newBatchIndex = lastCommittedIndex + 1;
        
        // Set up blob data for v7 batch
        bytes32 blobVersionedHash = keccak256(abi.encode("blob", seed, newBatchIndex));
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        // Create proper V7 batch header and compute hash the same way ScrollChain does
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, newBatchIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        // Compute batch hash the same way ScrollChain does
        bytes32 expectedBatchHash = BatchHeaderV0Codec.computeBatchHash(
            batchPtr,
            BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH
        );
        
        // Store the batch header for later finalization - optimized memory copy
        bytes memory batchHeaderBytes = new bytes(BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH);
        assembly {
            let headerPtr := add(batchHeaderBytes, 0x20)
            let src := batchPtr
            // Copy in 32-byte chunks for efficiency (73 bytes = 2*32 + 9)
            mstore(headerPtr, mload(src))
            mstore(add(headerPtr, 0x20), mload(add(src, 0x20)))
            // Copy remaining 9 bytes more efficiently
            let remaining := mload(add(src, 0x40))
            mstore(add(headerPtr, 0x40), remaining)
        }
        
        vm.startPrank(testEOA);
        try rollup.commitBatches(7, parentBatchHash, expectedBatchHash) {
            vm.stopPrank();
            // Store the batch header for finalization
            committedBatchHeaders[newBatchIndex] = batchHeaderBytes;
            nextBatchToCommit++;
            lastCommittedBatch = uint256(newBatchIndex);
            return true;
        } catch {
            vm.stopPrank();
            return false;
        }
    }
    
    /// @notice Finalizes the next sequential batch that's ready
    function _finalizeNextBatch(uint256 seed) internal returns (bool success) {
        // Don't try to finalize if paused
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        uint64 batchToFinalize = uint64(lastFinalized + 1);
        
        // Check if this batch is committed and we have its header
        if (rollup.committedBatches(batchToFinalize) == bytes32(0)) {
            return false;
        }
        
        bytes memory batchHeader = committedBatchHeaders[batchToFinalize];
        if (batchHeader.length == 0) {
            // No stored header, batch might have been committed in a previous test run
            return false;
        }
        
        // Generate mock finalization data
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, batchToFinalize));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, batchToFinalize));
        bytes memory proof = abi.encode("mockProof", seed);
        
        vm.startPrank(testEOA);
        try rollup.finalizeBundlePostEuclidV2(
            batchHeader,
            0, // totalL1MessagesPoppedOverall
            stateRoot,
            withdrawRoot,
            proof
        ) {
            vm.stopPrank();
            return true;
        } catch {
            vm.stopPrank();
            return false;
        }
    }
    
    /// @notice Commits and then finalizes a batch in sequence
    function _commitAndFinalizeBatch(uint256 seed) internal returns (bool success) {
        // First try to commit
        if (!_commitNextBatch(seed)) {
            return false;
        }
        
        // Then try to finalize the just-committed batch
        return _finalizeNextBatch(seed >> 128); // Use different part of seed
    }
    
    /// @notice Commits multiple batches at once
    function _commitMultipleBatches(uint256 seed) internal returns (bool success) {
        uint256 numBatches = (seed % 3) + 2; // 2-4 batches
        bool anySuccess = false;
        
        for (uint256 i = 0; i < numBatches; i++) {
            if (_commitNextBatch(seed + i)) {
                anySuccess = true;
            }
        }
        
        return anySuccess;
    }
    
    /// @notice Finalizes multiple batches at once
    function _finalizeMultipleBatches(uint256 seed) internal returns (bool success) {
        uint256 numBatches = (seed % 3) + 1; // 1-3 batches
        bool anySuccess = false;
        
        for (uint256 i = 0; i < numBatches; i++) {
            if (_finalizeNextBatch(seed + i)) {
                anySuccess = true;
            }
        }
        
        return anySuccess;
    }
    
    /// @notice Reverts the last committed batch if possible
    function _revertBatch(uint256 seed) internal returns (bool success) {
        // Can only revert if we have committed but not finalized batches
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        if (lastCommittedBatch <= lastFinalized) {
            return false;
        }
        
        // Generate batch header for the batch to keep (one before the last committed)
        bytes memory batchHeader = _generateValidBatchHeaderV7(seed, lastCommittedBatch - 1);
        
        vm.startPrank(address(this)); // Use the test contract as owner
        try rollup.revertBatch(batchHeader) {
            vm.stopPrank();
            // Update our tracking
            lastCommittedBatch--;
            nextBatchToCommit = lastCommittedBatch + 1;
            return true;
        } catch {
            vm.stopPrank();
            return false;
        }
    }
    
    /// @notice Pauses the contract
    function _pause() internal returns (bool success) {
        vm.startPrank(address(this));
        try rollup.setPause(true) {
            vm.stopPrank();
            return true;
        } catch {
            vm.stopPrank();
            return false;
        }
    }
    
    /// @notice Unpauses the contract
    function _unpause() internal returns (bool success) {
        vm.startPrank(address(this));
        try rollup.setPause(false) {
            vm.stopPrank();
            return true;
        } catch {
            vm.stopPrank();
            return false;
        }
    }
    
    /// @notice Advances time to enable different contract behaviors
    function _advanceTime(uint256 seed) internal returns (bool success) {
        uint256 timeToAdvance = (seed % 7200) + 1; // 1 second to 2 hours
        vm.warp(block.timestamp + timeToAdvance);
        return true; // Time advancement always succeeds
    }
    
    /// @notice Generates a simple valid batch header in v7 format - gas optimized
    /// @param seed Random seed for header generation  
    /// @param batchIndex The batch index for the header
    /// @return batchHeader The generated batch header
    function _generateValidBatchHeaderV7(uint256 seed, uint256 batchIndex) internal pure returns (bytes memory) {
        // Use v7 header - 73 bytes as defined in BatchHeaderV7Codec
        bytes memory batchHeader = new bytes(73); // v7 header size
        
        // Optimized assembly to set key fields for v7 format
        assembly {
            let basePtr := add(batchHeader, 0x20)
            
            // Version (1 byte at offset 0) + batch index (8 bytes at offset 1) in one operation
            mstore(basePtr, or(shl(248, 7), shl(192, batchIndex)))
            
            // Blob versioned hash (32 bytes at offset 9) - simplified
            mstore(add(basePtr, 9), xor(seed, batchIndex))
            
            // Parent batch hash (32 bytes at offset 41) - simplified  
            mstore(add(basePtr, 41), xor(seed, sub(batchIndex, 1)))
        }
        
        return batchHeader;
    }
    
    /***********************
     * Stress Test Operations *
     ***********************/
    
    /// @notice Try to commit a batch that's already committed (should fail)
    function _commitAlreadyCommittedBatch(uint256 seed) internal returns (bool success) {
        // Don't try if paused
        if (rollup.paused()) return false;
        
        // Get current state
        (uint64 lastCommittedIndex,,,,) = rollup.miscData();
        
        // If no batches committed yet, can't commit already committed
        if (lastCommittedIndex == 0) {
            return false;
        }
        
        // Try to commit the same batch again (should fail)
        bytes32 parentBatchHash = rollup.committedBatches(lastCommittedIndex - 1);
        uint64 alreadyCommittedIndex = lastCommittedIndex; // This batch is already committed
        
        // Set up blob data
        bytes32 blobVersionedHash = keccak256(abi.encode("blob", seed, alreadyCommittedIndex));
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        // Create batch header for already committed batch
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, alreadyCommittedIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        bytes32 batchHash = BatchHeaderV0Codec.computeBatchHash(
            batchPtr,
            BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH
        );
        
        vm.startPrank(testEOA);
        try rollup.commitBatches(7, parentBatchHash, batchHash) {
            vm.stopPrank();
            // This should not succeed - it's an error if it does
            return true;
        } catch {
            vm.stopPrank();
            // Expected to fail
            return false;
        }
    }
    
    /// @notice Try to finalize a future batch (skipping committed but not finalized batches) - should fail
    function _finalizeFutureBatch(uint256 seed) internal returns (bool success) {
        // Don't try if paused
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        (uint64 lastCommitted,,,,) = rollup.miscData();
        
        // We need at least 2 committed batches ahead of finalized to skip one
        if (lastCommitted <= lastFinalized + 1) {
            return false; // Not enough batches to skip
        }
        
        // Skip the next batch - try to finalize batch (lastFinalized + 2) instead of (lastFinalized + 1)
        uint64 futureBatch = uint64(lastFinalized + 2);
        
        // Generate a mock batch header for the future batch (this should fail in ScrollChain)
        bytes memory batchHeader = _generateValidBatchHeaderV7(seed, futureBatch);
        
        // Generate mock finalization data
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, futureBatch));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, futureBatch));
        bytes memory proof = abi.encode("mockProof", seed);
        
        vm.startPrank(testEOA);
        try rollup.finalizeBundlePostEuclidV2(
            batchHeader,
            0, // totalL1MessagesPoppedOverall
            stateRoot,
            withdrawRoot,
            proof
        ) {
            vm.stopPrank();
            // This should not succeed - Scroll requires sequential finalization
            return true;
        } catch {
            vm.stopPrank();
            // Expected to fail - batches must be finalized in sequential order
            return false;
        }
    }
    
    /// @notice Try to commit a batch several indices ahead (should fail)
    function _commitFutureBatch(uint256 seed) internal returns (bool success) {
        // Don't try if paused
        if (rollup.paused()) return false;
        
        // Get current state
        (uint64 lastCommittedIndex,,,,) = rollup.miscData();
        bytes32 parentBatchHash = rollup.committedBatches(lastCommittedIndex);
        
        // Try to commit a batch that's 2 indices ahead (should fail)
        uint64 futureBatchIndex = lastCommittedIndex + 2;
        
        // Set up blob data
        bytes32 blobVersionedHash = keccak256(abi.encode("blob", seed, futureBatchIndex));
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        // Create batch header for future batch
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, futureBatchIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        bytes32 batchHash = BatchHeaderV0Codec.computeBatchHash(
            batchPtr,
            BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH
        );
        
        vm.startPrank(testEOA);
        try rollup.commitBatches(7, parentBatchHash, batchHash) {
            vm.stopPrank();
            // This should not succeed - it's an error if it does
            return true;
        } catch {
            vm.stopPrank();
            // Expected to fail
            return false;
        }
    }
    
    /// @notice Try to finalize an already finalized batch (should fail)
    function _finalizeAlreadyFinalizedBatch(uint256 seed) internal returns (bool success) {
        // Don't try if paused
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        
        // Need at least one finalized batch to re-finalize
        if (lastFinalized == 0) {
            return false; // No batch to re-finalize
        }
        
        // Pick a random already-finalized batch (from 0 to lastFinalized inclusive)
        uint64 alreadyFinalizedBatch = uint64(lastFinalized == 1 ? 0 : seed % (lastFinalized + 1));
        
        // Use stored batch header if available, otherwise generate one
        bytes memory batchHeader = committedBatchHeaders[alreadyFinalizedBatch];
        if (batchHeader.length == 0) {
            // Fallback to generated header
            batchHeader = _generateValidBatchHeaderV7(seed, alreadyFinalizedBatch);
        }
        
        // Generate mock finalization data
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, alreadyFinalizedBatch));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, alreadyFinalizedBatch));
        bytes memory proof = abi.encode("mockProof", seed);
        
        vm.startPrank(testEOA);
        try rollup.finalizeBundlePostEuclidV2(
            batchHeader,
            0, // totalL1MessagesPoppedOverall
            stateRoot,
            withdrawRoot,
            proof
        ) {
            vm.stopPrank();
            // This should not succeed - batch is already finalized
            return true;
        } catch {
            vm.stopPrank();
            // Expected to fail - cannot finalize an already finalized batch
            return false;
        }
    }
}
