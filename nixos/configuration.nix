# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').

{
  config,
  lib,
  pkgs,
  meta,
  ...
}:

{
  imports = [ ];

  nix = {
    package = pkgs.nix;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 5d";
    };
  };

  # Configure sops secrets
  sops.defaultSopsFile = ./secrets.yaml;

  # This will automatically import SSH keys as age keys
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Secrets used in configuration
  sops.secrets.tailscale-auth-key = { };
  sops.secrets.k3s-token = { };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = meta.hostname; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "nl_NL.UTF-8";
    LC_IDENTIFICATION = "nl_NL.UTF-8";
    LC_MEASUREMENT = "nl_NL.UTF-8";
    LC_MONETARY = "nl_NL.UTF-8";
    LC_NAME = "nl_NL.UTF-8";
    LC_NUMERIC = "nl_NL.UTF-8";
    LC_PAPER = "nl_NL.UTF-8";
    LC_TELEPHONE = "nl_NL.UTF-8";
    LC_TIME = "nl_NL.UTF-8";
  };

  # Fixes for longhorn
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];
  virtualisation.docker.logDriver = "json-file";

  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";
  services.k3s = {
    enable = true;
    role = "server";
    # tokenFile = config.sops.secrets.k3s-token.path;
    extraFlags = toString (
      [
        "--write-kubeconfig-mode \"0644\""
        "--cluster-init"
        "--disable servicelb"
        "--disable traefik"
        "--disable local-storage"
      ]
      ++ (
        if meta.hostname == "homelab-0" then
          [ ]
        else
          [
            "--server https://192.168.178.151:6443"
          ]
      )
    );
    clusterInit = (meta.hostname == "homelab-0");
  };

  services.openiscsi = {
    enable = true;
    name = "iqn.2016-04.com.open-iscsi:${meta.hostname}";
  };

  # Define a user account. Don't forget to set a password with 'passwd'.
  users.users.homelab = {
    isNormalUser = true;
    description = "homelab";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      tree
      nano
    ];
    # Created using mkpasswd
    hashedPassword = "$y$j9T$m3gQb5oHdbq87LmiRnsIE/$v6d3ddYMfyEg.UDGIg0UtSZM.QBotTuDU/Sp8rbDsO6";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL0dyepv7Mynvj4EqLWfM0DtAz20ZI8+AfU/qhHiAsXP thomvandevin@thomvandevin-macbook.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBR653yMYwe9MQkwYTR0QUQu1cFAcgzxKIGqd6iIlz1o tvandevin@LMAC-N6CFJ7CWGC"
    ];
  };

  # Define a user account for GitHub runner
  users.users.github = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable 'sudo' for the user.
    packages = with pkgs; [

    ];
    # Created using mkpasswd
    hashedPassword = "$y$j9T$cg.sS1V5bCuCmwBxbv51V1$UY0HU0pZQ2UKA.FJtb3FK4Hk3OwSBPjwO8r0aqGKv/1";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDUniQG2A2RLUqANeJl17uN5tHI0YVKFlDZWYB3TrIWh9OIQyFPiL1py2qP4J5Fzf1n/OpAr2T65ZCzqI6/N+dCcwfkkKMJzxe6AT7Ol7sigUUAFMm4u4Rc5BE9MqYU4lCM2oriYWUAyERbnbvUSG+Zxa1PHQGAo7MvMBPOFbePIIIwqxOK6fn+GgMxL8UrDGUfMuh0TMR4bmcnoruEC7lzmjg7oFyOl2XGHtqZHluOLp3fKel8g8go+0OaK6GuqbZewq11P0p/vxu/yOYt/oSPAqhMwahn+HhCncqlU1mj7Hq7X6y8iRCqFyDruUs4RpL+oNml1Wlpg9KAeS5/mCaVPXGz8X35UYEHoG2/c6tf9q+NTMrUnygQiNWBdjuBx9ljW4ii7xpF9t2oeTbcIdfihNGbJf6pJHDW7l/pOKvReBlkIYjo/7ClZvHrCXlKC/+3vkhPF5YfOwGHiZiAjlvGtZCQJlHW/nio6qDUQDoPLDsczqs7Q8ep0nAlWVuhM/B9syJ0ZCkUBsh+oL4dCAK2SGRH3li54ymA17Yd5z5ruowY/CtHmMVEzMwfeZHvqytFA35rniK5PD1M6Xu65lmVZQjpZLyaBA4khoJB2T9OW9mV9vqSwowgolMXN1yiEZk8QsQkQ9cLl7R9MT4EvSK2m5pME+Qps2t9aKwyGlgiuw== thomvandevin@thomvandevin-macbook.local"
    ];
  };

  # nixos-anywhere fix
  security.sudo.wheelNeedsPassword = false;

  # Enable automatic login for the user.
  services.getty.autologinUser = "homelab";

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    k3s
    cifs-utils
    nfs-utils
    git
    jq
    tailscale
    bat
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    allowSFTP = false;
    settings = {
      PasswordAuthentication = false;
    };
  };

  # fail2ban
  services.fail2ban = {
    enable = true;
    # Ban IP after 5 failures
    maxretry = 5;
    ignoreIP = [
      "10.0.0.0/8" # k8s
      "192.168.0.0/16" # home network
      "100.64.0.0/10" # tailscale
    ];
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  services.tailscale = {
    enable = true;
    openFirewall = true;
  };

  # create a oneshot job to authenticate to Tailscale
  systemd.services.tailscale-autoconnect = {
    description = "Automatic connection to Tailscale";

    # make sure tailscale is running before trying to connect to tailscale
    after = [
      "network-pre.target"
      "tailscale.service"
    ];
    wants = [
      "network-pre.target"
      "tailscale.service"
    ];
    wantedBy = [ "multi-user.target" ];

    # set this service as a oneshot job
    serviceConfig.Type = "oneshot";

    # have the job run this shell script
    script = with pkgs; ''
      # wait for tailscaled to settle
      sleep 2

      # check if we are already authenticated to tailscale
      status="$(${tailscale}/bin/tailscale status -json | ${jq}/bin/jq -r .BackendState)"
      if [ $status = "Running" ]; then # if so, then do nothing
        exit 0
      fi

      # otherwise authenticate with tailscale
      ${tailscale}/bin/tailscale up -authkey $(cat ${config.sops.secrets.tailscale-auth-key.path})
    '';
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?

}
