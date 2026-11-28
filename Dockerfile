# hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261027-slim
FROM docker.io/hexpm/elixir@sha256:bb266918bb26de22fb02ff19430f47e76331001601df0fc820806c21cd4164e0 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

# Hex and rebar3 at fixed versions; rebar3 is the build Mix itself would pick
# for this Elixir and OTP, checked against its published SHA-512.
RUN mix local.hex 2.6.0 --force && \
  mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.28.0-otp-29 \
    --sha512 b51946058fbe4aa823185bfe27204be59be439982ac3a3e1dbd9f8260b9af046fcfdfbd9066283c3fbba5a2a45dc3570550c12a9a548daf223b80cac222a6d0f \
    --force

# The build context is this repository. Shared Regent libraries arrive from
# GitHub at the commits mix.lock pins; a mix.lock that no longer matches
# mix.exs stops the build.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod --check-locked
RUN mix deps.compile

COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# debian:trixie-20261027-slim (OpenSSL 3.5+ for native Erlang/OTP 29 ML-DSA-65 / ML-KEM)
FROM docker.io/library/debian@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS app

# OTP 29 opens libsctp when it starts and prints a warning on every boot and
# `bin/siwa_server rpc` without it.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LANG=C.UTF-8
ENV PHX_SERVER=true
ENV PORT=8080

COPY --from=build /app/_build/prod/rel/siwa_server ./

# Fail the image build immediately if the runtime OpenSSL loses native FIPS 204 ML-DSA-65.
RUN /app/bin/siwa_server eval 'SiwaServer.Release.verify_pqc_runtime!()'

CMD ["/app/bin/siwa_server", "start"]
