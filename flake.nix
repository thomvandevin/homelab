{
  description = "Homelab NixOS Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    # Disko
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      ...
    }@inputs:
    let
      nodes = [
        "homelab-0"
        "homelab-1"
        "homelab-2"
      ];
    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (name: {
          name = name;
          value = nixpkgs.lib.nixosSystem {
            specialArgs = {
              meta = {
                hostname = name;
              };
            };
            system = "x86_64-linux";
            modules = [
              # Modules
              disko.nixosModules.disko
              ./hardware-configuration.nix
              ./disko-configuration.nix
              ./configuration.nix
            ];
          };
        }) nodes
      );
    };
}
