// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

/// @title GDOGBuybackVault
/// @notice Holds the 1.0% dev/buyback leg of the $GDOG tax and lets the off-chain
/// GDOG-01 sentiment agent trigger buy-and-burns, without ever giving that agent
/// custody of funds or an unbounded spend. The agent's on-chain privileges are limited
/// to calling executeBuyback(); every call is capped by cooldown + per-call percentage,
/// enforced here, not by the agent's own good behavior. See GDOG_TECHNICAL_ROADMAP for
/// the full off-chain -> on-chain trust boundary.
contract GDOGBuybackVault is Ownable, Pausable, ReentrancyGuard {
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable gdogToken;

    /// @dev Hot wallet held by the off-chain agent relay. Deliberately NOT the owner -
    /// it can only call executeBuyback(), nothing else.
    address public agent;

    uint256 public buybackCooldown = 1 hours;
    uint256 public maxBuybackBps = 2500; // max 25% of vault balance spendable per trigger
    uint256 public opsWithdrawBps = 2000; // max 20% of vault balance withdrawable per epoch as ops budget
    uint256 public constant OPS_EPOCH = 7 days;

    uint256 public lastBuybackTime;
    uint256 public opsEpochStart;
    uint256 public opsWithdrawnThisEpoch;

    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event GuardrailsUpdated(uint256 cooldown, uint256 maxBuybackBps, uint256 opsWithdrawBps);
    event BuybackExecuted(address indexed triggeredBy, uint256 ethIn, uint256 gdogBurned);
    event OpsWithdrawal(address indexed to, uint256 amount);

    modifier onlyAgent() {
        require(msg.sender == agent, "Vault: not agent");
        _;
    }

    constructor(address router, address _gdogToken, address _agent, address initialOwner) Ownable(initialOwner) {
        require(router != address(0) && _gdogToken != address(0) && _agent != address(0), "Vault: zero addr");
        uniswapV2Router = IUniswapV2Router02(router);
        gdogToken = _gdogToken;
        agent = _agent;
        opsEpochStart = block.timestamp;
    }

    receive() external payable {}

    /// @notice Called by the GDOG-01 agent relay when it detects extreme FUD or social
    /// silence. Amount requested is clamped to maxBuybackBps of the current balance and
    /// gated by buybackCooldown - a compromised or malfunctioning agent key can drain the
    /// vault only at this bounded rate, never in one shot.
    function executeBuyback(uint256 requestedEthAmount) external onlyAgent whenNotPaused nonReentrant {
        // lastBuybackTime == 0 means "no buyback has ever run" - don't let a cooldown
        // that hasn't started yet block the very first call.
        require(lastBuybackTime == 0 || block.timestamp >= lastBuybackTime + buybackCooldown, "Vault: cooldown active");

        uint256 cap = (address(this).balance * maxBuybackBps) / 10_000;
        uint256 ethAmount = requestedEthAmount > cap ? cap : requestedEthAmount;
        require(ethAmount > 0, "Vault: nothing to spend");

        lastBuybackTime = block.timestamp;

        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = gdogToken;

        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
            0, path, BURN_ADDRESS, block.timestamp
        );

        emit BuybackExecuted(msg.sender, ethAmount, 0);
    }

    /// @notice Owner (multisig) manual buyback spike, same guardrails as the agent path.
    function manualBuyback(uint256 requestedEthAmount) external onlyOwner whenNotPaused nonReentrant {
        uint256 cap = (address(this).balance * maxBuybackBps) / 10_000;
        uint256 ethAmount = requestedEthAmount > cap ? cap : requestedEthAmount;
        require(ethAmount > 0, "Vault: nothing to spend");

        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = gdogToken;

        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
            0, path, BURN_ADDRESS, block.timestamp
        );

        emit BuybackExecuted(msg.sender, ethAmount, 0);
    }

    /// @notice Rate-limited operational withdrawal (infra, listings, trend-bot spend).
    /// Capped at opsWithdrawBps of balance per rolling OPS_EPOCH so the "dev" leg can
    /// never be silently drained in full - keep this pointed at a multisig, not an EOA.
    function withdrawOps(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Vault: zero addr");
        if (block.timestamp >= opsEpochStart + OPS_EPOCH) {
            opsEpochStart = block.timestamp;
            opsWithdrawnThisEpoch = 0;
        }
        uint256 cap = (address(this).balance * opsWithdrawBps) / 10_000;
        require(opsWithdrawnThisEpoch + amount <= cap, "Vault: exceeds ops cap");

        opsWithdrawnThisEpoch += amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Vault: send failed");

        emit OpsWithdrawal(to, amount);
    }

    function setAgent(address newAgent) external onlyOwner {
        require(newAgent != address(0), "Vault: zero addr");
        emit AgentUpdated(agent, newAgent);
        agent = newAgent;
    }

    function setGuardrails(uint256 newCooldown, uint256 newMaxBuybackBps, uint256 newOpsWithdrawBps)
        external
        onlyOwner
    {
        require(newCooldown >= 15 minutes, "Vault: cooldown too short");
        require(newMaxBuybackBps <= 5000, "Vault: max buyback too high");
        require(newOpsWithdrawBps <= 3000, "Vault: max ops withdraw too high");
        buybackCooldown = newCooldown;
        maxBuybackBps = newMaxBuybackBps;
        opsWithdrawBps = newOpsWithdrawBps;
        emit GuardrailsUpdated(newCooldown, newMaxBuybackBps, newOpsWithdrawBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
