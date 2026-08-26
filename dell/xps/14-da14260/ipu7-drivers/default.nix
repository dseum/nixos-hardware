{
  stdenv,
  lib,
  kernel,
  fetchFromGitHub,
  fetchpatch,
}:

# Kernels >= 6.17 ship an IPU7 core and ISys in drivers/staging/media/ipu7,
# but no PSys, so they cannot drive the hardware ISP that the camera HAL
# needs. This package supplies just the PSys module (intel-ipu7-psys), which
# has no in-tree counterpart, and links it against the in-tree core and ISys
# that already enumerate the sensor.
#
# Vendored from nixpkgs PR #542085; drop once that merges and use
# config.boot.kernelPackages.ipu7-drivers instead.
stdenv.mkDerivation {
  name = "ipu7-drivers-${kernel.version}";

  # Newer PSys revisions extend a kernel-owned struct that the in-tree IPU7
  # core allocates, causing an out-of-bounds write when the two are combined.
  # Keep this at the last revision before intel/ipu7-drivers#93's ABI break and
  # backport only fixes that preserve the shared structures.
  src = fetchFromGitHub {
    owner = "intel";
    repo = "ipu7-drivers";
    rev = "24d8923695dd977784845b637aba2cc21a927810";
    hash = "sha256-uZ89nLkn6O0i1XqB9igAOm73HMRNEWVsWW5bcLvh7GE=";
  };

  patches = [
    (fetchpatch {
      # Register the PSys bus before probing its auxiliary device.
      url = "https://github.com/intel/ipu7-drivers/commit/23cf17ab002dbb6b98da0e0dfa27ce2e4fe22a1f.patch";
      hash = "sha256-zd9YhtIOCdftNBt5C+UZtDjRvE3Ca9iZJHSKBRSAvdA=";
    })
    (fetchpatch {
      # Avoid reading the out-of-tree-only debugfs pointer from the in-tree core.
      url = "https://github.com/intel/ipu7-drivers/commit/4fbb9ebd2e9f5655469cc3651c8c8ea8492de749.patch";
      hash = "sha256-b8tkpimkQ2d0Sq/osdYM3yptDI+clNu/CU4nCJTC0yA=";
    })
    (fetchpatch {
      # Keep the readiness flag at the same offset as the in-tree IPU7 core.
      url = "https://github.com/intel/ipu7-drivers/commit/858ab564118f5e802e1c83367e9f0353a947efd0.patch";
      hash = "sha256-nTp3XPiIn9IFobQGbJPSk4JG2TI5CSJVSGHsRHzh4SE=";
    })

    # Backport PR #99 without advancing past the compatible shared-bus ABI.
    (fetchpatch {
      url = "https://github.com/intel/ipu7-drivers/commit/9bc2e047041e68d9997b8c2f4484c8d9f5936ff0.patch";
      hash = "sha256-SUaYoZieQkSGz5VNBRmRQAONcPXNmvlAZDuvk9U6Wfc=";
    })
    (fetchpatch {
      url = "https://github.com/intel/ipu7-drivers/commit/9bae9a68d44c4f35de206d00f88da27e60b1db14.patch";
      hash = "sha256-e46UpCY/WCPSQ458c7O9V/KhAIUH/JKawFNO2ps4zcc=";
    })
    (fetchpatch {
      url = "https://github.com/intel/ipu7-drivers/commit/3f33fe8c0c7b701f8719d8f027eedcac10521f36.patch";
      hash = "sha256-z8ozl1Cf2ROTcA1wFtoEWYE26uMhf7o2GzjsYT6ZkAo=";
    })
  ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "KERNELRELEASE=${kernel.modDirVersion}"
    "KERNEL_SRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ];

  enableParallelBuilding = true;

  preInstall = ''
    substituteInPlace Makefile \
      --replace-fail "INSTALL_MOD_DIR=" "INSTALL_MOD_PATH=$out INSTALL_MOD_DIR="
  '';

  installTargets = [ "modules_install" ];

  meta = {
    homepage = "https://github.com/intel/ipu7-drivers";
    description = "Intel IPU7 PSys kernel driver";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
