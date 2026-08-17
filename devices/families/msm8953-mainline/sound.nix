{ config, lib, pkgs, ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      msm8953-alsa-ucm = self.callPackage (
        { runCommand, fetchFromGitHub }:

        runCommand "msm8953-alsa-ucm" {
          src = fetchFromGitHub {
            name = "msm8953-alsa-ucm";
            owner = "msm8953-mainline";
            repo = "alsa-ucm-conf";
            rev = "c842a671ef37d876d8f1bd70801906c6b7eceb51";
            sha256 = "1705i4wd501igsd583pf7fsb7w2m5yyd7vw6j9pn9a3zsl0wkwyz";
          };
        } ''
          mkdir -p $out/share/
          ln -s $src $out/share/alsa
        ''
      ) {};
    })
  ];

  # Alsa UCM profiles (mido + msm8953-wcd codec)
  mobile.quirks.audio.alsa-ucm-meld = true;
  environment.systemPackages = [
    pkgs.msm8953-alsa-ucm
  ];
}
