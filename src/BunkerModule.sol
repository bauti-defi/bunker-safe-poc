// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISafe} from "@safe/interfaces/ISafe.sol";
import {Enum} from "@safe/libraries/Enum.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BunkerModule
/// @notice Safe module driven by a one-time ECDSA "hot key" ("bunker mode").
///
///         The Safe's only owner is a break-glass key that never signs in normal operation, so its
///         public key stays hidden behind its address hash. Day-to-day operations are signed by the
///         module's hot key, which is also known only by address. Every signature the hot key produces
///         burns it: the module rotates to the signed `nextHotKey` before running the payload.
///
/// @dev Trust model: the hot key holder (operator) is trusted with the Safe, so the payload is not
///      restricted. The adversary recovers private keys from exposed public keys, which takes far
///      longer than inclusion. The module only guarantees that an exposed key is worthless:
///
///      Invariant: once a valid signature by the current hot key is public, anyone can submit it, and
///      any submission that does not revert revokes that key. No payload outcome (revert, invalid
///      operation, expiry) can undo the rotation. The only reverts are:
///        - the signer is not (or no longer) the hot key: the signature has no authority to protect;
///        - not enough gas for a payload that will run: the signature stays valid and anyone can
///          resubmit it with more gas.
///      There is deliberately no nonce: a hot key signs exactly one op and a burned key can never be
///      reinstated, so burning the key is the replay protection.
contract BunkerModule is EIP712, ReentrancyGuard {
    /// @notice One Safe transaction plus rotation parameters. Mirrors the Safe tx shape
    ///         `(to, value, data, operation)`; batch by DELEGATECALLing MultiSendCallOnly.
    /// @param operation 0 = CALL, 1 = DELEGATECALL. Kept as uint8 so an out-of-range value is handled
    ///        as a rotation-only op instead of failing ABI decoding, which would publish the signature
    ///        without rotating.
    /// @param nextHotKey Address of the fresh key that replaces the signer. Its freshness (no exposed
    ///        public key) cannot be proven on-chain and is an operator assumption.
    /// @param deadline Last timestamp at which the payload may run. After it, the op only rotates.
    /// @param minPayloadGas Gas the submitter must make available to the payload, so a relayer
    ///        cannot burn the key while starving the payload.
    struct Op {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
        address nextHotKey;
        uint256 deadline;
        uint256 minPayloadGas;
    }

    enum Outcome {
        Executed,
        PayloadReverted,
        InvalidOperation,
        Expired,
        Frozen
    }

    bytes32 public constant OP_TYPEHASH = keccak256(
        "Op(address to,uint256 value,bytes data,uint8 operation,address nextHotKey,uint256 deadline,uint256 minPayloadGas)"
    );

    /// @dev Gas kept back for the work after the payload call (event + return).
    uint256 public constant POST_PAYLOAD_GAS_RESERVE = 30_000;

    ISafe public immutable SAFE;

    /// @notice Current one-time signing key. `address(0)` means frozen: only the Safe can unfreeze.
    address public hotKey;

    /// @notice Keys that have been used or replaced. A burned key can never become the hot key again.
    mapping(address key => bool) public burned;

    event HotKeyRotated(address indexed previous, address indexed next);
    event OpExecuted(bytes32 indexed opHash, Outcome outcome, bytes revertData);

    error ZeroSafe();
    error InvalidHotKey(address key);
    error NotHotKey(address recovered);
    error ModuleFrozen();
    error OnlySafe();
    error InsufficientGas(uint256 available, uint256 required);

    constructor(ISafe safe, address initialHotKey) EIP712("BunkerModule", "1") {
        if (address(safe) == address(0)) revert ZeroSafe();
        SAFE = safe;
        if (!_isValidNextHotKey(initialHotKey)) revert InvalidHotKey(initialHotKey);
        hotKey = initialHotKey;
        emit HotKeyRotated(address(0), initialHotKey);
    }

    /// @notice Executes an op signed by the current hot key. Callable by anyone.
    function execute(Op calldata op, bytes calldata signature) external nonReentrant returns (Outcome outcome) {
        address signer = hotKey;
        if (signer == address(0)) revert ModuleFrozen();

        bytes32 opHash = hashOp(op);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(opHash, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert NotHotKey(recovered);

        // Effects first: the signer's public key is now public, so it loses authority before any
        // external interaction.
        burned[signer] = true;
        address next = op.nextHotKey;
        bool nextValid = _isValidNextHotKey(next);
        address installed = nextValid ? next : address(0);
        hotKey = installed;
        emit HotKeyRotated(signer, installed);

        bytes memory revertData;
        if (!nextValid) {
            outcome = Outcome.Frozen;
        } else if (block.timestamp > op.deadline) {
            outcome = Outcome.Expired;
        } else if (op.operation > uint8(type(Enum.Operation).max)) {
            outcome = Outcome.InvalidOperation;
        } else {
            (outcome, revertData) = _runPayload(op);
        }
        emit OpExecuted(opHash, outcome, revertData);
    }

    /// @notice Break-glass path: the Safe (signed by its owner) installs a new hot key or freezes the
    ///         module with `address(0)`. The replaced key is burned.
    function setHotKey(address next) external {
        if (msg.sender != address(SAFE)) revert OnlySafe();
        address previous = hotKey;
        if (previous != address(0)) burned[previous] = true;
        if (next != address(0) && !_isValidNextHotKey(next)) revert InvalidHotKey(next);
        hotKey = next;
        emit HotKeyRotated(previous, next);
    }

    /// @notice EIP-712 digest the hot key signs for `op`.
    function hashOp(Op calldata op) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OP_TYPEHASH,
                    op.to,
                    op.value,
                    keccak256(op.data),
                    op.operation,
                    op.nextHotKey,
                    op.deadline,
                    op.minPayloadGas
                )
            )
        );
    }

    /// @dev Runs the payload through the Safe. The Safe reports a failed payload as `false` instead of
    ///      reverting (and MultiSend rolls back a whole batch), so a failed payload never undoes the
    ///      rotation done by `execute`.
    function _runPayload(Op calldata op) private returns (Outcome, bytes memory revertData) {
        uint256 required = (op.minPayloadGas * 64) / 63 + POST_PAYLOAD_GAS_RESERVE;
        if (gasleft() < required) revert InsufficientGas(gasleft(), required);
        bool success;
        (success, revertData) =
            SAFE.execTransactionFromModuleReturnData(op.to, op.value, op.data, Enum.Operation(op.operation));
        return success ? (Outcome.Executed, bytes("")) : (Outcome.PayloadReverted, revertData);
    }

    /// @dev Zero is the frozen sentinel. A burned key must never return: its public key may be
    ///      exposed, and reinstating it would make its old signatures replayable.
    function _isValidNextHotKey(address key) private view returns (bool) {
        return key != address(0) && !burned[key];
    }
}
