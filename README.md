# Scroll Contracts

This directory contains the solidity code for Scroll L1 bridge and rollup contracts and L2 bridge and pre-deployed contracts.

**Property based testing based on Alloy properties**

| You can find a description of the tests at `PROPERTY_BASED_TESTS.md` and the tests at `src/test/PropertyBasedTests.t.sol`.

To run the tests:

```bash
forge test --match-contract PropertyBasedTests --fuzz-runs 10000 -vvv
```

Results:

```
Ran 13 tests for src/test/PropertyBasedTests.t.sol:PropertyBasedTests
[PASS] testFuzz_FQP1_TimeoutGuaranteedProcessing(uint256) (runs: 10003, μ: 3090834, ~: 3094662)
[PASS] testFuzz_FQP2_MessageQueueStable(uint256) (runs: 10003, μ: 3093303, ~: 3097219)
[PASS] testFuzz_FQP3_StateInvariant(uint256) (runs: 10003, μ: 3088219, ~: 3092425)
[PASS] testFuzz_FQP4_QueuedMessageProgress(uint256) (runs: 10003, μ: 3120331, ~: 3124098)
[PASS] testFuzz_FQP5_OrderPreservation(uint256) (runs: 10003, μ: 3198975, ~: 3204656)
[PASS] testFuzz_FQP6_FinalizationConfirmation(uint256) (runs: 10003, μ: 3259749, ~: 3258733)
[PASS] testFuzz_SP1_RollingHashIntegrity(uint256) (runs: 10003, μ: 3030205, ~: 3042513)
[PASS] testFuzz_SP2_EnforcedModeActivation(uint256) (runs: 10003, μ: 3031546, ~: 3039288)
[PASS] testFuzz_SP3_ModeConsistency(uint256) (runs: 10003, μ: 3147296, ~: 3153329)
[PASS] testFuzz_SP4_FeePayment(uint256) (runs: 10003, μ: 3040719, ~: 3043187)
[PASS] testFuzz_SRP2_MonotonicState(uint256) (runs: 10003, μ: 4573755, ~: 4600396)
[PASS] testFuzz_SRP3_JustifiedState(uint256) (runs: 10003, μ: 5960089, ~: 5923056)
[PASS] testFuzz_SRP4_StateProgressionValidity(uint256) (runs: 10003, μ: 3269246, ~: 3267431)
Suite result: ok. 13 passed; 0 failed; 0 skipped; finished in 107.46s (776.86s CPU time)

Ran 1 test suite in 107.47s (107.46s CPU time): 13 tests passed, 0 failed, 0 skipped (13 total tests)
```

## Directory Structure

<pre>
├── <a href="./hardhat-test/">hardhat-test</a>: Hardhat integration tests
├── <a href="./lib/">lib</a>: External libraries and testing tools
├── <a href="./scripts">scripts</a>: Deployment scripts
├── <a href="./src">src</a>
│   ├── <a href="./src/gas-swap/">gas-swap</a>: Utility contract that allows gas payment in other tokens
│   ├── <a href="./src/interfaces/">interfaces</a>: Common contract interfaces
│   ├── <a href="./src/L1/">L1</a>: Contracts deployed on the L1 (Ethereum)
│   │   ├── <a href="./src/L1/gateways/">gateways</a>: Gateway router and token gateway contracts
│   │   ├── <a href="./src/L1/rollup/">rollup</a>: Rollup contracts for data availability and finalization
│   │   ├── <a href="./src/L1/IL1ScrollMessenger.sol">IL1ScrollMessenger.sol</a>: L1 Scroll messenger interface
│   │   └── <a href="./src/L1/L1ScrollMessenger.sol">L1ScrollMessenger.sol</a>: L1 Scroll messenger contract
│   ├── <a href="./src/L2/">L2</a>: Contracts deployed on the L2 (Scroll)
│   │   ├── <a href="./src/L2/gateways/">gateways</a>: Gateway router and token gateway contracts
│   │   ├── <a href="./src/L2/predeploys/">predeploys</a>: Pre-deployed contracts on L2
│   │   ├── <a href="./src/L2/IL2ScrollMessenger.sol">IL2ScrollMessenger.sol</a>: L2 Scroll messenger interface
│   │   └── <a href="./src/L2/L2ScrollMessenger.sol">L2ScrollMessenger.sol</a>: L2 Scroll messenger contract
│   ├── <a href="./src/libraries/">libraries</a>: Shared contract libraries
│   ├── <a href="./src/misc/">misc</a>: Miscellaneous contracts
│   ├── <a href="./src/mocks/">mocks</a>: Mock contracts used in the testing
│   ├── <a href="./src/rate-limiter/">rate-limiter</a>: Rater limiter contract
│   └── <a href="./src/test/">test</a>: Unit tests in solidity
├── <a href="./foundry.toml">foundry.toml</a>: Foundry configuration
├── <a href="./hardhat.config.ts">hardhat.config.ts</a>: Hardhat configuration
├── <a href="./remappings.txt">remappings.txt</a>: Foundry dependency mappings
...
</pre>

## Dependencies

### Node.js

First install [`Node.js`](https://nodejs.org/en) and [`npm`](https://www.npmjs.com/).
Run the following command to install [`yarn`](https://classic.yarnpkg.com/en/):

```bash
npm install --global yarn
```

### Foundry

Install `foundryup`, the Foundry toolchain installer:

```bash
curl -L https://foundry.paradigm.xyz | bash
```

If you do not want to use the redirect, feel free to manually download the `foundryup` installation script from [here](https://raw.githubusercontent.com/foundry-rs/foundry/master/foundryup/foundryup).

Then, run `foundryup` in a new terminal session or after reloading `PATH`.

Other ways to install Foundry can be found [here](https://github.com/foundry-rs/foundry#installation).

### Hardhat

Run the following command to install [Hardhat](https://hardhat.org/) and other dependencies.

```
yarn install
```

## Build

- Run `git submodule update --init --recursive` to initialize git submodules.
- Run `yarn prettier:solidity` to run linting in fix mode, will auto-format all solidity codes.
- Run `yarn prettier` to run linting in fix mode, will auto-format all typescript codes.
- Run `yarn prepare` to install the precommit linting hook.
- Run `forge build --evm-version cancun` to compile contracts with foundry.
- Run `npx hardhat compile` to compile with hardhat.
- Run `forge test --evm-version cancun -vvv` to run foundry units tests. It will compile all contracts before running the unit tests.
- Run `npx hardhat test` to run integration tests. It may not compile all contracts before running, it's better to run `npx hardhat compile` first.
