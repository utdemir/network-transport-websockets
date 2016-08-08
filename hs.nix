{ mkDerivation, base, binary, bytestring, containers, deepseq
, hslogger, network, network-transport, network-transport-tests
, random, stdenv, wai, wai-websockets, warp, websockets
}:
mkDerivation {
  pname = "network-transport-websockets";
  version = "0.0.1.0";
  src = ./.;
  libraryHaskellDepends = [
    base binary bytestring containers deepseq hslogger
    network-transport random websockets
  ];
  testHaskellDepends = [
    base bytestring hslogger network network-transport
    network-transport-tests wai wai-websockets warp websockets
  ];
  license = stdenv.lib.licenses.bsd3;
}
