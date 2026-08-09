// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only Uniswap V2 clone: real constant-product (x*y=k) math with the
/// standard 0.3% swap fee, sized to exactly the surface GDOGToken/GDOGBuybackVault
/// call through IUniswapV2Router02. Not gas-optimized, no flash-swap callback, no
/// TWAP oracle - just enough real AMM behavior to exercise the token's fee-on-transfer
/// hooks honestly instead of mocking away the thing under test.

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: withdraw failed");
    }

    receive() external payable {
        deposit();
    }
}

contract MockUniswapV2Pair is ERC20 {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public factory;
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor() ERC20("Mock LP", "MLP") {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "Pair: FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function _sync() private {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function mint(address to) external returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdEaD), MINIMUM_LIQUIDITY);
        } else {
            uint256 fromToken0 = (amount0 * _totalSupply) / _reserve0;
            uint256 fromToken1 = (amount1 * _totalSupply) / _reserve1;
            liquidity = fromToken0 < fromToken1 ? fromToken0 : fromToken1;
        }
        require(liquidity > 0, "Pair: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _sync();
    }

    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf(address(this));
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 _totalSupply = totalSupply();

        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "Pair: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);
        _sync();
    }

    /// @dev Mirrors real UniswapV2Pair.swap: computes the *actual* amount received
    /// from the balance delta (not a caller-supplied amountIn), so fee-on-transfer
    /// tokens like GDOG are handled correctly, then enforces the K invariant net of
    /// the 0.3% fee.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "Pair: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "Pair: INSUFFICIENT_LIQUIDITY");

        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "Pair: INSUFFICIENT_INPUT_AMOUNT");

        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(
            balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * 1_000_000, "Pair: K"
        );

        _sync();
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair);

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Factory: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Factory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Factory: PAIR_EXISTS");

        MockUniswapV2Pair newPair = new MockUniswapV2Pair();
        newPair.initialize(token0, token1);
        pair = address(newPair);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair);
    }
}

/// @dev Implements only the function signatures GDOGToken/GDOGBuybackVault actually
/// call. Deliberately does not `is IUniswapV2Router02` - the interface declares
/// factory()/WETH() as `pure` (matching the real router, whose auto-generated
/// immutable getters satisfy that), while this mock reads a normal state variable and
/// is `view`; callers dispatch by selector, so the mutability keyword never matters
/// off-chain of the ABI.
contract MockUniswapV2Router02 {
    MockUniswapV2Factory public immutable uniFactory;
    MockWETH public immutable weth;

    constructor(MockUniswapV2Factory _factory, MockWETH _weth) {
        uniFactory = _factory;
        weth = _weth;
    }

    receive() external payable {}

    function factory() external view returns (address) {
        return address(uniFactory);
    }

    function WETH() external view returns (address) {
        return address(weth);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        require(path.length == 2, "Router: unsupported path length");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(path[0], path[1]);
        amounts[1] = _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256, /* amountTokenMin */
        uint256, /* amountETHMin */
        address to,
        uint256 /* deadline */
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        address pairAddr = uniFactory.getPair(token, address(weth));
        if (pairAddr == address(0)) pairAddr = uniFactory.createPair(token, address(weth));

        amountToken = amountTokenDesired;
        amountETH = msg.value;

        require(IERC20(token).transferFrom(msg.sender, pairAddr, amountToken), "Router: transferFrom failed");
        weth.deposit{value: amountETH}();
        require(weth.transfer(pairAddr, amountETH), "Router: WETH transfer failed");

        liquidity = MockUniswapV2Pair(pairAddr).mint(to);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external {
        require(path.length == 2 && path[1] == address(weth), "Router: INVALID_PATH");
        address pairAddr = uniFactory.getPair(path[0], address(weth));
        require(pairAddr != address(0), "Router: NO_PAIR");

        require(IERC20(path[0]).transferFrom(msg.sender, pairAddr, amountIn), "Router: transferFrom failed");

        // Reserves are read AFTER the transfer, not before - matching real
        // UniswapV2Router02's _swapSupportingFeeOnTransferTokens exactly. This matters
        // because a fee-on-transfer token's transfer hook can itself trigger nested
        // pair.swap()/mint() activity (e.g. GDOGToken's own tax-swap-and-liquify) before
        // this function ever runs; reading reserves now picks up the post-hook synced
        // state, so the delta below reflects only this trade's own input, not whatever
        // the token's hook did to the pair in between.
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(path[0], address(weth));
        uint256 actualAmountIn = IERC20(path[0]).balanceOf(pairAddr) - reserveIn;
        uint256 amountOut = _getAmountOut(actualAmountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");

        address token0 = MockUniswapV2Pair(pairAddr).token0();
        (uint256 amount0Out, uint256 amount1Out) =
            path[0] == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        MockUniswapV2Pair(pairAddr).swap(amount0Out, amount1Out, address(this));

        weth.withdraw(amountOut);
        (bool ok,) = to.call{value: amountOut}("");
        require(ok, "Router: ETH_TRANSFER_FAILED");
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external payable {
        require(path.length == 2 && path[0] == address(weth), "Router: INVALID_PATH");
        address pairAddr = uniFactory.getPair(address(weth), path[1]);
        require(pairAddr != address(0), "Router: NO_PAIR");

        weth.deposit{value: msg.value}();
        require(weth.transfer(pairAddr, msg.value), "Router: WETH transfer failed");

        (uint256 reserveIn, uint256 reserveOut) = _getReserves(address(weth), path[1]);
        uint256 amountOut = _getAmountOut(msg.value, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");

        address token0 = MockUniswapV2Pair(pairAddr).token0();
        (uint256 amount0Out, uint256 amount1Out) =
            address(weth) == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        MockUniswapV2Pair(pairAddr).swap(amount0Out, amount1Out, to);
    }

    function _getReserves(address tokenA, address tokenB) internal view returns (uint256, uint256) {
        address pairAddr = uniFactory.getPair(tokenA, tokenB);
        address token0 = MockUniswapV2Pair(pairAddr).token0();
        (uint112 reserve0, uint112 reserve1) = MockUniswapV2Pair(pairAddr).getReserves();
        return tokenA == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        require(amountIn > 0, "Router: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "Router: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        return numerator / denominator;
    }
}
