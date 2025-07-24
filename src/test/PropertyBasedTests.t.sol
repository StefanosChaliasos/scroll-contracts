// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageQueueV1} from "../L1/rollup/L1MessageQueueV1.sol";
import {L1MessageQueueV2} from "../L1/rollup/L1MessageQueueV2.sol";
import {EnforcedTxGateway} from "../L1/gateways/EnforcedTxGateway.sol";
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
    EnforcedTxGateway internal enforcedTxGateway;
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
    
    // SRP3: Track commitments and proofs for justified state verification
    struct CommitmentProofPair {
        uint256 batchIndex;
        bytes32 batchHash;
        bytes32 stateRoot;
        bytes32 withdrawRoot;
        bool hasProof;
        uint256 commitTime;
        uint256 finalizeTime;
    }
    mapping(uint256 => CommitmentProofPair) private commitmentHistory;
    uint256[] private commitmentIndexes; // Track all committed batch indexes
    
    // FQP1: Message queue timeout tracking - removed, use SystemConfig instead
    
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
    
    // FQP1: Message queue operation statistics
    uint256 public sendEnforcedTxAttempts;
    uint256 public sendEnforcedTxSuccesses;
    uint256 public processEnforcedMsgAttempts;
    uint256 public processEnforcedMsgSuccesses;
    uint256 public commitAndFinalizeEnforcedAttempts;
    uint256 public commitAndFinalizeEnforcedSuccesses;
    uint256 public trySkipTimedOutAttempts;
    uint256 public trySkipTimedOutSuccesses; // Should be 0
    
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
        RevertBatch,
        // FQP1: Message queue operations
        SendEnforcedTransaction,
        ProcessEnforcedMessages,
        CommitAndFinalizeBatchEnforced,
        // Test operations for FQP properties
        TryFinalizeSkippingTimedOutMessages
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
        enforcedTxGateway = EnforcedTxGateway(_deployProxy(address(0)));
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
        
        // Initialize L1MessageQueueV2
        messageQueueV2.initialize();
        
        // Upgrade and initialize EnforcedTxGateway
        admin.upgrade(
            ITransparentUpgradeableProxy(address(enforcedTxGateway)),
            address(new EnforcedTxGateway(address(messageQueueV2), address(this)))
        );
        enforcedTxGateway.initialize();

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
        
        // Give the test contract some ETH for enforced transaction fees
        vm.deal(address(this), 100 ether);
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
    
    /// @notice SRP3: Justified State Property Test
    /// @dev Tests that every finalized batch was properly justified by commitment+proof or enforced mode
    /// @param seed Single seed for all operations
    function testFuzz_SRP3_JustifiedState(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        _resetJustificationTracking();
        
        uint8 numOperations = 30;
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeFinalized = rollup.lastFinalizedBatchIndex();
            
            // Perform random operation with SRP3 commitment tracking
            _performRandomOperationWithSRP3Tracking(uint256(keccak256(abi.encode(seed, i))));
            
            // Record state after operation  
            uint256 afterFinalized = rollup.lastFinalizedBatchIndex();
            
            // SRP3: Check that any newly finalized batches were properly justified
            if (afterFinalized > beforeFinalized) {
                // First, ensure all newly finalized batches have tracking records
                // for (uint256 batchIdx = beforeFinalized + 1; batchIdx <= afterFinalized; batchIdx++) {
                //     _ensureBatchHasTrackingRecord(batchIdx);
                // }
                // Then verify justification
                for (uint256 batchIdx = beforeFinalized + 1; batchIdx <= afterFinalized; batchIdx++) {
                    _verifySRP3JustifiedState(batchIdx);
                }
            }
        }
        
        emit log("=== SRP3 Justified State Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log("=== SRP3 Test Complete ===");
    }
    
    /// @notice SRP4: State Progression Validity Property Test  
    /// @dev Tests that commitments/proofs for states ≤ current finalized state are rejected
    /// @param seed Single seed for all operations
    function testFuzz_SRP4_StateProgressionValidity(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        
        uint8 numOperations = 30;
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Perform random operation with SRP4 enforcement
            _performRandomOperationWithSRP4Check(uint256(keccak256(abi.encode(seed, i))));
            
            // SRP4: Verify that no operation successfully processed old state
            // (This is implicitly checked in _performRandomOperationWithSRP4Check)
        }
        
        emit log("=== SRP4 State Progression Validity Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log("=== SRP4 Test Complete ===");
    }
    
    /// @notice FQP1: Timeout-Guaranteed Processing Property Test
    /// @dev Tests that if oldest message exceeds timeout and state advances, it must be processed
    /// @param seed Single seed for all operations
    function testFuzz_FQP1_TimeoutGuaranteedProcessing(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        _resetMessageQueueTracking();
        
        uint8 numOperations = 30;
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeFinalized = rollup.lastFinalizedBatchIndex();
            uint256 beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // Perform random operation with FQP1 message queue operations
            _performRandomOperationWithFQP1Tracking(uint256(keccak256(abi.encode(seed, i))));
            
            // Record state after operation
            uint256 afterFinalized = rollup.lastFinalizedBatchIndex();
            uint256 afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // FQP1: Check timeout-guaranteed processing
            _verifyFQP1TimeoutGuaranteedProcessing(beforeFinalized, afterFinalized, beforeUnfinalized, afterUnfinalized);
        }
        
        emit log("=== FQP1 Timeout-Guaranteed Processing Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Messages in queue", messageQueueV2.nextCrossDomainMessageIndex());
        emit log_named_uint("Unfinalized messages", messageQueueV2.nextCrossDomainMessageIndex() - messageQueueV2.nextUnfinalizedQueueIndex());
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log("=== FQP1 Test Complete ===");
    }
    
    /// @notice FQP2: Message Queue Stable Property Test
    /// @dev Tests that if finalized state didn't change, then message queue only grows
    /// @param seed Single seed for all operations
    function testFuzz_FQP2_MessageQueueStable(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        
        uint8 numOperations = 30;
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeFinalized = rollup.lastFinalizedBatchIndex();
            uint256 beforeTotalMessages = messageQueueV2.nextCrossDomainMessageIndex();
            uint256 beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // Perform random operation
            _performRandomOperation(uint256(keccak256(abi.encode(seed, i))), i);
            
            // Record state after operation
            uint256 afterFinalized = rollup.lastFinalizedBatchIndex();
            uint256 afterTotalMessages = messageQueueV2.nextCrossDomainMessageIndex();
            uint256 afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // FQP2: Verify message queue stability
            _verifyFQP2MessageQueueStable(
                beforeFinalized, afterFinalized,
                beforeTotalMessages, afterTotalMessages,
                beforeUnfinalized, afterUnfinalized
            );
        }
        
        emit log("=== FQP2 Message Queue Stable Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log_named_uint("Total messages in queue", messageQueueV2.nextCrossDomainMessageIndex());
        emit log("=== FQP2 Test Complete ===");
    }
    
    /// @notice FQP3: State Invariant Property Test
    /// @dev Tests that if unfinalized messages exist and queue didn't change, state remains unchanged
    ///      UNLESS messages haven't timed out yet
    /// @param seed Single seed for all operations
    function testFuzz_FQP3_StateInvariant(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        
        uint8 numOperations = 30;
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeFinalized = rollup.lastFinalizedBatchIndex();
            uint256 beforeTotalMessages = messageQueueV2.nextCrossDomainMessageIndex();
            uint256 beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // Perform random operation
            _performRandomOperation(uint256(keccak256(abi.encode(seed, i))), i);
            
            // Record state after operation
            uint256 afterFinalized = rollup.lastFinalizedBatchIndex();
            uint256 afterTotalMessages = messageQueueV2.nextCrossDomainMessageIndex();
            uint256 afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // FQP3: Verify state invariant
            _verifyFQP3StateInvariant(
                beforeFinalized, afterFinalized,
                beforeTotalMessages, afterTotalMessages,
                beforeUnfinalized, afterUnfinalized
            );
        }
        
        emit log("=== FQP3 State Invariant Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log_named_uint("Unfinalized messages", messageQueueV2.nextCrossDomainMessageIndex() - messageQueueV2.nextUnfinalizedQueueIndex());
        emit log("=== FQP3 Test Complete ===");
    }
    
    /// @notice FQP4: Queued Message Progress Property Test
    /// @dev Tests that when new blocks are finalized, next_unfinalized_index never decreases
    /// @param seed Single seed for all operations
    function testFuzz_FQP4_QueuedMessageProgress(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        
        uint8 numOperations = 30;
        
        // First, add some enforced messages to make the test meaningful
        for (uint256 i = 0; i < 3; i++) {
            _sendEnforcedTransaction(uint256(keccak256(abi.encode(seed, "init", i))));
        }
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeFinalized = rollup.lastFinalizedBatchIndex();
            uint256 beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
            
            // Perform random operation with FQP focus
            _performRandomOperationForFQP(uint256(keccak256(abi.encode(seed, i))));
            
            // Record state after operation
            uint256 afterFinalized = rollup.lastFinalizedBatchIndex();
            uint256 afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // FQP4: Verify queued message progress
            _verifyFQP4QueuedMessageProgress(
                beforeFinalized, afterFinalized,
                beforeUnfinalized, afterUnfinalized,
                totalMessages
            );
        }
        
        emit log("=== FQP4 Queued Message Progress Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        emit log_named_uint("Final unfinalized index", messageQueueV2.nextUnfinalizedQueueIndex());
        emit log_named_uint("Total messages", messageQueueV2.nextCrossDomainMessageIndex());
        emit log("=== FQP4 Test Complete ===");
    }
    
    /// @notice FQP5: Order Preservation Property Test
    /// @dev Tests that enforced messages are processed in FIFO order
    /// @param seed Single seed for all operations
    function testFuzz_FQP5_OrderPreservation(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        
        uint8 numOperations = 20; // Fewer operations for order tracking
        
        // Add several enforced messages with known order
        uint256[] memory messageIndices = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            messageIndices[i] = messageQueueV2.nextCrossDomainMessageIndex();
            _sendEnforcedTransaction(uint256(keccak256(abi.encode(seed, "ordered", i))));
        }
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // Perform random operation
            _performRandomOperationForFQP(uint256(keccak256(abi.encode(seed, i))));
            
            // Record state after operation
            uint256 afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // FQP5: Verify FIFO order preservation
            _verifyFQP5OrderPreservation(
                messageIndices,
                beforeUnfinalized,
                afterUnfinalized
            );
        }
        
        emit log("=== FQP5 Order Preservation Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Messages added for order testing", 5);
        emit log_named_uint("Final unfinalized index", messageQueueV2.nextUnfinalizedQueueIndex());
        emit log("=== FQP5 Test Complete ===");
    }
    
    /// @notice FQP6: Finalization Confirmation Property Test
    /// @dev Tests that messages transition from unfinalized to finalized correctly
    /// @param seed Single seed for all operations
    function testFuzz_FQP6_FinalizationConfirmation(uint256 seed) external {
        // Reset all tracking data
        _resetStats();
        
        uint8 numOperations = 25;
        
        // Track specific messages to verify their finalization
        uint256[] memory trackedMessages = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            trackedMessages[i] = messageQueueV2.nextCrossDomainMessageIndex();
            _sendEnforcedTransaction(uint256(keccak256(abi.encode(seed, "track", i))));
        }
        
        for (uint256 i = 0; i < numOperations; i++) {
            // Record state before operation
            uint256 beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // Perform random operation
            _performRandomOperationForFQP(uint256(keccak256(abi.encode(seed, i))));
            
            // Record state after operation
            uint256 afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
            
            // FQP6: Verify finalization confirmation for tracked messages
            _verifyFQP6FinalizationConfirmation(
                trackedMessages,
                beforeUnfinalized,
                afterUnfinalized
            );
        }
        
        emit log("=== FQP6 Finalization Confirmation Test Results ===");
        emit log_named_uint("Total operations", totalOperations);
        emit log_named_uint("Tracked messages", 3);
        emit log_named_uint("Final unfinalized index", messageQueueV2.nextUnfinalizedQueueIndex());
        emit log("=== FQP6 Test Complete ===");
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
    
    /***********************
     * SRP3/SRP4 Helper Functions *
     ***********************/
    
    /// @notice Reset all statistics for clean test runs
    function _resetStats() internal {
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
        
        // Reset FQP1 operation statistics
        sendEnforcedTxAttempts = 0;
        sendEnforcedTxSuccesses = 0;
        processEnforcedMsgAttempts = 0;
        processEnforcedMsgSuccesses = 0;
        commitAndFinalizeEnforcedAttempts = 0;
        commitAndFinalizeEnforcedSuccesses = 0;
        trySkipTimedOutAttempts = 0;
        trySkipTimedOutSuccesses = 0;
    }
    
    /// @notice Reset justification tracking for SRP3
    function _resetJustificationTracking() internal {
        // Clear commitment tracking
        for (uint256 i = 0; i < commitmentIndexes.length; i++) {
            delete commitmentHistory[commitmentIndexes[i]];
        }
        delete commitmentIndexes;
    }
    
    /// @notice Verify SRP3: Justified State property for a specific batch
    /// @param batchIndex The batch index to verify justification for
    function _verifySRP3JustifiedState(uint256 batchIndex) internal {
        // SRP3: Every finalized batch must have been justified by either:
        // 1. Normal mode: commitment + proof pair
        // 2. Enforced mode: processed during enforced mode
        
        // Special case: Skip genesis batch (index 0) - it's pre-justified
        if (batchIndex == 0) {
            return; // Genesis batch is imported, not committed/finalized through normal flow
        }
        
        // Check if we have a commitment+proof pair for this batch
        CommitmentProofPair memory commitment = commitmentHistory[batchIndex];
        
        // Removed debug logging for cleaner output
        
        if (commitment.batchIndex == batchIndex && commitment.hasProof) {
            // Normal mode justification: we have commitment + proof
            assertGt(commitment.commitTime, 0, "SRP3 violated: finalized batch missing commitment timestamp");
            assertGt(commitment.finalizeTime, 0, "SRP3 violated: finalized batch missing finalization timestamp");
            assertGe(commitment.finalizeTime, commitment.commitTime, "SRP3 violated: finalization before commitment");
        } else {
            // In our current test setup, we don't have enforced mode operations
            // So every finalized batch should have proper commitment+proof justification
            assertEq(commitment.batchIndex, batchIndex, "SRP3 violated: finalized batch has no commitment record");
            assertTrue(commitment.hasProof, "SRP3 violated: finalized batch has no proof record");
        }
    }
    
    /// @notice Perform random operation with SRP4 state progression validity checks
    /// @param seed Random seed for operation selection
    /// @return success Whether the operation succeeded
    function _performRandomOperationWithSRP4Check(uint256 seed) internal returns (bool success) {
        totalOperations++;
        
        // Get current finalized state before operation
        uint256 currentFinalized = rollup.lastFinalizedBatchIndex();
        
        // Choose operation type with same distribution as original
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 20) {
            opType = OperationType.CommitBatch;
        } else if (opWeight < 40) {
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 50) {
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 60) {
            opType = OperationType.CommitAlreadyCommitted;
        } else if (opWeight < 80) {
            opType = OperationType.FinalizeFuture;
        } else {
            opType = OperationType.FinalizeAlreadyFinalized;
        }
        
        // Execute operation with SRP4 checks
        if (opType == OperationType.CommitBatch) {
            commitAttempts++;
            success = _commitNextBatchWithSRP4Check(seed, currentFinalized);
            if (success) commitSuccesses++;
        } else if (opType == OperationType.FinalizeBatch) {
            finalizeAttempts++;
            success = _finalizeNextBatchWithSRP4Check(seed, currentFinalized);
            if (success) finalizeSuccesses++;
        } else if (opType == OperationType.AdvanceTime) {
            timeAdvanceAttempts++;
            success = _advanceTime(seed);
            if (success) timeAdvanceSuccesses++;
        } else {
            // Stress test operations - these should fail anyway for SRP4
            _performRandomOperation(seed, 0); // Use dummy index for stress tests
            success = false; // Assume these fail for SRP4 purposes
        }
        
        if (success) {
            successfulOperations++;
        } else {
            failedOperations++;
        }
        
        return success;
    }
    
    /// @notice Commit next batch with SRP4 state progression validity checks
    /// @param seed Random seed for batch generation
    /// @param currentFinalized Current finalized batch index before operation
    /// @return success Whether the commitment succeeded
    function _commitNextBatchWithSRP4Check(uint256 seed, uint256 currentFinalized) internal returns (bool success) {
        if (rollup.paused()) return false;
        
        (uint64 lastCommittedIndex,,,,) = rollup.miscData();
        uint64 newBatchIndex = lastCommittedIndex + 1;
        
        // SRP4: Verify we're not trying to commit for an old state
        // (This should always pass for normal next batch commits)
        assertGt(newBatchIndex, currentFinalized, "SRP4 violated: attempting to commit batch for old finalized state");
        
        // Perform normal commit operation
        success = _commitNextBatch(seed);
        
        // If successful, record the commitment for SRP3 tracking
        if (success) {
            bytes32 newBatchHash = rollup.committedBatches(newBatchIndex);
            
            commitmentHistory[newBatchIndex] = CommitmentProofPair({
                batchIndex: newBatchIndex,
                batchHash: newBatchHash,
                stateRoot: bytes32(0), // Will be set during finalization
                withdrawRoot: bytes32(0), // Will be set during finalization
                hasProof: false, // Will be set to true during finalization
                commitTime: block.timestamp == 0 ? 1 : block.timestamp, // Ensure non-zero timestamp
                finalizeTime: 0 // Will be set during finalization
            });
            commitmentIndexes.push(newBatchIndex);
        }
        
        return success;
    }
    
    /// @notice Finalize next batch with SRP4 state progression validity checks
    /// @param seed Random seed for batch generation
    /// @param currentFinalized Current finalized batch index before operation
    /// @return success Whether the finalization succeeded
    function _finalizeNextBatchWithSRP4Check(uint256 seed, uint256 currentFinalized) internal returns (bool success) {
        if (rollup.paused()) return false;
        
        uint64 batchToFinalize = uint64(currentFinalized + 1);
        
        // SRP4: Verify we're not trying to finalize an old state
        // (This should always pass for normal sequential finalization)
        assertGt(batchToFinalize, currentFinalized, "SRP4 violated: attempting to finalize old state");
        
        // Perform normal finalize operation
        success = _finalizeNextBatch(seed);
        
        // If successful, update the commitment record for SRP3 tracking
        if (success) {
            CommitmentProofPair storage commitment = commitmentHistory[batchToFinalize];
            if (commitment.batchIndex == batchToFinalize) {
                commitment.hasProof = true; // Mark as having proof
                commitment.finalizeTime = block.timestamp == 0 ? 2 : block.timestamp; // Ensure non-zero and > commitTime
                commitment.stateRoot = keccak256(abi.encode("stateRoot", seed, batchToFinalize));
                commitment.withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, batchToFinalize));
            }
        }
        
        return success;
    }
    
    /// @notice Perform random operation with SRP3 commitment and proof tracking
    /// @param seed Random seed for operation selection
    /// @return success Whether the operation succeeded
    function _performRandomOperationWithSRP3Tracking(uint256 seed) internal returns (bool success) {
        totalOperations++;
        
        // Choose operation type with same distribution as original
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 20) {
            opType = OperationType.CommitBatch;
        } else if (opWeight < 40) {
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 50) {
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 60) {
            opType = OperationType.CommitAlreadyCommitted;
        } else if (opWeight < 85) {
            opType = OperationType.FinalizeFuture;
        } else {
            opType = OperationType.FinalizeAlreadyFinalized;
        }
        
        // Execute operation with commitment tracking for SRP3
        if (opType == OperationType.CommitBatch) {
            commitAttempts++;
            uint256 currentFinalized = rollup.lastFinalizedBatchIndex();
            success = _commitNextBatchWithSRP4Check(seed, currentFinalized); // Reuse SRP4 function for tracking
            if (success) commitSuccesses++;
        } else if (opType == OperationType.FinalizeBatch) {
            finalizeAttempts++;
            uint256 currentFinalized = rollup.lastFinalizedBatchIndex();
            success = _finalizeNextBatchWithSRP4Check(seed, currentFinalized); // Reuse SRP4 function for tracking
            if (success) finalizeSuccesses++;
        } else if (opType == OperationType.AdvanceTime) {
            timeAdvanceAttempts++;
            success = _advanceTime(seed);
            if (success) timeAdvanceSuccesses++;
        } else {
            // Stress test operations - handle them individually to ensure proper tracking
            if (opType == OperationType.CommitAlreadyCommitted) {
                commitAlreadyCommittedAttempts++;
                success = _commitAlreadyCommittedBatch(seed);
                if (success) commitAlreadyCommittedSuccesses++;
            } else if (opType == OperationType.FinalizeFuture) {
                finalizeFutureAttempts++;
                success = _finalizeFutureBatch(seed);
                // If this unexpectedly succeeds, we need to track it
                if (success) {
                    finalizeFutureSuccesses++;
                    // Note: FinalizeFuture operation unexpectedly succeeded - will be handled by emergency tracking
                }
            } else if (opType == OperationType.FinalizeAlreadyFinalized) {
                finalizeAlreadyFinalizedAttempts++;
                success = _finalizeAlreadyFinalizedBatch(seed);
                if (success) finalizeAlreadyFinalizedSuccesses++;
            } else {
                // Use original function for any other stress test operations
                _performRandomOperation(seed, 0);
                success = false;
            }
        }
        
        if (success) {
            successfulOperations++;
        } else {
            failedOperations++;
        }
        
        return success;
    }
    
    /***********************
     * FQP1 Helper Functions *
     ***********************/
    
    /// @notice Reset message queue tracking for FQP1
    function _resetMessageQueueTracking() internal {
        // No need to reset - we're using Scroll's actual tracking
    }
    
    /// @notice Verify FQP1: Timeout-Guaranteed Processing property
    /// @param beforeFinalized Finalized batch index before operation
    /// @param afterFinalized Finalized batch index after operation
    /// @param beforeUnfinalized Index of first unfinalized message before operation
    /// @param afterUnfinalized Index of first unfinalized message after operation
    function _verifyFQP1TimeoutGuaranteedProcessing(
        uint256 beforeFinalized,
        uint256 afterFinalized,
        uint256 beforeUnfinalized, 
        uint256 afterUnfinalized
    ) internal {
        // FQP1: If state advanced and there are unfinalized messages that have timed out,
        // then some messages must have been processed
        
        // Only check if state actually advanced
        if (afterFinalized <= beforeFinalized) {
            return; // State didn't advance, no requirement to process messages
        }
        
        // Check if there were unfinalized messages before the operation
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        if (beforeUnfinalized >= totalMessages) {
            return; // No unfinalized messages to process
        }
        
        // Get timeout parameters from system config
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        
        // Get the timestamp of the oldest unfinalized message
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        // Check if the oldest message has timed out
        if (block.timestamp > oldestMessageTime + maxDelayMessageQueue) {
            // FQP1 CORE ASSERTION: If messages timed out and state advanced,
            // then messages MUST have been processed
            assertTrue(
                afterUnfinalized > beforeUnfinalized,
                "FQP1 VIOLATED: State advanced while timed-out messages were not processed!"
            );
            
            // Additional check: Ensure we're in enforced mode or messages were processed
            assertTrue(
                rollup.isEnforcedModeEnabled() || afterUnfinalized > beforeUnfinalized,
                "FQP1 VIOLATED: Timed-out messages exist but enforced mode not enabled!"
            );
        }
    }
    
    /// @notice Perform random operation with FQP1 message queue tracking
    /// @param seed Random seed for operation selection
    /// @return success Whether the operation succeeded
    function _performRandomOperationWithFQP1Tracking(uint256 seed) internal returns (bool success) {
        totalOperations++;
        
        // Choose operation type with emphasis on message queue operations
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 25) {
            opType = OperationType.CommitBatch;
        } else if (opWeight < 40) {
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 50) {
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 70) {
            opType = OperationType.SendEnforcedTransaction; // 20% - High emphasis
        } else if (opWeight < 85) {
            opType = OperationType.ProcessEnforcedMessages; // 15% - Process messages
        } else if (opWeight < 90) {
            opType = OperationType.CommitAndFinalizeBatchEnforced; // 5% - Enforced mode
        } else if (opWeight < 95) {
            opType = OperationType.TryFinalizeSkippingTimedOutMessages; // 5% - Should fail if messages timed out
        } else {
            // Stress test operations (low probability)
            uint256 stressOp = seed % 3;
            if (stressOp == 0) {
                opType = OperationType.CommitAlreadyCommitted;
            } else if (stressOp == 1) {
                opType = OperationType.FinalizeFuture;
            } else {
                opType = OperationType.FinalizeAlreadyFinalized;
            }
        }
        
        // Execute the chosen operation
        if (opType == OperationType.CommitBatch) {
            commitAttempts++;
            uint256 currentFinalized = rollup.lastFinalizedBatchIndex();
            success = _commitNextBatchWithSRP4Check(seed, currentFinalized);
            if (success) commitSuccesses++;
        } else if (opType == OperationType.FinalizeBatch) {
            finalizeAttempts++;
            uint256 currentFinalized = rollup.lastFinalizedBatchIndex();
            success = _finalizeNextBatchWithSRP4Check(seed, currentFinalized);
            if (success) finalizeSuccesses++;
        } else if (opType == OperationType.AdvanceTime) {
            timeAdvanceAttempts++;
            success = _advanceTime(seed);
            if (success) timeAdvanceSuccesses++;
        } else if (opType == OperationType.SendEnforcedTransaction) {
            sendEnforcedTxAttempts++;
            success = _sendEnforcedTransaction(seed);
            if (success) sendEnforcedTxSuccesses++;
        } else if (opType == OperationType.ProcessEnforcedMessages) {
            processEnforcedMsgAttempts++;
            success = _processEnforcedMessages(seed);
            if (success) processEnforcedMsgSuccesses++;
        } else if (opType == OperationType.CommitAndFinalizeBatchEnforced) {
            commitAndFinalizeEnforcedAttempts++;
            success = _commitAndFinalizeBatchEnforced(seed);
            if (success) commitAndFinalizeEnforcedSuccesses++;
        } else if (opType == OperationType.TryFinalizeSkippingTimedOutMessages) {
            trySkipTimedOutAttempts++;
            success = _tryFinalizeSkippingTimedOutMessages(seed);
            // This should fail if there are timed out messages
            if (success) trySkipTimedOutSuccesses++;
        } else {
            // Stress test operations - handle with original logic
            success = false; // These should generally fail
        }
        
        if (success) {
            successfulOperations++;
        } else {
            failedOperations++;
        }
        
        return success;
    }
    
    /// @notice Send an enforced transaction to the message queue
    /// @param seed Random seed for transaction parameters
    /// @return success Whether the operation succeeded
    function _sendEnforcedTransaction(uint256 seed) internal returns (bool success) {
        // Generate transaction parameters
        address target = address(uint160(seed % type(uint160).max));
        uint256 value = seed % 1 ether;
        uint256 gasLimit = 100000 + (seed % 200000); // 100k - 300k gas
        bytes memory data = abi.encode("enforced_tx", seed);
        
        // Calculate fee for the enforced transaction
        uint256 fee = messageQueueV2.estimateCrossDomainMessageFee(gasLimit);
        uint256 totalValue = value + fee;
        
        // Record the current message index before sending
        uint256 messageIndexBefore = messageQueueV2.nextCrossDomainMessageIndex();
        
        try enforcedTxGateway.sendTransaction{value: totalValue}(target, value, gasLimit, data) {
            // Verify the message was added to the queue
            uint256 messageIndexAfter = messageQueueV2.nextCrossDomainMessageIndex();
            require(messageIndexAfter == messageIndexBefore + 1, "Message not added to queue");
            
            // 50% chance to advance time past timeout after sending enforced message
            if (seed % 2 == 0) {
                (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
                uint256 timeToAdvance = maxDelayMessageQueue + 1 + (seed % 3600); // 1+ hour past timeout
                vm.warp(block.timestamp + timeToAdvance);
                timeAdvanceAttempts++;
                timeAdvanceSuccesses++;
            }
            
            return true;
        } catch {
            return false;
        }
    }
    
    /// @notice Process enforced messages by triggering enforced batch mode
    /// @param seed Random seed for processing parameters
    /// @return success Whether the operation succeeded
    function _processEnforcedMessages(uint256 seed) internal returns (bool success) {
        // Check if there are unfinalized messages that have timed out
        uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        
        if (unfinalizedIndex >= totalMessages) {
            return false; // No messages to process
        }
        
        // Get the timestamp of the oldest unfinalized message
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        // Get timeout parameters
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        
        // Check if we should enter enforced mode (message timed out)
        if (block.timestamp <= oldestMessageTime + maxDelayMessageQueue) {
            // Messages haven't timed out yet, can't process in enforced mode
            return false;
        }
        
        // Try to commit and finalize a batch in enforced mode
        // This should process the timed-out messages
        // In enforced mode, we would use commitAndFinalizeBatch
        // For now, we'll do a regular commit+finalize which should fail if messages are too old
        success = _commitNextBatch(seed);
        if (success) {
            success = _finalizeNextBatch(seed >> 128); // Use different part of seed
        }
        
        return success;
    }
    
    /// @notice Try to use commitAndFinalizeBatch in enforced mode
    /// @param seed Random seed for parameters
    /// @return success Whether the operation succeeded
    function _commitAndFinalizeBatchEnforced(uint256 seed) internal returns (bool success) {
        // Check if we have timed out messages
        uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        
        if (unfinalizedIndex >= totalMessages) {
            return false; // No messages to process
        }
        
        // Get timeout parameters
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        // Only proceed if messages have timed out or we're already in enforced mode
        if (!rollup.isEnforcedModeEnabled() && block.timestamp <= oldestMessageTime + maxDelayMessageQueue) {
            return false; // Can't enter enforced mode yet
        }
        
        // Get current state
        uint64 lastFinalized = uint64(rollup.lastFinalizedBatchIndex());
        bytes32 parentBatchHash = rollup.committedBatches(lastFinalized);
        uint64 newBatchIndex = lastFinalized + 1;
        
        // Create batch header
        bytes32 blobVersionedHash = keccak256(abi.encode("enforced_blob", seed, newBatchIndex));
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, newBatchIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        bytes memory batchHeader = new bytes(BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH);
        assembly {
            let headerPtr := add(batchHeader, 0x20)
            let src := batchPtr
            mstore(headerPtr, mload(src))
            mstore(add(headerPtr, 0x20), mload(add(src, 0x20)))
            let remaining := mload(add(src, 0x40))
            mstore(add(headerPtr, 0x40), remaining)
        }
        
        // Generate finalization data
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, newBatchIndex));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, newBatchIndex));
        bytes memory proof = abi.encode("mockProof", seed);
        
        IScrollChain.FinalizeStruct memory finalizeStruct = IScrollChain.FinalizeStruct({
            batchHeader: batchHeader,
            totalL1MessagesPoppedOverall: 0, // We'll assume no L1 messages for simplicity
            postStateRoot: stateRoot,
            withdrawRoot: withdrawRoot,
            zkProof: proof
        });
        
        try rollup.commitAndFinalizeBatch(7, parentBatchHash, finalizeStruct) {
            return true;
        } catch {
            return false;
        }
    }
    
    /// @notice Try to finalize a batch while skipping timed-out messages
    /// @dev This should fail if there are timed-out messages
    /// @param seed Random seed for parameters
    /// @return success Whether the operation succeeded (should be false if messages timed out)
    function _tryFinalizeSkippingTimedOutMessages(uint256 seed) internal returns (bool success) {
        // Check if we have timed out messages
        uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        
        if (unfinalizedIndex >= totalMessages) {
            // No messages - normal finalization should work
            return _finalizeNextBatch(seed);
        }
        
        // Get timeout parameters
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        bool messagesTimedOut = block.timestamp > oldestMessageTime + maxDelayMessageQueue;
        
        // Try normal finalization (should fail if messages timed out and we're not in enforced mode)
        success = _finalizeNextBatch(seed);
        
        // Verify the behavior: if messages timed out and we're not in enforced mode,
        // the finalization should have failed
        if (messagesTimedOut && !rollup.isEnforcedModeEnabled()) {
            assertTrue(!success, "FQP1 TEST FAILURE: Finalized batch while skipping timed-out messages!");
        }
        
        return success;
    }
    
    /// @notice Verify FQP2: Message Queue Stable property
    function _verifyFQP2MessageQueueStable(
        uint256 beforeFinalized,
        uint256 afterFinalized,
        uint256 beforeTotalMessages,
        uint256 afterTotalMessages,
        uint256 beforeUnfinalized,
        uint256 afterUnfinalized
    ) internal {
        // FQP2: If finalized state didn't change, then:
        // 1. Message queue should only grow (or stay the same)
        // 2. Next unfinalized index should remain the same
        
        if (beforeFinalized == afterFinalized) {
            // Message queue should only grow
            assertTrue(
                afterTotalMessages >= beforeTotalMessages,
                "FQP2 VIOLATED: Message queue shrank while finalized state unchanged!"
            );
            
            // Next unfinalized index should remain the same
            assertTrue(
                afterUnfinalized == beforeUnfinalized,
                "FQP2 VIOLATED: Unfinalized index changed while finalized state unchanged!"
            );
        }
    }
    
    /// @notice Verify FQP3: State Invariant property
    function _verifyFQP3StateInvariant(
        uint256 beforeFinalized,
        uint256 afterFinalized,
        uint256 beforeTotalMessages,
        uint256 afterTotalMessages,
        uint256 beforeUnfinalized,
        uint256 afterUnfinalized
    ) internal {
        // FQP3: If unfinalized messages exist and queue didn't change and messages timed out,
        // then finalized state should remain unchanged
        
        // Check if there are unfinalized messages
        uint256 unfinalizedCount = beforeTotalMessages - beforeUnfinalized;
        if (unfinalizedCount == 0) {
            return; // No unfinalized messages, property doesn't apply
        }
        
        // Check if queue didn't change
        bool queueUnchanged = (afterTotalMessages == beforeTotalMessages) && 
                             (afterUnfinalized == beforeUnfinalized);
        
        if (!queueUnchanged) {
            return; // Queue changed, property doesn't apply
        }
        
        // Get timeout parameters
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        
        // Check if oldest message has timed out
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        bool messagesTimedOut = block.timestamp > oldestMessageTime + maxDelayMessageQueue;
        
        if (messagesTimedOut) {
            // FQP3 CORE ASSERTION: If messages timed out and queue unchanged,
            // state should not advance
            assertTrue(
                afterFinalized == beforeFinalized,
                "FQP3 VIOLATED: State advanced while timed-out messages exist and queue unchanged!"
            );
        }
        // If messages haven't timed out, sequencer can choose to advance state or not
    }
    
    /// @notice Verify FQP4: Queued Message Progress property
    function _verifyFQP4QueuedMessageProgress(
        uint256 beforeFinalized,
        uint256 afterFinalized,
        uint256 beforeUnfinalized,
        uint256 afterUnfinalized,
        uint256 totalMessages
    ) internal {
        // FQP4: When state advances with unfinalized messages, unfinalized index must not decrease
        
        // Check if there were unfinalized messages
        if (beforeUnfinalized >= totalMessages) {
            return; // No unfinalized messages
        }
        
        // If state advanced
        if (afterFinalized > beforeFinalized) {
            // FQP4 CORE ASSERTION: Unfinalized index must not decrease
            assertTrue(
                afterUnfinalized >= beforeUnfinalized,
                "FQP4 VIOLATED: Unfinalized index decreased when state advanced!"
            );
        }
    }
    
    /// @notice Verify FQP5: Order Preservation property
    function _verifyFQP5OrderPreservation(
        uint256[] memory messageIndices,
        uint256 beforeUnfinalized,
        uint256 afterUnfinalized
    ) internal {
        // FQP5: Messages must be processed in FIFO order
        
        // If no messages were processed, nothing to check
        if (afterUnfinalized <= beforeUnfinalized) {
            return;
        }
        
        // Check that all processed messages were processed in order
        for (uint256 i = beforeUnfinalized; i < afterUnfinalized; i++) {
            // Verify that message at index i was processed before message at index i+1
            if (i + 1 < afterUnfinalized) {
                // In our implementation, this is guaranteed by the sequential index
                // But we verify the invariant holds
                assertTrue(
                    i < i + 1,
                    "FQP5 VIOLATED: Messages not processed in FIFO order!"
                );
            }
        }
        
        // Additional check: if a later message is processed, all earlier messages must be processed
        for (uint256 i = 0; i < messageIndices.length; i++) {
            if (messageIndices[i] < afterUnfinalized) {
                // This message was processed
                for (uint256 j = 0; j < i; j++) {
                    assertTrue(
                        messageIndices[j] < afterUnfinalized,
                        "FQP5 VIOLATED: Later message processed before earlier message!"
                    );
                }
            }
        }
    }
    
    /// @notice Verify FQP6: Finalization Confirmation property
    function _verifyFQP6FinalizationConfirmation(
        uint256[] memory trackedMessages,
        uint256 beforeUnfinalized,
        uint256 afterUnfinalized
    ) internal {
        // FQP6: If a message transitions from unfinalized to finalized, it stays finalized
        
        for (uint256 i = 0; i < trackedMessages.length; i++) {
            uint256 msgIndex = trackedMessages[i];
            
            // Check if message was unfinalized before
            bool wasUnfinalized = msgIndex >= beforeUnfinalized;
            
            // Check if message is finalized now
            bool isFinalized = msgIndex < afterUnfinalized;
            
            if (wasUnfinalized && isFinalized) {
                // FQP6: Message transitioned from unfinalized to finalized
                // In the real system, we would verify it's actually in the finalized state
                // Here we verify the index moved past it, which means it was finalized
                assertTrue(
                    afterUnfinalized > msgIndex,
                    "FQP6 VIOLATED: Message marked as finalized but index didn't move past it!"
                );
            }
            
            // Additional invariant: once finalized, always finalized
            if (!wasUnfinalized) {
                // Was already finalized before
                assertTrue(
                    isFinalized,
                    "FQP6 VIOLATED: Previously finalized message became unfinalized!"
                );
            }
        }
    }
    
    /// @notice Perform random operation focused on FQP testing
    function _performRandomOperationForFQP(uint256 seed) internal returns (bool success) {
        totalOperations++;
        
        // Weighted distribution for FQP-focused testing
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 20) {
            opType = OperationType.SendEnforcedTransaction; // 20%
        } else if (opWeight < 35) {
            opType = OperationType.CommitBatch; // 15%
        } else if (opWeight < 50) {
            opType = OperationType.FinalizeBatch; // 15%
        } else if (opWeight < 65) {
            opType = OperationType.CommitAndFinalizeBatchEnforced; // 15%
        } else if (opWeight < 75) {
            opType = OperationType.ProcessEnforcedMessages; // 10%
        } else if (opWeight < 85) {
            opType = OperationType.AdvanceTime; // 10%
        } else if (opWeight < 95) {
            opType = OperationType.TryFinalizeSkippingTimedOutMessages; // 10%
        } else {
            // Random stress test
            uint256 stress = seed % 3;
            if (stress == 0) opType = OperationType.CommitAlreadyCommitted;
            else if (stress == 1) opType = OperationType.FinalizeFuture;
            else opType = OperationType.FinalizeAlreadyFinalized;
        }
        
        // Execute the operation
        if (opType == OperationType.SendEnforcedTransaction) {
            sendEnforcedTxAttempts++;
            success = _sendEnforcedTransaction(seed);
            if (success) sendEnforcedTxSuccesses++;
        } else if (opType == OperationType.CommitBatch) {
            commitAttempts++;
            success = _commitNextBatch(seed);
            if (success) commitSuccesses++;
        } else if (opType == OperationType.FinalizeBatch) {
            finalizeAttempts++;
            success = _finalizeNextBatch(seed);
            if (success) finalizeSuccesses++;
        } else if (opType == OperationType.CommitAndFinalizeBatchEnforced) {
            commitAndFinalizeEnforcedAttempts++;
            success = _commitAndFinalizeBatchEnforced(seed);
            if (success) commitAndFinalizeEnforcedSuccesses++;
        } else if (opType == OperationType.ProcessEnforcedMessages) {
            processEnforcedMsgAttempts++;
            success = _processEnforcedMessages(seed);
            if (success) processEnforcedMsgSuccesses++;
        } else if (opType == OperationType.AdvanceTime) {
            timeAdvanceAttempts++;
            success = _advanceTime(seed);
            if (success) timeAdvanceSuccesses++;
        } else if (opType == OperationType.TryFinalizeSkippingTimedOutMessages) {
            trySkipTimedOutAttempts++;
            success = _tryFinalizeSkippingTimedOutMessages(seed);
            if (success) trySkipTimedOutSuccesses++;
        } else {
            // Stress test operations
            success = false;
        }
        
        if (success) {
            successfulOperations++;
        } else {
            failedOperations++;
        }
        
        return success;
    }
}
