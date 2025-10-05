// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Cofre de Vesting PR_TOKEN (cliff + vesting linear), revogável opcional
contract VestingVault is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant VESTING_ADMIN_ROLE = keccak256("VESTING_ADMIN_ROLE");

    IERC20 public immutable token;

    struct Grant {
        address beneficiary;
        address funder;
        uint128 total;        // total de tokens alocados
        uint128 released;     // já liberados
        uint64  start;        // timestamp do início (segundos)
        uint64  cliff;        // segundos após start até primeiro desbloqueio
        uint64  duration;     // segundos totais após start para 100%
        bool    revocable;    // pode revogar?
        bool    revoked;      // já foi revogado?
    }

    // grants armazenados em um vetor; referência por ID
    Grant[] public grants;

    // por beneficiário, lista de grantIds
    mapping(address => uint256[]) public grantsByBeneficiary;

    event GrantCreated(uint256 indexed grantId, address indexed beneficiary, address indexed funder, uint256 total);
    event TokensReleased(uint256 indexed grantId, address indexed beneficiary, uint256 amount);
    event GrantRevoked(uint256 indexed grantId, address indexed funder, uint256 refund);

    constructor(IERC20 _token, address admin) {
        token = _token;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VESTING_ADMIN_ROLE, admin);
    }

    // ----- View helpers -----
    function countGrants() external view returns (uint256) { return grants.length; }
    function grantsOf(address beneficiary) external view returns (uint256[] memory) {
        return grantsByBeneficiary[beneficiary];
    }

    /// @notice Quanto está liberável agora (vested - released)
    function releasable(uint256 grantId) public view returns (uint256) {
        Grant memory g = grants[grantId];
        return _vestedAmount(g) - g.released;
    }

    /// @notice Curva linear com cliff
    function _vestedAmount(Grant memory g) internal view returns (uint256) {
        // se já revogado, vested é o que já foi liberado (nada mais progride)
        if (g.revoked) return g.released;

        if (block.timestamp < g.start + g.cliff) {
            return 0;
        }

        if (block.timestamp >= g.start + g.duration) {
            return g.total;
        }

        // linear entre (start+cliff) e (start+duration)
        uint256 elapsed = block.timestamp - g.start;
        // Proporção: elapsed / duration
        // cuidado com precisão — usar Math.mulDiv evita overflow e mantém exatidão
        return Math.mulDiv(g.total, elapsed, g.duration);
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
    function createGrant(
        address beneficiary,
        address funder,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyRole(VESTING_ADMIN_ROLE) returns (uint256 grantId) {
        require(beneficiary != address(0), "beneficiary=0");
        require(funder != address(0), "funder=0");
        require(total > 0, "total=0");
        require(duration > 0, "duration=0");
        require(cliff <= duration, "cliff > duration");

        // Puxar fundos do funder para o cofre
        token.safeTransferFrom(funder, address(this), total);

        Grant memory g = Grant({
            beneficiary: beneficiary,
            funder: funder,
            total: uint128(total),
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revocable: revocable,
            revoked: false
        });

        grantId = grants.length;
        grants.push(g);
        grantsByBeneficiary[beneficiary].push(grantId);

        emit GrantCreated(grantId, beneficiary, funder, total);
    }

    /// @notice Libera tokens já adquiridos (vested) para o beneficiário
    function release(uint256 grantId) external {
        Grant storage g = grants[grantId];
        require(!g.revoked, "revoked");
        uint256 amount = releasable(grantId);
        require(amount > 0, "nothing to release");

        g.released += uint128(amount);
        token.safeTransfer(g.beneficiary, amount);
        emit TokensReleased(grantId, g.beneficiary, amount);
    }

    /// @notice Revoga um grant revogável. Devolve o *não-vested* ao funder.
    /// Pode ser chamado pelo ADMIN; se quiser permitir o próprio funder, mantenha o require abaixo.
    function revoke(uint256 grantId) external onlyRole(VESTING_ADMIN_ROLE) {
        Grant storage g = grants[grantId];
        require(g.revocable, "not revocable");
        require(!g.revoked, "already revoked");

        uint256 vested = _vestedAmount(g);
        uint256 unreleased = vested - g.released;
        uint256 refund = g.total - vested; // não-vested

        g.revoked = true;

        // 1) Pagar qualquer vested pendente ao beneficiário
        if (unreleased > 0) {
            g.released += uint128(unreleased);
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
