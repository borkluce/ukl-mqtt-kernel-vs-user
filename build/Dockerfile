# Build environment for all kernels and the user-space publisher.
# Ubuntu 22.04 (glibc 2.35, gcc 11.4): glibc 2.39's C23 symbols break UKL's static link.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake libtool pkg-config \
      bison flex gawk texinfo python3 bc cpio xz-utils kmod file rsync \
      libelf-dev libssl-dev libgmp-dev libmpfr-dev libmpc-dev \
      git ca-certificates wget \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
