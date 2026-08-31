{ pkgs, ... }:

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

  # The QDSP6 front-end PCM (q6asm-dai) constrains period_size to multiples of
  # 480 frames (snd_pcm_hw_constraint_step(PERIOD_SIZE, 480) in q6asm-dai.c).
  # PipeWire's default ALSA negotiation uses period 1024, which violates that
  # constraint, so the PCM open fails while the sink still reports "active" and
  # playback is silently dead. Force valid hw params on every ALSA sink
  # (1920 = 4 x 480; S16LE/48k matches the backend fixup in apq8016_sbc.c).
  # postmarketOS ships the same workaround for QDSP6 devices.
  services.pipewire.wireplumber.configPackages = [
    (pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/51-msm8953-qdsp6-alsa.conf" ''
      monitor.alsa.rules = [
        {
          matches = [
            { node.name = "~alsa_output.*" }
          ]
          actions = {
            update-props = {
              audio.format         = "S16LE"
              audio.rate           = 48000
              api.alsa.period-size = 1920
              api.alsa.period-num  = 4
            }
          }
        }
      ]
    '')
  ];
}
