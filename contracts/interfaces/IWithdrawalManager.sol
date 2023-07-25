// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IWithdrawalManager {
    function lockedLiquidity() external view returns (uint256 lockedLiquidity_);
}
