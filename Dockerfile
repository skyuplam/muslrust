FROM debian:stretch
MAINTAINER Eirik Albrigtsen <sszynrae@gmail.com>

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/bin:/usr/local/cargo/bin:$PATH \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    PREFIX=/usr/local/musl \
    CC=musl-gcc \
    LD_LIBRARY_PATH=$PREFIX

# Required packages:
# - musl-dev, musl-tools - the musl toolchain
# - curl, g++, make, pkgconf, cmake - for fetching and building third party libs
# - ca-certificates - openssl + curl + peer verification of downloads
# - xutils-dev - for openssl makedepend
# - libssl-dev and libpq-dev - for dynamic linking during diesel_codegen
#   build process
# - git - cargo builds in user projects
# - linux-headers-amd64 - needed for building openssl 1.1 (stretch only)
# - file - needed by rustup.sh install
# recently removed:
# cmake (not used), nano, zlib1g-dev
RUN apt-get update && apt-get install -y \
  musl-dev \
  musl-tools \
  file \
  git \
  make \
  g++ \
  curl \
  pkgconf \
  ca-certificates \
  xutils-dev \
  libssl-dev \
  libpq-dev \
  sudo \
  --no-install-recommends && \
  apt-get clean && rm -rf /var/lib/apt/lists/*


# Build arg to control rust toolchain
ARG TOOLCHAIN=stable
# Install rust and add build target to x86_64-unknown-linux-musl
RUN curl https://sh.rustup.rs -sSf | \
    sh -s -- -y --default-toolchain $TOOLCHAIN && \
    rustup target add x86_64-unknown-linux-musl && \
    echo "[build]\ntarget = \"x86_64-unknown-linux-musl\"" > $CARGO_HOME/config

# Set up a prefix for musl build libraries,
# make the linker's job of finding them easier
# Primarily for the benefit of postgres.
# Lastly, link some linux-headers for openssl 1.1 (not used herein)
RUN mkdir $PREFIX && \
    echo "$PREFIX/lib" >> /etc/ld-musl-x86_64.path && \
    ln -s /usr/include/linux /usr/include/x86_64-linux-musl/linux && \
    ln -s /usr/include/x86_64-linux-gnu/asm /usr/include/x86_64-linux-musl/asm && \
    ln -s /usr/include/asm-generic /usr/include/x86_64-linux-musl/asm-generic

# Build arg to control zlib version and checksum
ARG ZLIB_VER=1.2.11
ARG ZLIB_SHA256CHECKSUM=c3e5e9fdd5004dcb542feda5ee4f0ff0744628baf8ed2dd5d66f8ca1197cb1a1

# Build zlib (used in openssl and pq)
RUN curl -sS -o zlib-$ZLIB_VER.tar.gz http://zlib.net/zlib-$ZLIB_VER.tar.gz && \
    echo $ZLIB_SHA256CHECKSUM zlib-$ZLIB_VER.tar.gz | sha256sum -c - && \
    tar xzf zlib-$ZLIB_VER.tar.gz && \
    cd zlib-$ZLIB_VER && \
    CC="musl-gcc -fPIC -pie" LDFLAGS="-L$PREFIX/lib" \
    CFLAGS="-I$PREFIX/include" ./configure --static --prefix=$PREFIX && \
    make -j$(nproc) && make install && \
    cd .. && rm -rf zlib-$ZLIB_VER*

# Build arg to control openssl version
ARG SSL_VER=1.1.0g
# Build openssl (used in curl and pq)
RUN curl -sS -o openssl-$SSL_VER.tar.gz \
      https://www.openssl.org/source/openssl-$SSL_VER.tar.gz && \
    curl -sSL https://www.openssl.org/source/openssl-$SSL_VER.tar.gz.sha256 | \
      sed 's@$@ openssl-'$SSL_VER'.tar.gz@' | sha256sum -c - && \
    tar xzf openssl-$SSL_VER.tar.gz && \
    cd openssl-$SSL_VER && \
    ./Configure no-shared no-zlib no-async -fPIC --prefix=$PREFIX \
    # zlib --with-zlib-include=$PREFIX/include --with-zlib-lib=$PREFIX/lib \
    --openssldir=$PREFIX/ssl linux-x86_64 && \
    env C_INCLUDE_PATH=$PREFIX/include make depend 2> /dev/null && \
    make -j$(nproc) && make install && \
    cd .. && rm -rf openssl-$SSL_VER*

ARG CURL_VER=7.58.0
# Build curl (needs with-zlib and all this stuff to allow https)
# curl_LDFLAGS needed on stretch to avoid fPIC errors - though not sure from what
RUN curl -sSL https://curl.haxx.se/download/curl-$CURL_VER.tar.gz | tar xz && \
    cd curl-$CURL_VER && \
    CC="musl-gcc -fPIC -pie" LDFLAGS="-L$PREFIX/lib" \
    CFLAGS="-I$PREFIX/include" ./configure \
      --enable-shared=no --with-zlib --enable-static=ssl --enable-optimize \
      --prefix=$PREFIX --with-ca-path=/etc/ssl/certs/ \
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
      --without-ca-fallback && \
    make -j$(nproc) curl_LDFLAGS="-all-static" && make install && \
    cd .. && rm -rf curl-$CURL_VER

# Build arg to control libpq version
ARG PQ_VER=10.3
# Build libpq
RUN curl -sS -o postgresql-$PQ_VER.tar.gz \
      https://ftp.postgresql.org/pub/source/v$PQ_VER/postgresql-$PQ_VER.tar.gz && \
    curl -sSL \
      https://ftp.postgresql.org/pub/source/v$PQ_VER/postgresql-$PQ_VER.tar.gz.sha256 | \
      sha256sum -c - && \
    tar xzf postgresql-$PQ_VER.tar.gz && \
    cd postgresql-$PQ_VER && \
    CC="musl-gcc -fPIE -pie" LDFLAGS="-L$PREFIX/lib" \
    CFLAGS="-I$PREFIX/include" ./configure \
    --without-readline \
    --prefix=$PREFIX --host=x86_64-unknown-linux-musl && \
    make -s -j$(nproc) && make -s install && \
    rm $PREFIX/lib/*.so && rm $PREFIX/lib/*.so.* && \
    rm $PREFIX/lib/postgres* -rf &&  \
    cd .. && rm -rf postgresql-$PQ_VER*


# Build arg to control sqlite version and checksum
ARG SQLITE_VER=3220000
ARG SQLITE_SHA1CHECKSUM=2fb24ec12001926d5209d2da90d252b9825366ac
# Build libsqlite3 using same configuration as the alpine linux main/sqlite package
RUN curl -sS -o sqlite-autoconf-$SQLITE_VER.tar.gz \
      https://www.sqlite.org/2018/sqlite-autoconf-$SQLITE_VER.tar.gz && \
    echo $SQLITE_SHA1CHECKSUM sqlite-autoconf-$SQLITE_VER.tar.gz | sha1sum -c - && \
    tar xzf sqlite-autoconf-$SQLITE_VER.tar.gz && \
    cd sqlite-autoconf-$SQLITE_VER && \
    CFLAGS="-DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_SECURE_DELETE -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_ENABLE_RTREE -DSQLITE_USE_URI -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_JSON1" \
    CC="musl-gcc -fPIC -pie" \
    ./configure --prefix=$PREFIX --host=x86_64-unknown-linux-musl --enable-threadsafe --enable-dynamic-extensions --disable-shared && \
    make && make install && \
    cd .. && rm -rf sqlite-autoconf-$SQLITE_VER

# SSL cert directories get overridden by --prefix and --openssldir
# and they do not match the typical host configurations.
# The SSL_CERT_* vars fix this, but only when inside this container
# musl-compiled binary must point SSL at the correct certs (muslrust/issues/5) elsewhere
# Postgres bindings need vars so that diesel_codegen.so uses the GNU deps at build time
# but finally links with the static libpq.a at the end.
# It needs the non-musl pg_config to set this up with libpq-dev (depending on libssl-dev)
# See https://github.com/sgrif/pq-sys/pull/18
ENV PATH=$PREFIX/bin:$PATH \
    PKG_CONFIG_ALLOW_CROSS=true \
    PKG_CONFIG_ALL_STATIC=true \
    PQ_LIB_STATIC_X86_64_UNKNOWN_LINUX_MUSL=true \
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    PG_CONFIG_X86_64_UNKNOWN_LINUX_GNU=/usr/bin/pg_config \
    OPENSSL_STATIC=true \
    OPENSSL_DIR=$PREFIX \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    LIBZ_SYS_STATIC=1

RUN useradd rust --user-group --create-home --shell /bin/bash --groups sudo
RUN echo "%sudo  ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/nopasswd
USER rust
RUN sudo chown -R rust /usr/local
WORKDIR /home/rust
