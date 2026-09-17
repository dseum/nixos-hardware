{
  lib,
  pkgs,
  config,
  ...
}:
let
  # Reuse the upstream nixpkgs IPU7 packages and override only the revisions
  # that are not yet compatible with this kernel and camera topology.
  ipu7-camera-bins = pkgs.ipu7-camera-bins;

  ipu7-camera-hal = pkgs.ipu75xa-camera-hal.overrideAttrs (_: {
    # HAL master understands the in-tree intel_cvs V4L2 subdev added in Linux
    # 7.2. The released HAL in nixpkgs predates that media-graph topology.
    version = "0-unstable-2026-08-12";
    src = pkgs.fetchFromGitHub {
      owner = "intel";
      repo = "ipu7-camera-hal";
      rev = "11d8aff0d1ddc16aef56c8e6518e08e2f936a95b";
      hash = "sha256-NSZVVOZKa3xhwitdKw4EZpukf5B/ObQC4GEDwHMmZ6s=";
    };
    patches = [ ./ipu7-camera-hal/ipu75xa-ov08x40-cvs.patch ];
  });

  icamerasrc = pkgs.gst_all_1.icamerasrc-ipu75xa.override {
    ipu7x-camera-hal = ipu7-camera-hal;
  };

  ipu7-drivers = config.boot.kernelPackages.ipu7-drivers.overrideAttrs (_: {
    # 24d8923 is the last revision before intel/ipu7-drivers#93 changed the
    # kernel-owned bus layout. Backport only fixes that preserve that ABI.
    version = "0-unstable-2026-06-19";
    src = pkgs.fetchFromGitHub {
      owner = "intel";
      repo = "ipu7-drivers";
      rev = "24d8923695dd977784845b637aba2cc21a927810";
      hash = "sha256-uZ89nLkn6O0i1XqB9igAOm73HMRNEWVsWW5bcLvh7GE=";
    };
    patches = [
      (pkgs.fetchpatch {
        url = "https://github.com/intel/ipu7-drivers/commit/23cf17ab002dbb6b98da0e0dfa27ce2e4fe22a1f.patch";
        hash = "sha256-zd9YhtIOCdftNBt5C+UZtDjRvE3Ca9iZJHSKBRSAvdA=";
      })
      (pkgs.fetchpatch {
        url = "https://github.com/intel/ipu7-drivers/commit/4fbb9ebd2e9f5655469cc3651c8c8ea8492de749.patch";
        hash = "sha256-b8tkpimkQ2d0Sq/osdYM3yptDI+clNu/CU4nCJTC0yA=";
      })
      (pkgs.fetchpatch {
        url = "https://github.com/intel/ipu7-drivers/commit/858ab564118f5e802e1c83367e9f0353a947efd0.patch";
        hash = "sha256-nTp3XPiIn9IFobQGbJPSk4JG2TI5CSJVSGHsRHzh4SE=";
      })
      (pkgs.fetchpatch {
        url = "https://github.com/intel/ipu7-drivers/commit/9bc2e047041e68d9997b8c2f4484c8d9f5936ff0.patch";
        hash = "sha256-SUaYoZieQkSGz5VNBRmRQAONcPXNmvlAZDuvk9U6Wfc=";
      })
      (pkgs.fetchpatch {
        url = "https://github.com/intel/ipu7-drivers/commit/9bae9a68d44c4f35de206d00f88da27e60b1db14.patch";
        hash = "sha256-e46UpCY/WCPSQ458c7O9V/KhAIUH/JKawFNO2ps4zcc=";
      })
      (pkgs.fetchpatch {
        url = "https://github.com/intel/ipu7-drivers/commit/3f33fe8c0c7b701f8719d8f027eedcac10521f36.patch";
        hash = "sha256-z8ozl1Cf2ROTcA1wFtoEWYE26uMhf7o2GzjsYT6ZkAo=";
      })
    ];
  });

  # ALSA card numbers change when other audio devices probe first.
  sofSoundCard = "/dev/snd/by-path/pci-0000:00:1f.3-platform-sof_sdw";
in
{
  imports = [
    ../../../common/cpu/intel/panther-lake
    ../../../common/pc/laptop
    ../../../common/pc/ssd
  ];

  # Linux 7.2 provides the in-tree CVS bridge required by this camera topology.
  boot.kernelPackages = lib.mkIf (lib.versionOlder pkgs.linux.version "7.2") (
    lib.mkDefault pkgs.linuxPackages_latest
  );

  assertions = [
    {
      assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.2";
      message = "The Dell XPS 14 DA14260 profile requires Linux 7.2 or newer";
    }
  ];

  # SoundWire can probe the amplifiers concurrently even though they share the
  # speaker-ID GPIOs, making an exclusive GPIO request fail nondeterministically.
  boot.kernelPatches = [
    {
      name = "cs35l56-serialize-speaker-id-gpio";
      patch = ./cs35l56-serialize-speaker-id-gpio.patch;
    }
  ];

  # Intel CVS support for the Synaptics SVP7500 camera bridge is provided by
  # the in-tree driver in Linux 7.2 and newer.
  boot.extraModulePackages = [
    # PSys module for the hardware ISP; the in-tree staging driver only has
    # the core + ISys (raw capture), which forces the untuned software ISP.
    ipu7-drivers
    config.boot.kernelPackages.v4l2loopback
  ];
  boot.kernelModules = [
    "v4l2loopback"
  ];
  # The camera bridge and CS35L57 amplifiers share the speaker-ID GPIO. The
  # amplifiers only sample it during probe, so load intel_cvs after ALSA has
  # registered the sound card instead of letting coldplug claim it first.
  boot.blacklistedKernelModules = [ "intel_cvs" ];
  # Don't let v4l2loopback auto-create a device at load time — an unconfigured
  # device has a degenerate framerate range that breaks GStreamer caps
  # negotiation. The relay service below creates a configured device at runtime.
  #
  # The softdep orders the USB-I2C bridge stack ahead of the imaging unit. The
  # sensors are not on a native I2C controller: they sit behind the SVP7500,
  # which tunnels I2C over a USB bulk interface, so the USB-I2C and INT3472
  # plumbing must exist before intel_ipu7 starts bring-up. intel_cvs is omitted
  # deliberately and loaded by the camera relay after audio initialization.
  boot.extraModprobeConfig = ''
    options v4l2loopback devices=0
    softdep intel_ipu7 pre: usbio gpio_usbio i2c_usbio intel_skl_int3472_discrete
  '';

  # IPU firmware + AIQ blobs for the hardware ISP.
  hardware.firmware = [ ipu7-camera-bins ];

  # Prevent the SVP7500 USB bridge from autosuspending; the bridge firmware
  # has issues with power-state transitions that cause it to wedge on resume.
  # The intel-ipu7-psys rule lets the camera HAL (running as the relay/user)
  # open the PSys device node.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="06cb", ATTRS{idProduct}=="0701", ATTR{power/autosuspend}="-1"
    SUBSYSTEM=="intel-ipu7-psys", MODE="0660", GROUP="video"
  '';

  # Hide the raw IPU7 ISYS capture nodes from PipeWire. ISys exposes one
  # /dev/videoN per CSI-2 stream (~30 of them here), all raw Bayer that no
  # application can render — the frames only become an image after the PSys
  # hardware ISP, which is what the relay above exposes. Left visible they fill
  # every camera picker with unusable entries next to the one real device.
  #
  # Matched via device.product.name, which comes from udev's ID_V4L_PRODUCT and
  # is set by the kernel at device registration -- unlike device.description,
  # which WirePlumber derives from VIDIOC_QUERYCAP and so requires opening all
  # ~30 nodes just to decide to hide them. Same approach as nixpkgs'
  # hardware/video/webcam/ipu6.nix.
  #
  # Nothing here depends on IR; RGB-only users get the same benefit. mkDefault
  # because this is a presentation choice rather than hardware enablement --
  # set it to { } to get the raw nodes back.
  services.pipewire.wireplumber.extraConfig."50-disable-v4l2-ipu7" = lib.mkDefault {
    "monitor.v4l2.rules" = [
      {
        actions.update-props."device.disabled" = true;
        matches = [
          {
            "device.product.name" = "ipu7";
          }
        ];
      }
    ];
  };

  # libcamera's software ISP selects the OV08X40's broken 1928x1088 binned
  # mode. Hide only this built-in camera by its ACPI-backed libcamera path so
  # other libcamera devices remain available.
  services.pipewire.wireplumber.extraConfig."50-disable-libcamera-ipu7" = lib.mkDefault {
    "monitor.libcamera.rules" = [
      {
        actions.update-props."device.disabled" = true;
        matches = [
          {
            "api.libcamera.path" = "\\_SB_.LNK1";
          }
        ];
      }
    ];
  };

  systemd.paths.ipu7-camera-relay = {
    description = "Start the IPU7 camera after audio initialization";
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathExists = sofSoundCard;
  };

  # The IPU7 camera is driven through the Intel camera HAL (hardware ISP with
  # per-sensor AIQ tuning — proper colours, low CPU), but applications only
  # speak V4L2 and cannot use the HAL directly. v4l2-relayd runs a GStreamer
  # icamerasrc pipeline and feeds a v4l2loopback device ("Intel IPU7 Camera")
  # that any V4L2 app can open.
  #
  # This is a hand-rolled service rather than `services.v4l2-relayd` because that
  # module creates the loopback with the default 2 buffers (which throttles the
  # stream to ~3 fps) and only inserts a `queue` before its v4l2sink when the
  # input/output formats differ. Full framerate needs BOTH more buffers (-b 4)
  # and a `queue` (+ sync=false) on the output, which the module cannot express.
  systemd.services.ipu7-camera-relay =
    let
      gstPluginPath = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" (
        (with pkgs.gst_all_1; [
          gstreamer.out
          gst-plugins-base
          gst-plugins-good
          gst-plugins-bad
        ])
        ++ [ icamerasrc ]
      );
      v4l2loopback-ctl = "${config.boot.kernelPackages.v4l2loopback.bin}/bin/v4l2loopback-ctl";
      deviceFile = "/run/ipu7-camera-relay/device";

      # icamerasrc emits NV12 from the hardware ISP (already colour-corrected by
      # the AIQ tuning, so no videobalance hack is needed); videoconvert +
      # videoscale adapt it to the loopback format (both are passthrough when the
      # output caps match icamerasrc's native NV12) and videoflip fixes
      # orientation — benchmarked as free even on full 4K frames. The panel
      # mounts the sensor upside down (needs rotate-180 = H+V to make it
      # upright); a `vertical-flip` instead gives upright + left-right MIRROR, i.e.
      # the usual selfie view (rotate-180 then a horizontal mirror reduces to V).
      # Do NOT append a bare caps filter (e.g. `! video/x-raw,format=YUY2,...`):
      # v4l2-relayd parses this with the single-string gst_parse_launch, which
      # mis-tokenizes bare caps ("no element video", treats `/x-raw...` as a URI)
      # so the input pipeline fails to build and only the black splash is shown.
      # v4l2-relayd applies the caps (copied from the output appsrc below) to its
      # internal appsink instead.
      input = "icamerasrc ! videoconvert ! videoscale ! videoflip method=vertical-flip";

      # A leaky queue (drops old frames) + sync=false keep latency low so the
      # viewer sees the latest frame instead of a backlog; the -b 4 buffers in
      # preStart are enough to sustain full framerate without adding lag.
      #
      # 3840x2160 NV12: the sensor has a single native mode (3856x2176 @
      # 28.57 fps) and the hardware ISP scales, so 4K costs nothing over 720p —
      # benchmarked ~28.6 fps with zero drops at 720p/1080p/4K, flip included
      # (higher framerates are not possible: the sensor ignores 60/1 caps and
      # keeps its native cadence). NV12 is icamerasrc's native output, so the
      # videoconvert stages are passthrough instead of per-frame conversions.
      # Lower width/height here if a consumer struggles with 4K input.
      output =
        "appsrc name=appsrc caps=video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1"
        + " ! queue leaky=downstream max-size-buffers=3 ! videoconvert ! v4l2sink name=v4l2sink device=$(cat ${deviceFile}) sync=false";
    in
    {
      description = "Intel IPU7 camera to v4l2loopback relay (hardware ISP via camera HAL)";
      after = [ "modprobe@v4l2loopback.service" ];
      requires = [ "modprobe@v4l2loopback.service" ];
      unitConfig.ConditionPathExists = sofSoundCard;
      environment = {
        GST_PLUGIN_PATH = gstPluginPath;
        V4L2_DEVICE_FILE = deviceFile;
      };
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 2;
        RuntimeDirectory = "ipu7-camera-relay";
      };
      preStart = ''
        ${pkgs.kmod}/bin/modprobe intel_cvs
        ${v4l2loopback-ctl} add -b 4 -x 1 -n "Intel IPU7 Camera" > ${deviceFile}
      '';
      script = ''
        exec ${pkgs.v4l2-relayd}/bin/v4l2-relayd -i "${input}" -o "${output}"
      '';
      postStop = ''
        ${v4l2loopback-ctl} delete "$(cat ${deviceFile})" || true
      '';
    };

  # See https://github.com/NixOS/nixos-hardware/pull/127
  services.thermald.enable = true;

  # Allows for updating firmware via `fwupdmgr`.
  services.fwupd.enable = true;
}
