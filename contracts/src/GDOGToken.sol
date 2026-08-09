// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IUniswapV2Router02, IUniswapV2Factory} from "./interfaces/IUniswapV2.sol";

/// @title GDOGToken ($GDOG)
/// @notice Receiver-side-tax token: every buy/sell through a registered AMM pair pays a
/// tax in $GDOG that is converted to native ETH and distributed *within the same or the
/// immediately following transaction*, instead of being warehoused in the contract and
/// dumped in one large batch later (the classic "swap-and-liquify" dump candle).
///
/// Honesty note on the "never sells $GDOG" requirement: a fee-on-transfer token cannot
/// extract ETH mid-swap without a modified router, and modifying the router would break
/// GSWAP/Uniswap V2 compatibility. What this contract guarantees instead is (a) tax is
/// swapped in small, bounded increments on essentially every sell rather than
/// accumulated and (b) the auto-liquidity leg pairs ETH against a pre-funded treasury
/// allocation, never against freshly taxed tokens - so taxed tokens are only ever
/// converted once, immediately, and never re-sold from an accumulated pile.
contract GDOGToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Steady-state 5% tax split 2.5 / 1.5 / 1.0
    uint256 public constant MARKETING_FEE_BPS = 250;
    uint256 public constant LIQUIDITY_FEE_BPS = 150;
    uint256 public constant DEV_FEE_BPS = 100;
    uint256 public constant BASE_TAX_BPS = MARKETING_FEE_BPS + LIQUIDITY_FEE_BPS + DEV_FEE_BPS; // 500 = 5%

    // Anti-snipe launch tax: 20% decaying linearly to 5% over 5 blocks
    uint256 public constant LAUNCH_TAX_BPS = 2000;
    uint256 public constant LAUNCH_DECAY_BLOCKS = 5;

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;

    address public marketingWallet;
    address public buybackVault; // GDOGBuybackVault - fed by the 1.0% dev/buyback leg
    address public liquidityLockRecipient; // LP tokens sent here (timelock/dead address)

    uint256 public liquidityTreasury; // GDOG pre-funded for auto-liquidity, never sourced from tax
    // Tracks only tax collected via _update, separate from liquidityTreasury and any
    // other GDOG the contract happens to hold - the auto-swap must never touch anything
    // but tax it actually collected.
    uint256 public pendingTaxTokens;
    uint256 public maxSwapAmount = TOTAL_SUPPLY / 200; // 0.5% cap per auto-swap, bounds price impact

    uint256 public maxTxAmount = TOTAL_SUPPLY / 100; // 1%
    uint256 public maxWalletAmount = (TOTAL_SUPPLY * 2) / 100; // 2%

    uint256 public launchBlock;
    bool public tradingEnabled;
    bool private _inSwap;

    mapping(address => bool) public automatedMarketMakerPairs;
    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public isExcludedFromLimits;

    event TaxCollected(address indexed from, uint256 tokenAmount, uint256 taxBps);
    event TaxSwapped(uint256 tokenAmountIn, uint256 ethOut);
    event TaxDistributed(uint256 marketingEth, uint256 devEth, uint256 liquidityEth);
    event LiquidityTreasuryFunded(address indexed from, uint256 amount);
    event TradingEnabled(uint256 launchBlock);
    event LimitsRaised(uint256 maxTxAmount, uint256 maxWalletAmount);

    modifier lockTheSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    constructor(
        address router,
        address _marketingWallet,
        address _buybackVault,
        address _liquidityLockRecipient,
        address initialOwner
    ) ERC20("Gdog", "GDOG") Ownable(initialOwner) {
        require(router != address(0) && _marketingWallet != address(0), "GDOG: zero addr");
        require(_liquidityLockRecipient != address(0), "GDOG: zero addr");
        // _buybackVault may be address(0) at construction time to break the circular
        // dependency (GDOGBuybackVault's constructor needs this token's address). Deploy
        // the token first, deploy the vault with the resulting token address, then wire
        // it back with setBuybackVault() before enableTrading(). See roadmap Phase 3.

        uniswapV2Router = IUniswapV2Router02(router);
        marketingWallet = _marketingWallet;
        buybackVault = _buybackVault;
        liquidityLockRecipient = _liquidityLockRecipient;

        address pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());
        uniswapV2Pair = pair;
        automatedMarketMakerPairs[pair] = true;

        isExcludedFromFees[initialOwner] = true;
        isExcludedFromFees[address(this)] = true;
        if (_buybackVault != address(0)) isExcludedFromFees[_buybackVault] = true;

        isExcludedFromLimits[initialOwner] = true;
        isExcludedFromLimits[address(this)] = true;
        isExcludedFromLimits[router] = true;
        // Deliberately NOT excluding `pair` here: the pair is one side of every single
        // buy/sell by definition, so excluding it would silently exempt all trading from
        // maxTxAmount/maxWalletAmount - the two limits exist specifically to bound trades
        // through the pair.
        // Repeated buyback-and-burn traffic from GDOGBuybackVault otherwise piles up
        // against BURN_ADDRESS until it exceeds maxWalletAmount and buybacks start
        // reverting. Still fully taxed like any other buy - only the wallet cap is lifted.
        isExcludedFromLimits[BURN_ADDRESS] = true;

        _mint(initialOwner, TOTAL_SUPPLY);
    }

    receive() external payable {}

    // ---------------------------------------------------------------------
    // Core transfer hook (OZ v5 uses _update in place of the old _transfer)
    // ---------------------------------------------------------------------
    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0) || _inSwap) {
            super._update(from, to, amount);
            return;
        }

        bool isBuy = automatedMarketMakerPairs[from];
        bool isSell = automatedMarketMakerPairs[to];
        bool exempt = isExcludedFromLimits[from] || isExcludedFromLimits[to];

        if (!exempt) {
            require(
                tradingEnabled || isExcludedFromFees[from] || isExcludedFromFees[to], "GDOG: trading not enabled"
            );
            if (isBuy || isSell) {
                require(amount <= maxTxAmount, "GDOG: exceeds max tx");
            }
            if (!isSell) {
                require(balanceOf(to) + amount <= maxWalletAmount, "GDOG: exceeds max wallet");
            }
        }

        // Sell-triggered auto-swap of whatever tax has accumulated since the last trigger.
        // Triggering on sells (not buys) avoids reentering the router mid-buy and keeps
        // each swap small and bounded by maxSwapAmount instead of growing unchecked.
        // Uses pendingTaxTokens, NOT balanceOf(address(this)) - the contract's raw token
        // balance also includes liquidityTreasury, which must never be swept into a swap.
        if (isSell && pendingTaxTokens > 0) {
            _swapTaxTokensForEth(pendingTaxTokens);
        }

        bool takeFee = (isBuy || isSell) && !isExcludedFromFees[from] && !isExcludedFromFees[to];
        if (takeFee) {
            uint256 taxBps = currentTaxBps();
            uint256 taxTokens = (amount * taxBps) / BPS_DENOMINATOR;
            if (taxTokens > 0) {
                super._update(from, address(this), taxTokens);
                pendingTaxTokens += taxTokens;
                amount -= taxTokens;
                emit TaxCollected(from, taxTokens, taxBps);
            }
        }

        super._update(from, to, amount);
    }

    /// @notice Current buy/sell tax in bps: 20% at launch block, decaying linearly to 5%
    /// over LAUNCH_DECAY_BLOCKS, flat 5% forever after.
    function currentTaxBps() public view returns (uint256) {
        if (launchBlock == 0) return BASE_TAX_BPS;
        uint256 elapsed = block.number - launchBlock;
        if (elapsed >= LAUNCH_DECAY_BLOCKS) return BASE_TAX_BPS;
        uint256 step = (LAUNCH_TAX_BPS - BASE_TAX_BPS) / LAUNCH_DECAY_BLOCKS;
        return LAUNCH_TAX_BPS - (elapsed * step);
    }

    // ---------------------------------------------------------------------
    // Tax swap + receiver-side distribution
    // ---------------------------------------------------------------------
    function _swapTaxTokensForEth(uint256 pending) private lockTheSwap {
        uint256 amountToSwap = pending > maxSwapAmount ? maxSwapAmount : pending;
        if (amountToSwap == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), amountToSwap);

        uint256 ethBefore = address(this).balance;
        try uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap, 0, path, address(this), block.timestamp
        ) {
            pendingTaxTokens -= amountToSwap;
            uint256 ethReceived = address(this).balance - ethBefore;
            emit TaxSwapped(amountToSwap, ethReceived);
            if (ethReceived > 0) _distributeEth(ethReceived);
        } catch {
            // Thin liquidity or router revert: leave pendingTaxTokens untouched so the
            // next sell trigger retries, rather than reverting the user's transfer.
        }
    }

    function _distributeEth(uint256 ethAmount) private {
        uint256 marketingShare = (ethAmount * MARKETING_FEE_BPS) / BASE_TAX_BPS;
        uint256 devShare = (ethAmount * DEV_FEE_BPS) / BASE_TAX_BPS;
        uint256 liquidityShare = ethAmount - marketingShare - devShare;

        if (marketingShare > 0) _sendEth(marketingWallet, marketingShare);
        if (devShare > 0) _sendEth(buybackVault, devShare);
        if (liquidityShare > 0) _addLiquidityFromTreasury(liquidityShare);

        emit TaxDistributed(marketingShare, devShare, liquidityShare);
    }

    /// @dev Pairs ETH against the pre-funded liquidity treasury, never against tokens
    /// just collected as tax, so a tax event never doubles as an open-market GDOG sale
    /// beyond the single swap already performed in _swapTaxTokensForEth.
    function _addLiquidityFromTreasury(uint256 ethAmount) private {
        if (liquidityTreasury == 0) {
            _sendEth(marketingWallet, ethAmount); // don't strand ETH if treasury is dry
            return;
        }

        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = address(this);
        uint256 quoted = uniswapV2Router.getAmountsOut(ethAmount, path)[1];
        uint256 tokenAmount = quoted > liquidityTreasury ? liquidityTreasury : quoted;
        if (tokenAmount == 0) {
            _sendEth(marketingWallet, ethAmount);
            return;
        }

        liquidityTreasury -= tokenAmount;
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        try uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this), tokenAmount, 0, 0, liquidityLockRecipient, block.timestamp
        ) {} catch {
            liquidityTreasury += tokenAmount;
            _sendEth(marketingWallet, ethAmount);
        }
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "GDOG: ETH send failed");
    }

    // ---------------------------------------------------------------------
    // Treasury funding / launch / admin (bounded - no rug switches)
    // ---------------------------------------------------------------------

    /// @notice Seeds the auto-liquidity treasury from the caller's own balance. Meant to
    /// be called once by the deployer/multisig before enableTrading() using an
    /// allocation carved out of TOTAL_SUPPLY at mint (e.g. from a team/treasury bucket).
    function fundLiquidityTreasury(uint256 amount) external {
        _transfer(msg.sender, address(this), amount);
        liquidityTreasury += amount;
        emit LiquidityTreasuryFunded(msg.sender, amount);
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "GDOG: already enabled");
        require(buybackVault != address(0), "GDOG: buyback vault not set");
        tradingEnabled = true;
        launchBlock = block.number;
        emit TradingEnabled(launchBlock);
    }

    /// @notice Wires up GDOGBuybackVault once, before launch. Only callable pre-trading
    /// so it can never be used to redirect live tax revenue after the fact.
    function setBuybackVault(address newVault) external onlyOwner {
        require(!tradingEnabled, "GDOG: trading already live");
        require(newVault != address(0), "GDOG: zero addr");
        if (buybackVault != address(0)) isExcludedFromFees[buybackVault] = false;
        buybackVault = newVault;
        isExcludedFromFees[newVault] = true;
    }

    /// @notice Limits may only be raised, never re-tightened - prevents the classic
    /// "shrink the max wallet after launch to trap holders" rug pattern.
    function raiseLimits(uint256 newMaxTxAmount, uint256 newMaxWalletAmount) external onlyOwner {
        require(newMaxTxAmount >= maxTxAmount, "GDOG: cannot lower maxTx");
        require(newMaxWalletAmount >= maxWalletAmount, "GDOG: cannot lower maxWallet");
        require(newMaxTxAmount <= TOTAL_SUPPLY && newMaxWalletAmount <= TOTAL_SUPPLY, "GDOG: exceeds supply");
        maxTxAmount = newMaxTxAmount;
        maxWalletAmount = newMaxWalletAmount;
        emit LimitsRaised(newMaxTxAmount, newMaxWalletAmount);
    }

    function setMaxSwapAmount(uint256 newMaxSwapAmount) external onlyOwner {
        require(newMaxSwapAmount <= TOTAL_SUPPLY / 100, "GDOG: cap too high");
        maxSwapAmount = newMaxSwapAmount;
    }

    function excludeFromFees(address account, bool excluded) external onlyOwner {
        isExcludedFromFees[account] = excluded;
    }

    function excludeFromLimits(address account, bool excluded) external onlyOwner {
        isExcludedFromLimits[account] = excluded;
    }

    function setMarketingWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "GDOG: zero addr");
        marketingWallet = newWallet;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != uniswapV2Pair, "GDOG: cannot unset primary pair");
        automatedMarketMakerPairs[pair] = value;
    }

    /// @notice Recovers ERC20s mistakenly sent to the contract - explicitly excludes
    /// GDOG itself so this can never be used to pull the tax/liquidity treasury out.
    function rescueForeignToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(this), "GDOG: cannot rescue GDOG");
        require(ERC20(token).transfer(to, amount), "GDOG: rescue transfer failed");
    }
}
