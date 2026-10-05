{
  description = "Homelab NixOS Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # Disko
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Sops
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
      ...
    }@inputs:
    let
      nodes = {
        homelab-0 = {
          role = "server";
          disk = "/dev/sda";
          hardware = ./hosts/homelab-0.nix;
        };
        homelab-1 = {
          role = "agent";
          disk = "/dev/nvme0n1";
          hardware = ./hosts/optiplex-5080-micro.nix;
        };
        homelab-2 = {
          role = "agent";
          disk = "/dev/nvme0n1";
          hardware = ./hosts/optiplex-5080-micro.nix;
        };
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        name: node:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            meta = {
              hostname = name;
              inherit (node) role disk;
            };
          };
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            node.hardware
            ./disko-configuration.nix
            ./configuration.nix
          ];
        }
      ) nodes;
    };
}
