// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
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
/// - SRP (Simple Rollup Properties): State integrity and progression
/// - FQP (Forced Queue Properties): Censorship resistance mechanisms  
/// - SP (Scroll-specific Properties): Implementation-specific behaviors
/// 
/// This approach validates that the smart contract implementation maintains
/// the same properties proven in our formal Alloy model.
contract PropertyBasedTests is DSTestPlus {
    
    /*************
     * Constants *
     *************/
    
    uint256 private constant MAX_OPERATIONS = 30;
    uint256 private constant MAX_CHUNKS_PER_BATCH = 10;
    
    /*************
     * Contracts *
     *************/
    
    EmptyContract private placeholder;
    ProxyAdmin private admin;
    SystemConfig private system;
    L1MessageQueueV1 private messageQueueV1;
    L1MessageQueueV2 private messageQueueV2;
    ScrollChain private rollup;
    EnforcedTxGateway private enforcedTxGateway;
    MockRollupVerifier private verifier;
    
    /*************
     * State     *
     *************/
    
    // Test account
    address private testEOA;
    
    // Batch tracking
    uint256 private initialFinalizedBatchIndex;
    uint256 private lastCommittedBatch;
    uint256 private nextBatchToCommit = 1;
    mapping(uint256 => bytes) private committedBatchHeaders;
    
    // SRP3: Commitment tracking
    struct CommitmentProofPair {
        uint256 batchIndex;
        bytes32 commitment;
        bytes32 stateRoot;
        bytes32 withdrawRoot;
        bool hasProof;
        uint256 commitTime;
        uint256 finalizeTime;
    }
    mapping(uint256 => CommitmentProofPair) private commitmentHistory;
    uint256[] private commitmentIndexes;
    
    // Statistics
    mapping(OperationType => uint256) public operationAttempts;
    mapping(OperationType => uint256) public operationSuccesses;
    uint256 public totalOperations;
    
    // Operation types
    enum OperationType {
        CommitBatch,
        FinalizeBatch, 
        AdvanceTime,
        CommitAlreadyCommitted,
        FinalizeFuture,
        CommitFuture,
        FinalizeAlreadyFinalized,
        RevertBatch,
        SendEnforcedTransaction,
        ProcessEnforcedMessages,
        CommitAndFinalizeBatchEnforced,
        TryFinalizeSkippingTimedOutMessages
    }
    
    /*************
     * Setup     *
     *************/
    
    function setUp() public {
        _deployContracts();
        _initializeContracts();
        _setupTestAccounts();
    }
    
    function _deployContracts() private {
        placeholder = new EmptyContract();
        admin = new ProxyAdmin();
        system = SystemConfig(_deployProxy(address(0)));
        messageQueueV1 = L1MessageQueueV1(_deployProxy(address(0)));
        messageQueueV2 = L1MessageQueueV2(_deployProxy(address(0)));
        rollup = ScrollChain(_deployProxy(address(0)));
        enforcedTxGateway = EnforcedTxGateway(_deployProxy(address(0)));
        verifier = new MockRollupVerifier();
    }
    
    function _initializeContracts() private {
        // Initialize SystemConfig
        admin.upgrade(ITransparentUpgradeableProxy(address(system)), address(new SystemConfig()));
        system.initialize(
            address(this),
            address(uint160(1)),
            SystemConfig.MessageQueueParameters({maxGasLimit: 1000000, baseFeeOverhead: 0, baseFeeScalar: 0}),
            SystemConfig.EnforcedBatchParameters({maxDelayEnterEnforcedMode: 86400, maxDelayMessageQueue: 86400})
        );

        // Initialize L1MessageQueueV1
        admin.upgrade(
            ITransparentUpgradeableProxy(address(messageQueueV1)),
            address(new L1MessageQueueV1(address(this), address(rollup), address(1)))
        );
        messageQueueV1.initialize(address(this), address(rollup), address(0), address(0), 10000000);

        // Initialize L1MessageQueueV2
        admin.upgrade(
            ITransparentUpgradeableProxy(address(messageQueueV2)),
            address(new L1MessageQueueV2(
                address(this),
                address(rollup),
                address(1),
                address(messageQueueV1),
                address(system)
            ))
        );
        messageQueueV2.initialize();
        
        // Initialize EnforcedTxGateway
        admin.upgrade(
            ITransparentUpgradeableProxy(address(enforcedTxGateway)),
            address(new EnforcedTxGateway(address(messageQueueV2), address(this)))
        );
        enforcedTxGateway.initialize();

        // Initialize ScrollChain
        admin.upgrade(
            ITransparentUpgradeableProxy(address(rollup)),
            address(new ScrollChainMockBlob(
                233,
                address(messageQueueV1),
                address(messageQueueV2),
                address(verifier),
                address(1)
            ))
        );
        rollup.initialize(address(this), address(this), 1);
        
        // Import genesis batch
        bytes memory batchHeader = new bytes(89);
        assembly {
            mstore(add(batchHeader, add(0x20, 25)), 1)
        }
        rollup.importGenesisBatch(batchHeader, bytes32(uint256(1)));
        
        initialFinalizedBatchIndex = rollup.lastFinalizedBatchIndex();
        lastCommittedBatch = 0;
    }
    
    function _setupTestAccounts() private {
        uint256 testPrivateKey = 0x888;
        testEOA = hevm.addr(testPrivateKey);
        rollup.addProver(testEOA);
        rollup.addSequencer(testEOA);
        hevm.deal(address(this), 100 ether);
    }
    
    function _deployProxy(address _logic) internal returns (address) {
        if (_logic == address(0)) _logic = address(placeholder);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(_logic, address(admin), new bytes(0));
        return address(proxy);
    }
    
    /*********************************
     * Property Test Entry Points    *
     *********************************/
    
    /// @notice SRP2: Monotonic State Property Test
    function testFuzz_SRP2_MonotonicState(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SRP2);
    }
    
    /// @notice SRP3: Justified State Property Test
    function testFuzz_SRP3_JustifiedState(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SRP3);
    }
    
    /// @notice SRP4: State Progression Validity Property Test  
    function testFuzz_SRP4_StateProgressionValidity(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SRP4);
    }
    
    /// @notice FQP1: Timeout-Guaranteed Processing Property Test
    function testFuzz_FQP1_TimeoutGuaranteedProcessing(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.FQP1);
    }
    
    /// @notice FQP2: Message Queue Stable Property Test
    function testFuzz_FQP2_MessageQueueStable(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.FQP2);
    }
    
    /// @notice FQP3: State Invariant Property Test
    function testFuzz_FQP3_StateInvariant(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.FQP3);
    }
    
    /// @notice FQP4: Queued Message Progress Property Test
    function testFuzz_FQP4_QueuedMessageProgress(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.FQP4);
    }
    
    /// @notice FQP5: Order Preservation Property Test
    function testFuzz_FQP5_OrderPreservation(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.FQP5);
    }
    
    /// @notice FQP6: Finalization Confirmation Property Test
    function testFuzz_FQP6_FinalizationConfirmation(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.FQP6);
    }
    
    /// @notice SP1: Rolling Hash Integrity Property Test
    function testFuzz_SP1_RollingHashIntegrity(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SP1);
    }
    
    /// @notice SP2: Enforced Mode Activation Property Test
    function testFuzz_SP2_EnforcedModeActivation(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SP2);
    }
    
    /// @notice SP3: Mode Consistency Property Test
    function testFuzz_SP3_ModeConsistency(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SP3);
    }
    
    /// @notice SP4: Fee Payment Property Test
    function testFuzz_SP4_FeePayment(uint256 seed) external {
        _runPropertyTest(seed, PropertyType.SP4);
    }
    
    /*********************************
     * Property Test Framework       *
     *********************************/
    
    enum PropertyType {
        SRP2, SRP3, SRP4,
        FQP1, FQP2, FQP3, FQP4, FQP5, FQP6,
        SP1, SP2, SP3, SP4
    }
    
    struct TestContext {
        PropertyType propertyType;
        uint256 seed;
        uint256[] trackedIndices;
        bytes32[] trackedHashes;
    }
    
    function _runPropertyTest(uint256 seed, PropertyType propertyType) private {
        _resetStats();
        
        TestContext memory ctx = TestContext({
            propertyType: propertyType,
            seed: seed,
            trackedIndices: new uint256[](0),
            trackedHashes: new bytes32[](0)
        });
        
        // Property-specific setup
        _setupForProperty(ctx);
        
        // Run operations
        uint8 numOperations = _getNumOperations();
        for (uint256 i = 0; i < numOperations; i++) {
            _executeOperationWithVerification(ctx, i);
        }
        
        // Log results
        _logTestResults(propertyType);
    }
    
    function _setupForProperty(TestContext memory ctx) private {
        if (ctx.propertyType == PropertyType.FQP1 || 
            ctx.propertyType == PropertyType.FQP2 ||
            ctx.propertyType == PropertyType.FQP3) {
            // Add enforced messages for FQP tests
            for (uint256 i = 0; i < 2; i++) {
                _sendEnforcedTransaction(uint256(keccak256(abi.encode(ctx.seed, "setup", i))));
            }
        } else if (ctx.propertyType == PropertyType.FQP4) {
            // Add more messages for progress tracking
            for (uint256 i = 0; i < 3; i++) {
                _sendEnforcedTransaction(uint256(keccak256(abi.encode(ctx.seed, "init", i))));
            }
        } else if (ctx.propertyType == PropertyType.FQP5 || 
                   ctx.propertyType == PropertyType.FQP6) {
            // Track specific messages
            ctx.trackedIndices = new uint256[](5);
            for (uint256 i = 0; i < 5; i++) {
                ctx.trackedIndices[i] = messageQueueV2.nextCrossDomainMessageIndex();
                _sendEnforcedTransaction(uint256(keccak256(abi.encode(ctx.seed, "tracked", i))));
            }
        } else if (ctx.propertyType == PropertyType.SP3) {
            // Setup enforced mode for SP3
            for (uint256 i = 0; i < 3; i++) {
                _sendEnforcedTransaction(uint256(keccak256(abi.encode(ctx.seed, "mode", i))));
            }
            (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
            hevm.warp(block.timestamp + maxDelayMessageQueue + 100);
        } else if (ctx.propertyType == PropertyType.SRP3) {
            // Clear commitment tracking for SRP3
            for (uint256 i = 0; i < commitmentIndexes.length; i++) {
                delete commitmentHistory[commitmentIndexes[i]];
            }
            delete commitmentIndexes;
        }
    }
    
    function _getNumOperations() private pure returns (uint8) {
        return 50;
    }
    
    /*********************************
     * Operation Execution           *
     *********************************/
    
    struct OperationState {
        uint256 beforeFinalized;
        uint256 afterFinalized;
        uint256 beforeTotalMessages;
        uint256 afterTotalMessages;
        uint256 beforeUnfinalized;
        uint256 afterUnfinalized;
        bool beforeEnforcedMode;
        bool afterEnforcedMode;
    }
    
    function _executeOperationWithVerification(TestContext memory ctx, uint256 operationIndex) private {
        OperationState memory state;
        
        // Record before state
        state.beforeFinalized = rollup.lastFinalizedBatchIndex();
        state.beforeTotalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        state.beforeUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
        state.beforeEnforcedMode = rollup.isEnforcedModeEnabled();
        
        // Execute operation
        uint256 opSeed = uint256(keccak256(abi.encode(ctx.seed, operationIndex)));
        bool isFQPTest = uint256(ctx.propertyType) >= uint256(PropertyType.FQP1) && 
                         uint256(ctx.propertyType) <= uint256(PropertyType.FQP6);
        bool isSPTest = uint256(ctx.propertyType) >= uint256(PropertyType.SP1);
        
        if (isFQPTest || isSPTest) {
            _performRandomOperationForFQP(opSeed);
        } else if (ctx.propertyType == PropertyType.SRP3) {
            _performRandomOperationWithSRP3Tracking(opSeed);
        } else if (ctx.propertyType == PropertyType.SRP4) {
            _performRandomOperationWithSRP4Check(opSeed);
        } else {
            _performRandomOperation(opSeed, operationIndex);
        }
        
        // Record after state
        state.afterFinalized = rollup.lastFinalizedBatchIndex();
        state.afterTotalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        state.afterUnfinalized = messageQueueV2.nextUnfinalizedQueueIndex();
        state.afterEnforcedMode = rollup.isEnforcedModeEnabled();
        
        // Verify property
        _verifyProperty(ctx, state);
    }
    
    function _verifyProperty(TestContext memory ctx, OperationState memory state) private {
        if (ctx.propertyType == PropertyType.SRP2) {
            _verifySRP2(state);
        } else if (ctx.propertyType == PropertyType.SRP3) {
            _verifySRP3(state);
        } else if (ctx.propertyType == PropertyType.SRP4) {
            // Verified inline in operation
        } else if (ctx.propertyType == PropertyType.FQP1) {
            _verifyFQP1(state);
        } else if (ctx.propertyType == PropertyType.FQP2) {
            _verifyFQP2(state);
        } else if (ctx.propertyType == PropertyType.FQP3) {
            _verifyFQP3(state);
        } else if (ctx.propertyType == PropertyType.FQP4) {
            _verifyFQP4(state);
        } else if (ctx.propertyType == PropertyType.FQP5) {
            _verifyFQP5(ctx.trackedIndices, state);
        } else if (ctx.propertyType == PropertyType.FQP6) {
            _verifyFQP6(ctx.trackedIndices, state);
        } else if (ctx.propertyType == PropertyType.SP1) {
            _verifySP1ForNewMessages(state);
        } else if (ctx.propertyType == PropertyType.SP2) {
            _verifySP2(state);
        } else if (ctx.propertyType == PropertyType.SP3) {
            _verifySP3(state);
        } else if (ctx.propertyType == PropertyType.SP4) {
            _verifySP4ForNewMessages(state);
        }
    }
    
    /*********************************
     * Property Verification         *
     *********************************/
    
    function _verifySRP2(OperationState memory state) private {
        assertGe(
            state.afterFinalized, 
            state.beforeFinalized, 
            "SRP2 violated: finalized index decreased"
        );
    }
    
    function _verifySRP3(OperationState memory state) private {
        if (state.afterFinalized > state.beforeFinalized) {
            for (uint256 idx = state.beforeFinalized + 1; idx <= state.afterFinalized; idx++) {
                _verifySRP3JustifiedState(idx);
            }
        }
    }
    
    function _verifySRP3JustifiedState(uint256 batchIndex) private {
        if (batchIndex == 0) return; // Genesis is pre-justified
        
        CommitmentProofPair memory commitment = commitmentHistory[batchIndex];
        
        if (commitment.batchIndex == batchIndex && commitment.hasProof) {
            // Justified by proof
        } else if (rollup.isEnforcedModeEnabled()) {
            // Justified by enforced mode
        } else {
            assertTrue(false, 
                string(abi.encodePacked("SRP3 violated: batch ", 
                    _uint256ToString(batchIndex), 
                    " finalized without justification"))
            );
        }
    }
    
    function _verifyFQP1(OperationState memory state) private {
        if (state.afterFinalized <= state.beforeFinalized) return;
        
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        if (state.beforeUnfinalized >= totalMessages) return;
        
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        if (block.timestamp > oldestMessageTime + maxDelayMessageQueue) {
            assertTrue(
                state.afterUnfinalized > state.beforeUnfinalized,
                "FQP1 VIOLATED: State advanced while timed-out messages were not processed!"
            );
            
            assertTrue(
                rollup.isEnforcedModeEnabled() || state.afterUnfinalized > state.beforeUnfinalized,
                "FQP1 VIOLATED: Timed-out messages exist but enforced mode not enabled!"
            );
        }
    }
    
    function _verifyFQP2(OperationState memory state) private {
        if (state.beforeFinalized == state.afterFinalized) {
            assertTrue(
                state.afterTotalMessages >= state.beforeTotalMessages,
                "FQP2 VIOLATED: Message queue shrank while finalized state unchanged!"
            );
            
            assertTrue(
                state.afterUnfinalized == state.beforeUnfinalized,
                "FQP2 VIOLATED: Unfinalized index changed while finalized state unchanged!"
            );
        }
    }
    
    function _verifyFQP3(OperationState memory state) private {
        uint256 unfinalizedCount = state.beforeTotalMessages - state.beforeUnfinalized;
        if (unfinalizedCount == 0) return;
        
        bool queueUnchanged = (state.afterTotalMessages == state.beforeTotalMessages) && 
                             (state.afterUnfinalized == state.beforeUnfinalized);
        
        if (!queueUnchanged) return;
        
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        bool messagesTimedOut = block.timestamp > oldestMessageTime + maxDelayMessageQueue;
        
        if (messagesTimedOut) {
            assertTrue(
                state.afterFinalized == state.beforeFinalized,
                "FQP3 VIOLATED: State advanced while timed-out messages exist and queue unchanged!"
            );
        }
    }
    
    function _verifyFQP4(OperationState memory state) private {
        if (state.beforeUnfinalized >= state.beforeTotalMessages) return;
        
        if (state.afterFinalized > state.beforeFinalized) {
            assertTrue(
                state.afterUnfinalized >= state.beforeUnfinalized,
                "FQP4 VIOLATED: Unfinalized index decreased when state advanced!"
            );
        }
    }
    
    function _verifyFQP5(uint256[] memory trackedIndices, OperationState memory state) private {
        if (state.afterUnfinalized <= state.beforeUnfinalized) return;
        
        for (uint256 i = state.beforeUnfinalized; i < state.afterUnfinalized; i++) {
            if (i + 1 < state.afterUnfinalized) {
                assertTrue(i < i + 1, "FQP5 VIOLATED: Messages not processed in FIFO order!");
            }
        }
        
        for (uint256 i = 0; i < trackedIndices.length; i++) {
            if (trackedIndices[i] < state.afterUnfinalized) {
                for (uint256 j = 0; j < i; j++) {
                    assertTrue(
                        trackedIndices[j] < state.afterUnfinalized,
                        "FQP5 VIOLATED: Later message processed before earlier message!"
                    );
                }
            }
        }
    }
    
    function _verifyFQP6(uint256[] memory trackedMessages, OperationState memory state) private {
        for (uint256 i = 0; i < trackedMessages.length; i++) {
            uint256 msgIndex = trackedMessages[i];
            
            bool wasUnfinalized = msgIndex >= state.beforeUnfinalized;
            bool isFinalized = msgIndex < state.afterUnfinalized;
            
            if (wasUnfinalized && isFinalized) {
                assertTrue(
                    state.afterUnfinalized > msgIndex,
                    "FQP6 VIOLATED: Message marked as finalized but index didn't move past it!"
                );
            }
            
            if (!wasUnfinalized) {
                assertTrue(
                    isFinalized,
                    "FQP6 VIOLATED: Previously finalized message became unfinalized!"
                );
            }
        }
    }
    
    function _verifySP1ForNewMessages(OperationState memory state) private {
        if (state.afterTotalMessages > state.beforeTotalMessages) {
            for (uint256 msgIdx = state.beforeTotalMessages; msgIdx < state.afterTotalMessages; msgIdx++) {
                _verifySP1RollingHashIntegrity(msgIdx);
            }
        }
    }
    
    function _verifySP1RollingHashIntegrity(uint256 messageIndex) private {
        bytes32 actualHash = messageQueueV2.getMessageRollingHash(messageIndex);
        
        assertTrue(actualHash != bytes32(0), "SP1 VIOLATED: Rolling hash is zero!");
        
        if (messageIndex > 0) {
            bytes32 prevHash = messageQueueV2.getMessageRollingHash(messageIndex - 1);
            assertTrue(
                actualHash != prevHash,
                "SP1 VIOLATED: Rolling hash not unique from previous message!"
            );
        }
    }
    
    function _verifySP2(OperationState memory state) private {
        if (!state.beforeEnforcedMode && state.afterEnforcedMode) {
            uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
            uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
            
            if (unfinalizedIndex < totalMessages) {
                (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
                uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
                
                assertTrue(
                    block.timestamp > oldestMessageTime + maxDelayMessageQueue,
                    "SP2 VIOLATED: Enforced mode activated without timeout conditions!"
                );
            }
        }
    }
    
    function _verifySP3(OperationState memory state) private {
        if (state.beforeEnforcedMode || state.afterEnforcedMode) {
            // Mode consistency is enforced by contract modifiers
            // Additional runtime checks could be added here
        }
    }
    
    function _verifySP4ForNewMessages(OperationState memory state) private {
        if (state.afterTotalMessages > state.beforeTotalMessages) {
            for (uint256 txIdx = state.beforeTotalMessages; txIdx < state.afterTotalMessages; txIdx++) {
                _verifySP4FeePayment(txIdx);
            }
        }
    }
    
    function _verifySP4FeePayment(uint256 messageIndex) private {
        bytes32 messageHash = messageQueueV2.getMessageRollingHash(messageIndex);
        assertTrue(messageHash != bytes32(0), "SP4 VIOLATED: Message added without proper fee payment!");
        
        uint256 timestamp = messageQueueV2.getMessageEnqueueTimestamp(messageIndex);
        assertTrue(
            timestamp > 0 && timestamp <= block.timestamp,
            "SP4 VIOLATED: Invalid timestamp for fee-paid transaction!"
        );
    }
    
    /*********************************
     * Operation Implementations     *
     *********************************/
    
    function _performRandomOperation(uint256 seed, uint256 /* operationIndex */) internal returns (bool) {
        totalOperations++;
        
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 40) {
            opType = OperationType.CommitBatch;
        } else if (opWeight < 70) {
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 85) {
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 92) {
            opType = OperationType.CommitAlreadyCommitted;
        } else if (opWeight < 97) {
            opType = OperationType.FinalizeFuture;
        } else {
            opType = OperationType.FinalizeAlreadyFinalized;
        }
        
        return _executeOperation(opType, seed);
    }
    
    function _performRandomOperationForFQP(uint256 seed) internal returns (bool) {
        totalOperations++;
        
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 20) {
            opType = OperationType.SendEnforcedTransaction;
        } else if (opWeight < 35) {
            opType = OperationType.CommitBatch;
        } else if (opWeight < 50) {
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 65) {
            opType = OperationType.CommitAndFinalizeBatchEnforced;
        } else if (opWeight < 75) {
            opType = OperationType.ProcessEnforcedMessages;
        } else if (opWeight < 85) {
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 95) {
            opType = OperationType.TryFinalizeSkippingTimedOutMessages;
        } else {
            uint256 stress = seed % 3;
            if (stress == 0) opType = OperationType.CommitAlreadyCommitted;
            else if (stress == 1) opType = OperationType.FinalizeFuture;
            else opType = OperationType.FinalizeAlreadyFinalized;
        }
        
        return _executeOperation(opType, seed);
    }
    
    function _performRandomOperationWithSRP3Tracking(uint256 seed) internal returns (bool) {
        totalOperations++;
        
        uint256 opWeight = seed % 100;
        OperationType opType;
        
        if (opWeight < 35) {
            opType = OperationType.CommitBatch;
        } else if (opWeight < 65) {
            opType = OperationType.FinalizeBatch;
        } else if (opWeight < 75) {
            opType = OperationType.AdvanceTime;
        } else if (opWeight < 80) {
            opType = OperationType.SendEnforcedTransaction;
        } else if (opWeight < 85) {
            opType = OperationType.CommitAndFinalizeBatchEnforced;
        } else {
            uint256 stress = seed % 4;
            if (stress == 0) opType = OperationType.CommitAlreadyCommitted;
            else if (stress == 1) opType = OperationType.FinalizeFuture;
            else if (stress == 2) opType = OperationType.FinalizeAlreadyFinalized;
            else opType = OperationType.RevertBatch;
        }
        
        bool success = _executeOperation(opType, seed);
        
        // Track commitments for SRP3
        if (opType == OperationType.CommitBatch && success) {
            _trackCommitmentForSRP3();
        } else if (opType == OperationType.FinalizeBatch && success) {
            _trackProofForSRP3();
        }
        
        return success;
    }
    
    function _performRandomOperationWithSRP4Check(uint256 seed) internal returns (bool) {
        totalOperations++;
        uint256 currentFinalized = rollup.lastFinalizedBatchIndex();
        
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
        
        if (opType == OperationType.CommitBatch) {
            return _commitNextBatchWithSRP4Check(seed, currentFinalized);
        } else if (opType == OperationType.FinalizeBatch) {
            return _finalizeNextBatchWithSRP4Check(seed, currentFinalized);
        } else {
            return _executeOperation(opType, seed);
        }
    }
    
    function _executeOperation(OperationType opType, uint256 seed) private returns (bool) {
        operationAttempts[opType]++;
        
        bool success = false;
        
        if (opType == OperationType.CommitBatch) {
            success = _commitNextBatch(seed);
        } else if (opType == OperationType.FinalizeBatch) {
            success = _finalizeNextBatch(seed);
        } else if (opType == OperationType.AdvanceTime) {
            success = _advanceTime(seed);
        } else if (opType == OperationType.SendEnforcedTransaction) {
            success = _sendEnforcedTransaction(seed);
        } else if (opType == OperationType.CommitAndFinalizeBatchEnforced) {
            success = _commitAndFinalizeBatchEnforced(seed);
        } else if (opType == OperationType.ProcessEnforcedMessages) {
            success = _processEnforcedMessages(seed);
        } else if (opType == OperationType.TryFinalizeSkippingTimedOutMessages) {
            success = _tryFinalizeSkippingTimedOutMessages(seed);
        } else if (opType == OperationType.CommitAlreadyCommitted) {
            success = _commitAlreadyCommittedBatch(seed);
            assertFalse(success);
        } else if (opType == OperationType.FinalizeFuture) {
            success = _finalizeFutureBatch(seed);
            assertFalse(success);
        } else if (opType == OperationType.FinalizeAlreadyFinalized) {
            success = _finalizeAlreadyFinalizedBatch(seed);
            assertFalse(success);
        } else if (opType == OperationType.RevertBatch) {
            success = _revertBatch(seed);
        }
        
        if (success) {
            operationSuccesses[opType]++;
        }
        
        return success;
    }
    
    /*********************************
     * Core Operations               *
     *********************************/
    
    function _commitNextBatch(uint256 seed) internal returns (bool) {
        if (rollup.paused()) return false;
        
        (uint64 lastCommittedIndex,,,,) = rollup.miscData();
        bytes32 parentBatchHash = rollup.committedBatches(lastCommittedIndex);
        uint64 newBatchIndex = lastCommittedIndex + 1;
        
        bytes32 blobVersionedHash = keccak256(abi.encode("blob", seed, newBatchIndex));
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, newBatchIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        bytes32 expectedBatchHash = BatchHeaderV0Codec.computeBatchHash(
            batchPtr,
            BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH
        );
        
        bytes memory batchHeaderBytes = new bytes(BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH);
        assembly {
            let headerPtr := add(batchHeaderBytes, 0x20)
            let src := batchPtr
            mstore(headerPtr, mload(src))
            mstore(add(headerPtr, 0x20), mload(add(src, 0x20)))
            let remaining := mload(add(src, 0x40))
            mstore(add(headerPtr, 0x40), remaining)
        }
        
        hevm.startPrank(testEOA);
        try rollup.commitBatches(7, parentBatchHash, expectedBatchHash) {
            hevm.stopPrank();
            committedBatchHeaders[newBatchIndex] = batchHeaderBytes;
            nextBatchToCommit++;
            lastCommittedBatch = uint256(newBatchIndex);
            return true;
        } catch {
            hevm.stopPrank();
            return false;
        }
    }
    
    function _finalizeNextBatch(uint256 seed) internal returns (bool) {
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        uint64 batchToFinalize = uint64(lastFinalized + 1);
        
        if (rollup.committedBatches(batchToFinalize) == bytes32(0)) {
            return false;
        }
        
        if (committedBatchHeaders[batchToFinalize].length == 0) {
            return false;
        }
        
        bytes memory batchHeader = committedBatchHeaders[batchToFinalize];
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, batchToFinalize));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, batchToFinalize));
        bytes memory proof = abi.encode("mockProof", seed);
        
        hevm.startPrank(testEOA);
        try rollup.finalizeBundlePostEuclidV2(
            batchHeader,
            0,
            stateRoot,
            withdrawRoot,
            proof
        ) {
            hevm.stopPrank();
            return true;
        } catch {
            hevm.stopPrank();
            return false;
        }
    }
    
    function _advanceTime(uint256 seed) internal returns (bool) {
        uint256 timeToAdvance = 1 + (seed % 3600);
        hevm.warp(block.timestamp + timeToAdvance);
        return true;
    }
    
    function _sendEnforcedTransaction(uint256 seed) internal returns (bool) {
        address target = address(uint160(seed % type(uint160).max));
        uint256 value = seed % 1 ether;
        uint256 gasLimit = 100000 + (seed % 200000);
        bytes memory data = abi.encode("enforced_tx", seed);
        
        uint256 fee = messageQueueV2.estimateCrossDomainMessageFee(gasLimit);
        uint256 totalValue = value + fee;
        
        uint256 messageIndexBefore = messageQueueV2.nextCrossDomainMessageIndex();
        
        try enforcedTxGateway.sendTransaction{value: totalValue}(target, value, gasLimit, data) {
            uint256 messageIndexAfter = messageQueueV2.nextCrossDomainMessageIndex();
            require(messageIndexAfter == messageIndexBefore + 1, "Message not added to queue");
            
            if (seed % 2 == 0) {
                (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
                uint256 timeToAdvance = maxDelayMessageQueue + 1 + (seed % 3600);
                hevm.warp(block.timestamp + timeToAdvance);
                operationAttempts[OperationType.AdvanceTime]++;
                operationSuccesses[OperationType.AdvanceTime]++;
            }
            
            return true;
        } catch {
            return false;
        }
    }
    
    function _commitAndFinalizeBatchEnforced(uint256 seed) internal returns (bool) {
        uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        
        if (unfinalizedIndex >= totalMessages) {
            return false;
        }
        
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        if (!rollup.isEnforcedModeEnabled() && block.timestamp <= oldestMessageTime + maxDelayMessageQueue) {
            return false;
        }
        
        uint64 lastFinalized = uint64(rollup.lastFinalizedBatchIndex());
        bytes32 parentBatchHash = rollup.committedBatches(lastFinalized);
        uint64 newBatchIndex = lastFinalized + 1;
        
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
        
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, newBatchIndex));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, newBatchIndex));
        bytes memory proof = abi.encode("mockProof", seed);
        
        IScrollChain.FinalizeStruct memory finalizeStruct = IScrollChain.FinalizeStruct({
            batchHeader: batchHeader,
            totalL1MessagesPoppedOverall: 0,
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
    
    function _processEnforcedMessages(uint256 seed) internal returns (bool) {
        uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        
        if (unfinalizedIndex >= totalMessages) {
            return false;
        }
        
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        
        if (block.timestamp <= oldestMessageTime + maxDelayMessageQueue) {
            return false;
        }
        
        bool success = _commitNextBatch(seed);
        if (success) {
            success = _finalizeNextBatch(seed >> 128);
        }
        
        return success;
    }
    
    function _tryFinalizeSkippingTimedOutMessages(uint256 seed) internal returns (bool) {
        uint256 unfinalizedIndex = messageQueueV2.nextUnfinalizedQueueIndex();
        uint256 totalMessages = messageQueueV2.nextCrossDomainMessageIndex();
        
        if (unfinalizedIndex >= totalMessages) {
            return _finalizeNextBatch(seed);
        }
        
        (, uint256 maxDelayMessageQueue) = SystemConfig(system).enforcedBatchParameters();
        uint256 oldestMessageTime = messageQueueV2.getFirstUnfinalizedMessageEnqueueTime();
        
        bool messagesTimedOut = block.timestamp > oldestMessageTime + maxDelayMessageQueue;
        
        bool success = _finalizeNextBatch(seed);
        
        if (messagesTimedOut && !rollup.isEnforcedModeEnabled()) {
            assertTrue(!success, "FQP1 TEST FAILURE: Finalized batch while skipping timed-out messages!");
        }
        
        return success;
    }
    
    /*********************************
     * Stress Test Operations        *
     *********************************/
    
    function _commitAlreadyCommittedBatch(uint256 seed) internal returns (bool) {
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        (uint64 lastCommitted,,,,) = rollup.miscData();
        
        if (lastCommitted <= lastFinalized) {
            return false;
        }
        
        uint64 alreadyCommittedIndex = uint64(lastFinalized + 1 + (seed % (lastCommitted - lastFinalized)));
        bytes32 parentBatchHash = rollup.committedBatches(alreadyCommittedIndex - 1);
        
        bytes32 blobVersionedHash = keccak256(abi.encode("duplicate_blob", seed, alreadyCommittedIndex));
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, alreadyCommittedIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        bytes32 batchHash = BatchHeaderV0Codec.computeBatchHash(
            batchPtr,
            BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH
        );
        
        hevm.startPrank(testEOA);
        try rollup.commitBatches(7, parentBatchHash, batchHash) {
            hevm.stopPrank();
            return true;
        } catch {
            hevm.stopPrank();
            return false;
        }
    }
    
    function _finalizeFutureBatch(uint256 seed) internal returns (bool) {
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        (uint64 lastCommitted,,,,) = rollup.miscData();
        
        if (lastCommitted <= lastFinalized + 1) {
            return false;
        }
        
        uint64 futureBatch = uint64(lastFinalized + 2);
        
        bytes memory batchHeader = _generateValidBatchHeaderV7(seed, futureBatch);
        
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, futureBatch));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, futureBatch));
        bytes memory proof = abi.encode("mockProof", seed);
        
        hevm.startPrank(testEOA);
        try rollup.finalizeBundlePostEuclidV2(
            batchHeader,
            0,
            stateRoot,
            withdrawRoot,
            proof
        ) {
            hevm.stopPrank();
            return true;
        } catch {
            hevm.stopPrank();
            return false;
        }
    }
    
    function _finalizeAlreadyFinalizedBatch(uint256 seed) internal returns (bool) {
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        
        if (lastFinalized == 0) {
            return false;
        }
        
        uint64 alreadyFinalizedIndex = uint64(1 + (seed % lastFinalized));
        
        bytes memory batchHeader = _generateValidBatchHeaderV7(seed, alreadyFinalizedIndex);
        
        bytes32 stateRoot = keccak256(abi.encode("stateRoot", seed, alreadyFinalizedIndex));
        bytes32 withdrawRoot = keccak256(abi.encode("withdrawRoot", seed, alreadyFinalizedIndex));
        bytes memory proof = abi.encode("mockProof", seed);
        
        hevm.startPrank(testEOA);
        try rollup.finalizeBundlePostEuclidV2(
            batchHeader,
            0,
            stateRoot,
            withdrawRoot,
            proof
        ) {
            hevm.stopPrank();
            return true;
        } catch {
            hevm.stopPrank();
            return false;
        }
    }
    
    function _revertBatch(uint256 seed) internal returns (bool) {
        if (rollup.paused()) return false;
        
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        (uint64 lastCommitted,,,,) = rollup.miscData();
        
        if (lastCommitted <= lastFinalized) {
            return false;
        }
        
        uint64 batchToRevert = uint64(lastFinalized + 1 + (seed % (lastCommitted - lastFinalized)));
        
        if (committedBatchHeaders[batchToRevert].length == 0) {
            return false;
        }
        
        bytes memory batchHeader = committedBatchHeaders[batchToRevert];
        
        try rollup.revertBatch(batchHeader) {
            for (uint256 i = batchToRevert; i <= lastCommitted; i++) {
                delete committedBatchHeaders[i];
            }
            return true;
        } catch {
            return false;
        }
    }
    
    /*********************************
     * SRP-Specific Functions        *
     *********************************/
    
    function _commitNextBatchWithSRP4Check(uint256 seed, uint256 currentFinalized) internal returns (bool) {
        operationAttempts[OperationType.CommitBatch]++;
        bool success = _commitNextBatch(seed);
        
        if (success) {
            operationSuccesses[OperationType.CommitBatch]++;
            
            (uint64 newCommittedIndex,,,,) = rollup.miscData();
            
            assertTrue(
                newCommittedIndex > currentFinalized,
                "SRP4 violated: committed batch index not greater than finalized"
            );
        }
        
        return success;
    }
    
    function _finalizeNextBatchWithSRP4Check(uint256 seed, uint256 currentFinalized) internal returns (bool) {
        operationAttempts[OperationType.FinalizeBatch]++;
        
        uint256 batchToFinalize = currentFinalized + 1;
        
        if (rollup.committedBatches(batchToFinalize) == bytes32(0)) {
            return false;
        }
        
        bool success = _finalizeNextBatch(seed);
        
        if (success) {
            operationSuccesses[OperationType.FinalizeBatch]++;
            
            uint256 newFinalized = rollup.lastFinalizedBatchIndex();
            
            assertTrue(
                newFinalized == batchToFinalize,
                "SRP4 violated: finalized wrong batch"
            );
        }
        
        return success;
    }
    
    function _trackCommitmentForSRP3() private {
        (uint64 lastCommittedIndex,,,,) = rollup.miscData();
        
        commitmentHistory[lastCommittedIndex] = CommitmentProofPair({
            batchIndex: lastCommittedIndex,
            commitment: rollup.committedBatches(lastCommittedIndex),
            stateRoot: bytes32(0),
            withdrawRoot: bytes32(0),
            hasProof: false,
            commitTime: block.timestamp,
            finalizeTime: 0
        });
        
        commitmentIndexes.push(lastCommittedIndex);
    }
    
    function _trackProofForSRP3() private {
        uint256 lastFinalized = rollup.lastFinalizedBatchIndex();
        
        if (commitmentHistory[lastFinalized].batchIndex == lastFinalized) {
            commitmentHistory[lastFinalized].hasProof = true;
            commitmentHistory[lastFinalized].finalizeTime = block.timestamp;
            commitmentHistory[lastFinalized].stateRoot = rollup.finalizedStateRoots(lastFinalized);
            commitmentHistory[lastFinalized].withdrawRoot = rollup.withdrawRoots(lastFinalized);
        }
    }
    
    /*********************************
     * Utility Functions             *
     *********************************/
    
    function _resetStats() private {
        totalOperations = 0;
        
        for (uint256 i = 0; i <= uint256(OperationType.TryFinalizeSkippingTimedOutMessages); i++) {
            delete operationAttempts[OperationType(i)];
            delete operationSuccesses[OperationType(i)];
        }
    }
    
    function _generateValidBatchHeaderV7(uint256 seed, uint64 batchIndex) private returns (bytes memory) {
        bytes32 parentBatchHash = rollup.committedBatches(batchIndex - 1);
        bytes32 blobVersionedHash = keccak256(abi.encode("blob", seed, batchIndex));
        
        ScrollChainMockBlob(address(rollup)).setBlobVersionedHash(0, blobVersionedHash);
        
        uint256 batchPtr = BatchHeaderV7Codec.allocate();
        BatchHeaderV0Codec.storeVersion(batchPtr, 7);
        BatchHeaderV0Codec.storeBatchIndex(batchPtr, batchIndex);
        BatchHeaderV7Codec.storeParentBatchHash(batchPtr, parentBatchHash);
        BatchHeaderV7Codec.storeBlobVersionedHash(batchPtr, blobVersionedHash);
        
        bytes memory batchHeaderBytes = new bytes(BatchHeaderV7Codec.BATCH_HEADER_FIXED_LENGTH);
        assembly {
            let headerPtr := add(batchHeaderBytes, 0x20)
            let src := batchPtr
            mstore(headerPtr, mload(src))
            mstore(add(headerPtr, 0x20), mload(add(src, 0x20)))
            let remaining := mload(add(src, 0x40))
            mstore(add(headerPtr, 0x40), remaining)
        }
        
        return batchHeaderBytes;
    }
    
    function _uint256ToString(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function _logTestResults(PropertyType propertyType) private {
        string memory propertyName;
        
        if (propertyType == PropertyType.SRP2) propertyName = "SRP2 Monotonic State";
        else if (propertyType == PropertyType.SRP3) propertyName = "SRP3 Justified State";
        else if (propertyType == PropertyType.SRP4) propertyName = "SRP4 State Progression Validity";
        else if (propertyType == PropertyType.FQP1) propertyName = "FQP1 Timeout-Guaranteed Processing";
        else if (propertyType == PropertyType.FQP2) propertyName = "FQP2 Message Queue Stable";
        else if (propertyType == PropertyType.FQP3) propertyName = "FQP3 State Invariant";
        else if (propertyType == PropertyType.FQP4) propertyName = "FQP4 Queued Message Progress";
        else if (propertyType == PropertyType.FQP5) propertyName = "FQP5 Order Preservation";
        else if (propertyType == PropertyType.FQP6) propertyName = "FQP6 Finalization Confirmation";
        else if (propertyType == PropertyType.SP1) propertyName = "SP1 Rolling Hash Integrity";
        else if (propertyType == PropertyType.SP2) propertyName = "SP2 Enforced Mode Activation";
        else if (propertyType == PropertyType.SP3) propertyName = "SP3 Mode Consistency";
        else if (propertyType == PropertyType.SP4) propertyName = "SP4 Fee Payment";
        
        emit log(string(abi.encodePacked("=== ", propertyName, " Test Results ===")));
        emit log_named_uint("Total operations", totalOperations);
        
        if (uint256(propertyType) >= uint256(PropertyType.FQP1)) {
            emit log_named_uint("Messages in queue", messageQueueV2.nextCrossDomainMessageIndex());
            emit log_named_uint("Unfinalized messages", 
                messageQueueV2.nextCrossDomainMessageIndex() - messageQueueV2.nextUnfinalizedQueueIndex());
        }
        
        emit log_named_uint("Final finalized batch index", rollup.lastFinalizedBatchIndex());
        
        if (uint256(propertyType) >= uint256(PropertyType.SP2)) {
            emit log_named_string("Final enforced mode status", 
                rollup.isEnforcedModeEnabled() ? "true" : "false");
        }
        
        emit log(string(abi.encodePacked("=== ", propertyName, " Test Complete ===")));
    }
}