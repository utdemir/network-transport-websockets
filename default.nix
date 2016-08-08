{ pkgs }:

let myHaskellPackages = pkgs.haskellPackages.override {
      overrides = self: super: with pkgs.haskell.lib; {
        network-transport-tests =
          myHaskellPackages.callPackage ../../network-transport-tests {};
        # network-transport = overrideCabal super.network-transport (drv: {
        #   postPatch = ''
        #     sed -i '/^tlog/ d' src/Network/Transport/Internal.hs
        #     cat <<EOF >> src/Network/Transport/Internal.hs
        #     tlog :: MonadIO m => String -> m ()
        #     tlog = liftIO . putStrLn
        #     EOF
        #     ''; 
        # });
      };
    };
in  myHaskellPackages.callPackage ./hs.nix {}
