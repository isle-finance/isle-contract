// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { VersionedInitializable } from "./libraries/upgradability/VersionedInitializable.sol";
import { Errors } from "./libraries/Errors.sol";

import { Adminable } from "./abstracts/Adminable.sol";

import { IIsleGlobals } from "./interfaces/IIsleGlobals.sol";

contract IsleGlobals is IIsleGlobals, VersionedInitializable, Adminable, UUPSUpgradeable {
    uint256 public constant LOPO_GLOBALS_REVISION = 0x1;
    uint256 public constant HUNDRED_ = 1_000_000; // 100.0000%

    /*//////////////////////////////////////////////////////////////////////////
                            UUPS FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address newImplementation_) internal override onlyAdmin { }

    function getImplementation() external view override returns (address implementation_) {
        implementation_ = _getImplementation();
    }

    /// @inheritdoc VersionedInitializable
    function getRevision() internal pure virtual override returns (uint256 revision_) {
        revision_ = LOPO_GLOBALS_REVISION;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////////////////*/

    uint24 public override protocolFee; // 100.0000%
    address public override isleVault;

    bool public override protocolPaused;
    mapping(address => bool) public override isContractPaused;
    mapping(address => mapping(bytes4 => bool)) public override isFunctionUnpaused;
    mapping(address => bool) public override isPoolAdmin;
    mapping(address => bool) public override isCollateralAsset;
    mapping(address => bool) public override isPoolAsset;

    /*//////////////////////////////////////////////////////////////////////////
                                INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIsleGlobals
    function initialize(address governor_) external override initializer {
        admin = governor_;
        emit Initialized();
    }

    /*//////////////////////////////////////////////////////////////////////////
                        EXTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIsleGlobals
    function setIsleVault(address vault_) external override onlyAdmin {
        if (vault_ == address(0)) {
            revert Errors.Globals_InvalidVault(vault_);
        }
        emit IsleVaultSet(isleVault, vault_);
        isleVault = vault_;
    }

    /// @inheritdoc IIsleGlobals
    function setProtocolPaused(bool protocolPaused_) external override onlyAdmin {
        emit ProtocolPausedSet(msg.sender, protocolPaused = protocolPaused_);
    }

    /// @inheritdoc IIsleGlobals
    function setContractPaused(address contract_, bool contractPaused_) external override onlyAdmin {
        emit ContractPausedSet(msg.sender, contract_, isContractPaused[contract_] = contractPaused_);
    }

    /// @inheritdoc IIsleGlobals
    function setFunctionUnpaused(address contract_, bytes4 sig_, bool functionUnpaused_) external override onlyAdmin {
        emit FunctionUnpausedSet(msg.sender, contract_, sig_, isFunctionUnpaused[contract_][sig_] = functionUnpaused_);
    }

    /// @inheritdoc IIsleGlobals
    function setProtocolFee(uint24 protocolFee_) external override onlyAdmin {
        emit ProtocolFeeSet(protocolFee = protocolFee_);
    }

    /// @inheritdoc IIsleGlobals
    function setValidCollateralAsset(address collateralAsset_, bool isValid_) external override onlyAdmin {
        isCollateralAsset[collateralAsset_] = isValid_;
        emit ValidCollateralAssetSet(collateralAsset_, isValid_);
    }

    /// @inheritdoc IIsleGlobals
    function setValidPoolAsset(address poolAsset_, bool isValid_) external override onlyAdmin {
        isPoolAsset[poolAsset_] = isValid_;
        emit ValidPoolAssetSet(poolAsset_, isValid_);
    }

    /// @inheritdoc IIsleGlobals
    function setValidPoolAdmin(address poolAdmin_, bool isValid_) external override onlyAdmin {
        isPoolAdmin[poolAdmin_] = isValid_;
        emit ValidPoolAdminSet(poolAdmin_, isValid_);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            EXTERNAL CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIsleGlobals
    function governor() external view override returns (address governor_) {
        governor_ = admin;
    }

    /// @inheritdoc IIsleGlobals
    function isFunctionPaused(address contract_, bytes4 sig_) public view override returns (bool functionIsPaused_) {
        functionIsPaused_ = (protocolPaused || isContractPaused[contract_]) && !isFunctionUnpaused[contract_][sig_];
    }

    /// @inheritdoc IIsleGlobals
    function isFunctionPaused(bytes4 sig_) external view override returns (bool functionIsPaused_) {
        functionIsPaused_ = isFunctionPaused(msg.sender, sig_);
    }
}
