{ inputs, lib, pkgs, ... }:

{
  imports = [
    (inputs.ray-devenv + "/profiles/config.nix")
  ]
  ++ lib.optional (builtins.pathExists ./devenv.local.nix) ./devenv.local.nix;

  packages = with pkgs; [
    age
  ];
}
