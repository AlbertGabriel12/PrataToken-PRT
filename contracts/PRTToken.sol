// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract PrataToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint8 public constant DECIMALS = 6;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** DECIMALS; // 1 bilhão com 6 casas decimais

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address defaultAdmin,
        address pauser,
        address operator,
        address upgrader
    ) public initializer {
        __ERC20_init("Prata", "PRT");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ERC20Permit_init("Prata");
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(UPGRADER_ROLE, upgrader);
    }

    function decimals() public view virtual override returns (uint8) {
        return DECIMALS;
    }

    function pause() public onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() public onlyRole(PAUSER_ROLE) { _unpause(); }

    function mint(address to, uint256 amount) public onlyRole(OPERATOR_ROLE) whenNotPaused() {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        _mint(to, amount);
    }

    function burn(uint256 amount) public override onlyRole(OPERATOR_ROLE) whenNotPaused() {
        _burn(msg.sender, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        super._update(from, to, value);
    }
}
