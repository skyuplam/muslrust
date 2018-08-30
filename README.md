# muslrust
[![build status](https://secure.travis-ci.org/clux/muslrust.svg)](http://travis-ci.org/clux/muslrust)
[![docker pulls](https://img.shields.io/docker/pulls/clux/muslrust.svg)](
https://hub.docker.com/r/clux/muslrust/)
[![docker image info](https://images.microbadger.com/badges/image/clux/muslrust.svg)](http://microbadger.com/images/clux/muslrust)
[![docker tag](https://images.microbadger.com/badges/version/clux/muslrust.svg)](https://hub.docker.com/r/clux/muslrust/tags/)

A plain docker environment for building static binaries compiled with rust and linked against musl instead of glibc. Built nightly on travis.

This is only useful if you require external C dependencies, because otherwise you could do `rustup target add x86_64-unknown-linux-musl`.

This container [comes with a bunch of statically compiled C libraries](#c-libraries) using `musl-gcc` so that we can statically link against these as well.

If you already have [rustup](https://www.rustup.rs/) installed on the machine that should compile, you might consider [cross](https://github.com/japaric/cross) as a more general solution for cross compiling rust binaries.

## Usage
Pull and run from a rust project root:

```sh
docker pull skyuplam/muslrust
docker run -v $PWD:/volume -t skyuplam/muslrust cargo build
```

You should have a static executable in the target folder:

```sh
ldd target/x86_64-unknown-linux-musl/debug/EXECUTABLE
        not a dynamic executable
```

From there on, you can include it in a blank docker image (because everything you need is included in the binary) and perhaps end up with a [5MB docker blog image](https://github.com/skyuplam/blog).

## Docker builds
Latest is always the last built nightly pushed by travis. To pin against specific builds, see the [available tags](https://hub.docker.com/r/skyuplam/muslrust/tags/) on the docker hub.

## C Libraries
The following system libraries are compiled against `musl-gcc`:

- [x] curl ([curl crate](https://github.com/carllerche/curl-rust))
- [x] openssl ([openssl crate](https://github.com/sfackler/rust-openssl))
- [x] pq ([pq-sys crate](https://github.com/sgrif/pq-sys) used by [diesel](https://github.com/diesel-rs/diesel))
- [x] sqlite3 ([libsqlite3-sys crate](https://github.com/jgallagher/rusqlite/tree/master/libsqlite3-sys) used by [diesel](https://github.com/diesel-rs/diesel))
- [x] zlib (used by pq and openssl)

We try to keep these up to date.

If it weren't for pq, we could ditch zlib as the `flate2` crate bundles `miniz.c` as the default implementation, and this just works. Similarly, curl is only needed for people using the C bindings to curl over [hyper](https://hyper.rs/).

If you need extra dependencies, you can follow the builder pattern approach by [portier-broker](https://github.com/portier/portier-broker/blob/master/Dockerfile)

## Developing
Clone, tweak, build, and run tests:

```sh
git clone git@github.com:skyuplam/muslrust.git && cd muslrust
make build
make test
```

Before we push a new version of muslrust we ensure that we can use and statically link:

- [x] `serde`
- [x] `diesel` (postgres and sqlite - see note below for postgres)
- [x] `hyper`
- [x] `curl`
- [x] `openssl`
- [x] `flate2`
- [x] `rand`

## SSL Verification
You need to point openssl at the location of your certificates explicitly to have https requests not return certificate errors.

```sh
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs
```

You can also hardcode this in your binary, or, more sensibly set it in your running docker image. The [openssl-probe crate](https://crates.io/crates/openssl-probe) can be also be used to detect where these reside.

## Diesel and PQ builds
Very fresh. Core `diesel` works fine, but `diesel_codegen` needs a fork of `pq-sys`. See the [test/dieselcrate](./test/dieselcrate) for how to get this working.

For stuff like `infer_schema!` to work you need to explicitly pass on `-e DATABASE_URL=$DATABASE_URL` to the `docker run`. It's probably easier to just make `diesel print-schema > src/schema.rs` part of your migration setup though.

## Caching Cargo Locally
Repeat builds locally are always from scratch (thus slow) without a cached cargo directory. You can set up a docker volume by just adding `-v cargo-cache:/root/.cargo` to the docker run command.

You'll have an extra volume that you can inspect with `docker volume inspect cargo-cache`.

Suggested developer usage is to add the following function to your `~/.bashrc`:

```sh
musl-build() {
  docker run \
    -v cargo-cache:/root/.cargo \
    -v "$PWD:/volume" \
    --rm -it skyuplam/muslrust cargo build --release
}
```

Then use in your project:

```sh
$ cd myproject
$ musl-build
    Finished release [optimized] target(s) in 0.0 secs
```

Second time around this will be quick, and you can even mix it with native `cargo build` calls without screwing with your cache.

## Debugging on alpine
If you are running a plain alpine/scratch container with your musl binary in there, then even if you add `ENV RUST_BACKTRACE=full` to your `Dockerfile`, your stacktraces will look like a longer version of this:

```sh
app_1  | stack backtrace:
app_1  |    0:           0x870b03 - <unknown>
app_1  |    1:           0x86ca10 - <unknown>
app_1  |    2:           0x875623 - <unknown>
app_1  |    3:           0x875392 - <unknown>
```

To debug in the container, you seem to need to have the `rust` package installed (from `apk`), as well as debug symbols compiled in (to get line numbers).

## Using muslrust on CI
Due to the current best compatibility with docker caching strategies, recommended CI is Circle. See [webapp-rs](https://github.com/clux/webapp-rs) for a complete life-cycle example of a rust cloud application on alpine built on CI.

### Clippy
If you need to install [clippy](https://github.com/rust-lang-nursery/rust-clippy) on a CI build image, you need to build it against the GNU toolchain (see [#37](https://github.com/clux/muslrust/issues/37#issuecomment-357314202)):

```sh
CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu cargo install clippy
```
