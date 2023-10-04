// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Errors } from "contracts/libraries/Errors.sol";

import { LopoGlobals_Integration_Concrete_Test } from "../LopoGlobals.t.sol";
import { Callable_Integration_Shared_Test } from "tests/integration/shared/lopo-globals/callable.t.sol";

contract SetValidPoolAdmin_Integration_Concrete_Test is
    LopoGlobals_Integration_Concrete_Test,
    Callable_Integration_Shared_Test
{
    function setUp() public virtual override(LopoGlobals_Integration_Concrete_Test, Callable_Integration_Shared_Test) {
        LopoGlobals_Integration_Concrete_Test.setUp();
    }

    function test_RevertWhen_CallerNotGovernor() external {
        changePrank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Errors.Globals_CallerNotGovernor.selector, users.governor, users.eve));
        lopoGlobals.setValidPoolAdmin(address(users.poolAdmin), false);
    }

    function test_SetValidPoolAdmin() external whenCallerGovernor {
        assertEq(lopoGlobals.isPoolAdmin(address(users.poolAdmin)), true);

        vm.expectEmit(true, true, true, true);
        emit ValidPoolAdminSet(address(users.poolAdmin), false);
        lopoGlobals.setValidPoolAdmin(address(users.poolAdmin), false);

        assertEq(lopoGlobals.isPoolAdmin(address(users.poolAdmin)), false);
    }
}