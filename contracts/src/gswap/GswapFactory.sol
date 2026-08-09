// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IGswapFactory} from "./interfaces/IGswap.sol";
import {GswapPair} from "./GswapPair.sol";

contract GswapFactory is IGswapFactory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Gswap: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Gswap: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Gswap: PAIR_EXISTS");

        GswapPair newPair = new GswapPair{salt: keccak256(abi.encodePacked(token0, token1))}();
        newPair.initialize(token0, token1);
        pair = address(newPair);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "Gswap: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "Gswap: FORBIDDEN");
        require(_feeToSetter != address(0), "Gswap: ZERO_ADDRESS");
        feeToSetter = _feeToSetter;
    }
}
