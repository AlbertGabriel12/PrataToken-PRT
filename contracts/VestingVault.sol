// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title Cofre de Vesting PR_TOKEN (cliff + vesting linear), revogável opcional
contract VestingVault is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant VESTING_ADMIN_ROLE = keccak256("VESTING_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IERC20 public token;

    struct Grant {
        address beneficiary;                // quem recebe os tokens
        address funder;                     // quem fornece os tokens
        uint256 total;                      // total de tokens alocados
        uint256 released;                   // já liberados
        uint256 start;                      // timestamp do início (segundos)
        uint256 cliff;                      // segundos após start até primeiro desbloqueio (segundos)
        uint256 duration;                   // segundos totais após start para 100% (segundos)
        uint16  initialPercentualDeposit;   // percentual *inicial* em basis points (ex: 1000 = 10% | ex: 10000 = 100%)
        bool    revocable;                  // pode revogar?
        bool    revoked;                    // já foi revogado?
    }

    // grants armazenados em um vetor; referência por ID
    Grant[] public grants;

    // por beneficiário, lista de grantIds
    mapping(address => uint256[]) public grantsByBeneficiary;

    event GrantCreated(uint256 indexed grantId, address indexed beneficiary, address indexed funder, uint256 total);
    event TokensReleased(uint256 indexed grantId, address indexed beneficiary, uint256 amount);
    event GrantRevoked(uint256 indexed grantId, address indexed funder, uint256 refund);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _token, address admin) public initializer {
        token = _token;

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VESTING_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ----- External Viewers -----
    function countGrants() external view returns (uint256) { return grants.length; }
    function grantsOf(address beneficiary) external view returns (uint256[] memory) {
        return grantsByBeneficiary[beneficiary];
    }

    /// @notice Quanto está liberável agora (vested - released)
    function releasable(uint256 grantId) public view returns (uint256) {
        Grant memory g = grants[grantId];
        uint256 vested = _vestedAmount(g);
        if (vested <= g.released) {
            return 0;
        }
        return vested - g.released;
    }

    /// @notice Curva linear com cliff
    function _vestedAmount(Grant memory g) internal view returns (uint256) {
        // se já revogado, vested é o que já foi liberado (nada mais progride)
        if (g.revoked) return g.released;

        // Parte inicial (TGE / depósito inicial)
        uint256 initial = Math.mulDiv(g.total, g.initialPercentualDeposit, 100_00);
        uint256 vestingTotal = g.total - initial;

        uint256 start = g.start;
        uint256 cliff = g.cliff;
        uint256 duration = g.duration;

        uint256 cliffTime = start + cliff;
        uint256 endTime = start + duration;

        if (block.timestamp < cliffTime) {
            // Antes do cliff: nada
            return initial;
        }

        if (block.timestamp >= endTime) {
            // Depois do fim: 100% vested
            return g.total;
        }

        // Vesting linear APÓS o cliff para a parte não-inicial
        uint256 elapsedAfterCliff = block.timestamp - cliffTime;
        uint256 vestingDurationAfterCliff = duration - cliff;
        // em createGrant garantimos cliff < duration
        uint256 vestedAfterCliff = Math.mulDiv(
            vestingTotal,
            elapsedAfterCliff,
            vestingDurationAfterCliff
        );

        return initial + vestedAfterCliff;
    }

    // ----- Fluxo principal -----

    /// @notice Cria um grant (funder transfere tokens para o cofre dentro desta função)
    /// @param beneficiary quem receberá o vesting
    /// @param funder      quem fornece os tokens (precisa aprovar antes)
    /// @param total       total de tokens do grant
    /// @param start       timestamp de início (em segundos)
    /// @param cliff       duração do cliff (em segundos) a partir do start
    /// @param duration    duração total (em segundos) a partir do start
    /// @param revocable   se true, VESTING_ADMIN pode revogar; funder também pode ser permitido
    /// @param initialPercentualDeposit percentual para deposito inicial
    function createGrant(
        address beneficiary,
        address funder,
        uint256 total,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        bool revocable,
        uint16 initialPercentualDeposit
    ) external onlyRole(VESTING_ADMIN_ROLE) returns (uint256 grantId) {
        require(beneficiary != address(0), "beneficiary cant is zero");
        require(funder != address(0), "funder cant is zero");
        require(total > 0, "total cant is zero");
        require(duration > 0, "duration cant is zero");
        require(cliff < duration, "cliff must been less than duration");
        require(initialPercentualDeposit <= 10000, "initialPercentualDeposit must been less or equal than 10000, percentual basisPoint");

        // Puxar fundos do funder para o cofre
        token.safeTransferFrom(funder, address(this), total);

        Grant memory g = Grant({
            beneficiary: beneficiary,
            funder: funder,
            total: total,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revocable: revocable,
            revoked: false,
            initialPercentualDeposit: initialPercentualDeposit
        });

        grantId = grants.length;
        grants.push(g);
        grantsByBeneficiary[beneficiary].push(grantId);

        // se initialPercentualDeposit for maior do que zero enviar tokens para endereço
        uint256 initialDepositAmount = Math.mulDiv(total, initialPercentualDeposit, 10_000);
        if (initialDepositAmount > 0) {
            Grant storage gs = grants[grantId];
            gs.released = initialDepositAmount;
            token.safeTransfer(beneficiary, initialDepositAmount);
            
            emit TokensReleased(grantId, beneficiary, initialDepositAmount);
        }

        emit GrantCreated(grantId, beneficiary, funder, total);
    }

    /// @notice Libera tokens já adquiridos (vested) para o beneficiário
    function release(uint256 grantId) external nonReentrant {
        Grant storage g = grants[grantId];
        require(!g.revoked, "revoked");
        uint256 amount = releasable(grantId);
        require(amount > 0, "nothing to release");

        g.released += amount;
        token.safeTransfer(g.beneficiary, amount);
        emit TokensReleased(grantId, g.beneficiary, amount);
    }

    /// @notice Revoga um grant revogável. Devolve o *não-vested* ao funder.
    /// Pode ser chamado pelo ADMIN; se quiser permitir o próprio funder, mantenha o require abaixo.
    function revoke(uint256 grantId) external onlyRole(VESTING_ADMIN_ROLE) nonReentrant {
        Grant storage g = grants[grantId];
        require(g.revocable, "not revocable");
        require(!g.revoked, "already revoked");

        uint256 vested = _vestedAmount(g);
        uint256 unreleased;
        if (vested > g.released) {
            unreleased = vested - g.released;
        } else {
            unreleased = 0;
        }
        uint256 refund = g.total - vested; // não-vested

        g.revoked = true;

        // 1) Pagar qualquer vested pendente ao beneficiário
        if (unreleased > 0) {
            g.released += unreleased;
            token.safeTransfer(g.beneficiary, unreleased);
            emit TokensReleased(grantId, g.beneficiary, unreleased);
        }

        // 2) Devolver não-vested ao funder
        if (refund > 0) {
            token.safeTransfer(g.funder, refund);
        }

        emit GrantRevoked(grantId, g.funder, refund);
    }
}
