#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -ex

NOXARGS=""
RUST=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --python-version) PYTHON_VERSION="$2"; shift ;;
        --noxsession) NOXSESSION="$2"; shift ;;
        --openssl-type) OPENSSL_TYPE="$2"; shift ;;
        --openssl-version) OPENSSL_VERSION="$2"; shift ;;
        --noxargs) NOXARGS="$2"; shift ;;
        --rust) RUST="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Export necessary environment variables
export CRYPTOGRAPHY_OPENSSL_NO_LEGACY="${CRYPTOGRAPHY_OPENSSL_NO_LEGACY:-}"
export CONFIG_FLAGS_ARG="${CONFIG_FLAGS_ARG}"
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
export NOXSESSION="${NOXSESSION}"
export CARGO_TARGET_DIR="/cryptography/src/rust/target/"
export PATH=$PATH:$HOME/.cargo/bin && . "$HOME/.cargo/env"
DEFAULT_CONFIG_FLAGS="shared no-ssl2 no-ssl3"
export CONFIG_FLAGS="$DEFAULT_CONFIG_FLAGS $CONFIG_FLAGS_ARG"

# Install necessary Python packages
python -m pip install -c ci-constraints-requirements.txt 'nox' 'tomli; python_version < "3.11"'

# Install Rust toolchain if specified
if [[ -n "$RUST" ]]; then
    rustup toolchain install "$RUST" --component rustfmt --component clippy --profile minimal --no-self-update
fi

if [[ $NOXSESSION != 'flake' && $NOXSESSION != 'docs' ]]; then
    rustup component add llvm-tools-preview
fi

if [[ $NOXSESSION != 'flake' && $NOXSESSION != 'docs' && $NOXSESSION != 'rust' ]]; then
    git clone https://github.com/C2SP/wycheproof.git
    git clone https://github.com/C2SP/x509-limbo.git
fi

# Set up OpenSSL or LibreSSL depending on the OPENSSL_TYPE
setup_ssl() {
    local ssl_dir="/cryptography/osslcache/$1-$OPENSSL_VERSION"
    if [[ "$1" == "openssl" ]]; then
        git clone https://github.com/openssl/openssl
        cd openssl
        git checkout "openssl-$OPENSSL_VERSION"
        sed -i "s/^SHLIB_VERSION=.*/SHLIB_VERSION=100/" VERSION.dat
        ./config $CONFIG_FLAGS -fPIC --prefix="$ssl_dir"
        make depend
        make -j"$(nproc)"
        make install_sw install_ssldirs
        rm -rf "$ssl_dir/bin"
        if [[ "$CONFIG_FLAGS_ARG" =~ enable-fips ]]; then
            make -j"$(nproc)" install_fips
            pushd "${ssl_dir}"
            sed -i "s:# .include fipsmodule.cnf:.include $(pwd)/ssl/fipsmodule.cnf:" ssl/openssl.cnf
            sed -i 's:# fips = fips_sect:fips = fips_sect:' ssl/openssl.cnf
            popd
        fi
    elif [[ "$1" == "libressl" ]]; then
        curl -LO "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-$OPENSSL_VERSION.tar.gz"
        tar zxf "libressl-$OPENSSL_VERSION.tar.gz"
        cd "libressl-$OPENSSL_VERSION"
        cmake -B build -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF -DHOST_POWERPC64=1 -DCMAKE_INSTALL_PREFIX="$ssl_dir"
        make -C build -j"$(nproc)" install
        rm -rf "$ssl_dir/bin" "$ssl_dir/share" "$ssl_dir/lib/libtls*"
    fi
    cd ..
    export OSSL_PATH="$ssl_dir"
    export OPENSSL_DIR="$ssl_dir"
    export CFLAGS=-Werror=implicit-function-declaration
    export RUSTFLAGS="-Clink-arg=-Wl,-rpath=$ssl_dir/lib -Clink-arg=-Wl,-rpath=$ssl_dir/lib64"
}

if [[ "$OPENSSL_TYPE" == "openssl" ]]; then
    setup_ssl "openssl"
elif [[ "$OPENSSL_TYPE" == "libressl" ]]; then
    setup_ssl "libressl"
fi

nox -v --install-only
nox --no-install --  --color=yes --wycheproof-root=wycheproof --x509-limbo-root=x509-limbo $NOXARGS

