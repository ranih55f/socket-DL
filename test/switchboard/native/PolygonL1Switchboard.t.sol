// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../Setup.t.sol";
import "forge-std/Test.sol";
import "../../../contracts/switchboard/native/PolygonL1Switchboard.sol";
import "../../../contracts/TransmitManager.sol";
import "../../../contracts/GasPriceOracle.sol";
import "../../../contracts/ExecutionManager.sol";
import "../../../contracts/CapacitorFactory.sol";
import "../../../contracts/interfaces/ICapacitor.sol";

// Goerli -> Optimism-Goerli
// Switchboard on Goerli (5) for mumbai-testnet (80001) as remote is: 0xDe5c161D61D069B0F2069518BB4110568D465465
// RemoteNativeSwitchBoard i.e SwitchBoard on mumbai-testnet (80001) is:0x029ce68B3A6B3B3713CaC23a39c9096f279c8Ad2
contract PolygonL1SwitchboardTest is Setup {
    bytes32[] roots;

    uint256 initialConfirmationGasLimit_ = 300000;
    uint256 executionOverhead_ = 300000;
    address checkpointManager_ = 0x2890bA17EfE978480615e330ecB65333b880928e;
    address fxRoot_ = 0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA;
    address remoteNativeSwitchboard_ =
        0x029ce68B3A6B3B3713CaC23a39c9096f279c8Ad2;

    IGasPriceOracle gasPriceOracle_;

    PolygonL1Switchboard polygonL1Switchboard;
    ICapacitor singleCapacitor;

    function setUp() external {
        _a.chainSlug = uint32(uint256(5));
        _b.chainSlug = uint32(uint256(80001));

        uint256 fork = vm.createFork(vm.envString("GOERLI_RPC"), 8546583);
        vm.selectFork(fork);

        uint256[] memory transmitterPivateKeys = new uint256[](1);
        transmitterPivateKeys[0] = _transmitterPrivateKey;

        _chainSetup(transmitterPivateKeys);
    }

    function testInitateNativeConfirmation() public {
        address socketAddress = address(_a.socket__);

        vm.startPrank(socketAddress);

        bytes32 packedMessage = _a.hasher__.packMessage(
            _a.chainSlug,
            msg.sender,
            _b.chainSlug,
            0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1,
            0,
            1000000,
            100,
            abi.encode(msg.sender)
        );

        singleCapacitor.addPackedMessage(packedMessage);

        (
            bytes32 root,
            uint256 packetId,
            bytes memory sig
        ) = _getLatestSignature(_a, address(singleCapacitor), _b.chainSlug);
        uint256 capacitorPacketCount = uint256(uint64(packetId));
        polygonL1Switchboard.initateNativeConfirmation(packetId);
        vm.stopPrank();
    }

    function _chainSetup(uint256[] memory transmitterPrivateKeys_) internal {
        _watcher = vm.addr(_watcherPrivateKey);
        _transmitter = vm.addr(_transmitterPrivateKey);

        deployContractsOnSingleChain(_a, _b.chainSlug, transmitterPrivateKeys_);
    }

    function deployContractsOnSingleChain(
        ChainContext storage cc_,
        uint256 remoteChainSlug_,
        uint256[] memory transmitterPrivateKeys_
    ) internal {
        // deploy socket setup
        deploySocket(cc_, _socketOwner);

        hoax(_socketOwner);
        cc_.transmitManager__.setProposeGasLimit(
            remoteChainSlug_,
            _proposeGasLimit
        );

        SocketConfigContext memory scc_ = addPolygonL1Switchboard(
            cc_,
            remoteChainSlug_,
            _capacitorType
        );
        cc_.configs__.push(scc_);

        // add roles
        hoax(_socketOwner);
        cc_.executionManager__.grantRole(EXECUTOR_ROLE, _executor);
        _addTransmitters(transmitterPrivateKeys_, cc_, remoteChainSlug_);
    }

    function deploySocket(
        ChainContext storage cc_,
        address deployer_
    ) internal {
        vm.startPrank(deployer_);

        cc_.hasher__ = new Hasher();
        cc_.sigVerifier__ = new SignatureVerifier();
        cc_.capacitorFactory__ = new CapacitorFactory();
        cc_.gasPriceOracle__ = new GasPriceOracle(deployer_, cc_.chainSlug);
        cc_.executionManager__ = new ExecutionManager(
            cc_.gasPriceOracle__,
            deployer_
        );

        cc_.transmitManager__ = new TransmitManager(
            cc_.sigVerifier__,
            cc_.gasPriceOracle__,
            deployer_,
            cc_.chainSlug,
            _sealGasLimit
        );

        cc_.gasPriceOracle__.setTransmitManager(cc_.transmitManager__);

        cc_.socket__ = new Socket(
            uint32(cc_.chainSlug),
            address(cc_.hasher__),
            address(cc_.transmitManager__),
            address(cc_.executionManager__),
            address(cc_.capacitorFactory__)
        );

        vm.stopPrank();
    }

    function addPolygonL1Switchboard(
        ChainContext storage cc_,
        uint256 remoteChainSlug_,
        uint256 capacitorType_
    ) internal returns (SocketConfigContext memory scc_) {
        polygonL1Switchboard = new PolygonL1Switchboard(
            initialConfirmationGasLimit_,
            executionOverhead_,
            checkpointManager_,
            fxRoot_,
            _socketOwner,
            cc_.gasPriceOracle__
        );

        scc_ = registerSwitchbaord(
            cc_,
            _socketOwner,
            address(polygonL1Switchboard),
            remoteChainSlug_,
            capacitorType_
        );
    }

    function registerSwitchbaord(
        ChainContext storage cc_,
        address deployer_,
        address switchBoardAddress_,
        uint256 remoteChainSlug_,
        uint256 capacitorType_
    ) internal returns (SocketConfigContext memory scc_) {
        vm.startPrank(deployer_);
        cc_.socket__.registerSwitchBoard(
            switchBoardAddress_,
            uint32(remoteChainSlug_),
            uint32(capacitorType_)
        );

        scc_.siblingChainSlug = remoteChainSlug_;
        scc_.capacitor__ = cc_.socket__.capacitors__(
            switchBoardAddress_,
            remoteChainSlug_
        );
        singleCapacitor = scc_.capacitor__;

        scc_.decapacitor__ = cc_.socket__.decapacitors__(
            switchBoardAddress_,
            remoteChainSlug_
        );
        scc_.switchboard__ = ISwitchboard(switchBoardAddress_);

        polygonL1Switchboard.setCapacitor(address(singleCapacitor));

        vm.stopPrank();
    }
}