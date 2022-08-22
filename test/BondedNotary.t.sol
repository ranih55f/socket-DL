// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Notary/BondedNotary.sol";
import "../src/interfaces/IAccumulator.sol";
import "../src/utils/SignatureVerifier.sol";

contract SocketTest is Test {
    address constant _owner = address(1);
    uint256 constant _signerPrivateKey = uint256(2);
    address constant _accum = address(3);
    bytes32 constant _root = bytes32(uint256(4));
    uint256 constant _packetId = uint256(5);
    address _signer;
    address constant _raju = address(6);
    bytes32 constant _altRoot = bytes32(uint256(7));

    uint256 constant _minBondAmount = 100e18;
    uint256 constant _bondClaimDelay = 1 weeks;
    uint256 constant _chainId = 0x2013AA263;
    uint256 constant _remoteChainId = 0x2013AA264;

    Notary _notary;
    SignatureVerifier _sigVerifier;

    function setUp() external {
        _signer = vm.addr(_signerPrivateKey);
        _sigVerifier = new SignatureVerifier();

        hoax(_owner);
        _notary = new Notary(
            _minBondAmount,
            _bondClaimDelay,
            _chainId,
            address(_sigVerifier)
        );
    }

    function testDeployment() external {
        assertEq(_notary.owner(), _owner);
        assertEq(_notary.minBondAmount(), _minBondAmount);
        assertEq(_notary.bondClaimDelay(), _bondClaimDelay);
        assertEq(_notary.chainId(), _chainId);
    }

    function testAddBond() external {
        uint256 amount = 100e18;
        hoax(_signer);
        _notary.addBond{value: amount}();
        assertEq(_notary.getBond(_signer), amount);
    }

    function testReduceValidAmount() external {
        uint256 initialAmount = 150e18;
        uint256 reduceAmount = 10e18;

        assertGe(initialAmount - reduceAmount, _minBondAmount);

        startHoax(_signer, initialAmount);
        _notary.addBond{value: initialAmount}();
        _notary.reduceBond(reduceAmount);

        assertEq(_notary.getBond(_signer), initialAmount - reduceAmount);
        assertEq(_signer.balance, reduceAmount);
    }

    function testReduceInvalidAmount() external {
        uint256 initialAmount = 150e18;
        uint256 reduceAmount = 90e18;

        assertLt(initialAmount - reduceAmount, _minBondAmount);

        startHoax(_signer, initialAmount);
        _notary.addBond{value: initialAmount}();
        vm.expectRevert(INotary.InvalidBondReduce.selector);
        _notary.reduceBond(reduceAmount);
    }

    function testUnbondSigner() external {
        uint256 amount = 150e18;
        uint256 claimTime = block.timestamp + _bondClaimDelay;

        startHoax(_signer, amount);
        _notary.addBond{value: amount}();
        _notary.unbondSigner();

        assertEq(_notary.getBond(_signer), 0);
        (uint256 unbondAmount, uint256 unbondClaimTime) = _notary.getUnbondData(
            _signer
        );
        assertEq(unbondAmount, amount);
        assertEq(unbondClaimTime, claimTime);
    }

    function testClaimBondBeforeDelay() external {
        uint256 amount = 150e18;
        uint256 claimTime = block.timestamp + _bondClaimDelay;

        startHoax(_signer, amount);
        _notary.addBond{value: amount}();
        _notary.unbondSigner();

        vm.warp(claimTime - 10);
        vm.expectRevert(INotary.ClaimTimeLeft.selector);
        _notary.claimBond();

        assertEq(_notary.getBond(_signer), 0);
        (uint256 unbondAmount, uint256 unbondClaimTime) = _notary.getUnbondData(
            _signer
        );
        assertEq(unbondAmount, amount);
        assertEq(unbondClaimTime, claimTime);
        assertEq(_signer.balance, 0);
    }

    function testClaimBondAfterDelay() external {
        uint256 amount = 150e18;
        uint256 claimTime = block.timestamp + _bondClaimDelay;

        startHoax(_signer, amount);
        _notary.addBond{value: amount}();
        _notary.unbondSigner();

        vm.warp(claimTime + 10);
        _notary.claimBond();

        assertEq(_notary.getBond(_signer), 0);
        (uint256 unbondAmount, uint256 unbondClaimTime) = _notary.getUnbondData(
            _signer
        );
        assertEq(unbondAmount, 0);
        assertEq(unbondClaimTime, 0);
        assertEq(_signer.balance, amount);
    }

    function testSubmitSignature() external {
        startHoax(_signer);
        _notary.addBond{value: _minBondAmount}();

        vm.mockCall(
            _accum,
            abi.encodeWithSelector(IAccumulator.sealPacket.selector),
            abi.encode(_root, _packetId)
        );

        bytes32 digest = keccak256(
            abi.encode(_chainId, _accum, _packetId, _root)
        );

        _notary.submitSignature(_accum, _getSignature(digest));
    }

    function testSubmitSignatureWithoutEnoughBond() external {
        startHoax(_signer);
        _notary.addBond{value: _minBondAmount / 2}();

        vm.mockCall(
            _accum,
            abi.encodeWithSelector(IAccumulator.sealPacket.selector),
            abi.encode(_root, _packetId)
        );

        bytes32 digest = keccak256(
            abi.encode(_chainId, _accum, _packetId, _root)
        );

        vm.expectRevert(INotary.InvalidBond.selector);
        _notary.submitSignature(_accum, _getSignature(digest));
    }

    function testChallengeSignature() external {
        hoax(_signer, 150e18);
        _notary.addBond{value: 120e18}();

        vm.mockCall(
            _accum,
            abi.encodeWithSelector(IAccumulator.sealPacket.selector),
            abi.encode(_root, _packetId)
        );

        bytes32 digest = keccak256(
            abi.encode(_chainId, _accum, _packetId, _root)
        );

        _notary.submitSignature(_accum, _getSignature(digest));

        bytes32 altDigest = keccak256(
            abi.encode(_chainId, _accum, _packetId, _altRoot)
        );

        hoax(_raju, 0);
        _notary.challengeSignature(
            _accum,
            _altRoot,
            _packetId,
            _getSignature(altDigest)
        );

        assertEq(_signer.balance, 30e18);
        assertEq(_raju.balance, 120e18);
        assertEq(address(_notary).balance, 0);
    }

    function testSubmitRemoteRoot() external {
        bytes32 digest = keccak256(
            abi.encode(_remoteChainId, _accum, _packetId, _root)
        );

        hoax(_owner);
        _notary.grantSignerRole(_remoteChainId, _signer);

        hoax(_raju);
        _notary.submitRemoteRoot(
            _remoteChainId,
            _accum,
            _packetId,
            _root,
            _getSignature(digest)
        );

        assertEq(
            _notary.getRemoteRoot(_remoteChainId, _accum, _packetId),
            _root
        );
    }

    function testSubmitRemoteRootWithoutRole() external {
        bytes32 digest = keccak256(
            abi.encode(_remoteChainId, _accum, _packetId, _root)
        );

        hoax(_raju);
        vm.expectRevert(INotary.InvalidSigner.selector);
        _notary.submitRemoteRoot(
            _remoteChainId,
            _accum,
            _packetId,
            _root,
            _getSignature(digest)
        );
    }

    function _getSignature(bytes32 digest) internal returns (bytes memory sig) {
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(
            _signerPrivateKey,
            digest
        );

        sig = new bytes(65);
        bytes1 v32 = bytes1(sigV);

        assembly {
            mstore(add(sig, 96), v32)
            mstore(add(sig, 32), sigR)
            mstore(add(sig, 64), sigS)
        }
    }
}
