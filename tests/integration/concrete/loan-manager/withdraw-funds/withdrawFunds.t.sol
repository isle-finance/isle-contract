// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { Errors } from "contracts/libraries/Errors.sol";

import { LoanManager_Integration_Concrete_Test } from "../LoanManager.t.sol";
import { Callable_Integration_Shared_Test } from "../../../shared/loan-manager/callable.t.sol";

contract WithdrawFunds_Integration_Concrete_Test is
    LoanManager_Integration_Concrete_Test,
    Callable_Integration_Shared_Test
{
    function setUp() public virtual override(LoanManager_Integration_Concrete_Test, Callable_Integration_Shared_Test) {
        LoanManager_Integration_Concrete_Test.setUp();
        Callable_Integration_Shared_Test.setUp();

        createDefaultLoan();
    }

    modifier WhenCallerLoanSeller() {
        _;
    }

    modifier WhenWithdrawAmountLessThanOrEqualToDrawableAmount() {
        _;
    }

    modifier WhenBuyerRepayLoan() {
        _;
    }

    function test_RevertWhen_FunctionPaused() external {
        changePrank(users.governor);
        lopoGlobals.setContractPause(address(loanManager), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.FunctionPaused.selector, bytes4(keccak256("withdrawFunds(uint16,address,uint256)"))
            )
        );
        loanManager.withdrawFunds(1, address(0), 0);
    }

    function test_RevertWhen_CallerNotLoanSeller() external WhenNotPaused {
        changePrank(users.caller);
        vm.expectRevert(abi.encodeWithSelector(Errors.LoanManager_CallerNotSeller.selector, users.seller));
        loanManager.withdrawFunds(1, address(0), 0);
    }

    function test_RevertWhen_WithdrawAmountGreaterThanDrawableAmount() external WhenNotPaused WhenCallerLoanSeller {
        changePrank(users.seller);
        uint256 principalRequested = defaults.PRINCIPAL_REQUESTED();
        vm.expectRevert(
            abi.encodeWithSelector(Errors.LoanManager_Overdraw.selector, 1, principalRequested + 1, principalRequested)
        );
        loanManager.withdrawFunds(1, address(users.seller), principalRequested + 1);
    }

    function test_WithdrawFunds_WhenBuyerNotRepayLoan()
        external
        WhenNotPaused
        WhenCallerLoanSeller
        WhenWithdrawAmountLessThanOrEqualToDrawableAmount
    {
        changePrank(users.seller);
        uint256 principalRequested = defaults.PRINCIPAL_REQUESTED();
        uint256 loanManagerBalanceBefore = usdc.balanceOf(address(loanManager));

        IERC721 receivable = IERC721(address(receivable));

        receivable.approve(address(loanManager), defaults.RECEIVABLE_TOKEN_ID());

        vm.expectEmit(true, true, true, true);
        emit FundsWithdrawn(1, principalRequested);

        loanManager.withdrawFunds(1, address(users.seller), principalRequested);

        uint256 loanManagerBalanceAfter = usdc.balanceOf(address(loanManager));

        assertEq(receivable.balanceOf(address(users.seller)), 0);
        assertEq(receivable.balanceOf(address(loanManager)), 1);
        assertEq(loanManagerBalanceAfter, loanManagerBalanceBefore - principalRequested);
    }

    function test_WithdrawFunds()
        external
        WhenNotPaused
        WhenCallerLoanSeller
        WhenWithdrawAmountLessThanOrEqualToDrawableAmount
        WhenBuyerRepayLoan
    {
        changePrank(users.buyer);
        loanManager.repayLoan(1);

        changePrank(users.seller);
        uint256 principalRequested = defaults.PRINCIPAL_REQUESTED();
        uint256 loanManagerBalanceBefore = usdc.balanceOf(address(loanManager));

        IERC721 receivable = IERC721(address(receivable));

        receivable.approve(address(loanManager), defaults.RECEIVABLE_TOKEN_ID());

        vm.expectEmit(true, true, true, true);
        emit AssetBurned(defaults.RECEIVABLE_TOKEN_ID());

        vm.expectEmit(true, true, true, true);
        emit FundsWithdrawn(1, principalRequested);

        loanManager.withdrawFunds(1, address(users.seller), principalRequested);

        uint256 loanManagerBalanceAfter = usdc.balanceOf(address(loanManager));

        // check the receivable token is transferred and burned in the same transaction
        assertEq(receivable.balanceOf(address(users.seller)), 0);
        assertEq(receivable.balanceOf(address(loanManager)), 0);
        assertEq(loanManagerBalanceAfter, loanManagerBalanceBefore - principalRequested);
    }
}
