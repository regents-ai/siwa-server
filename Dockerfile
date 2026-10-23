# hexpm/elixir:1.20.4-erlang-29.1.2-debian-bookworm-20261020-slim
FROM docker.io/hexpm/elixir@sha256:11ab449084960993491cdc3493be292464c5a63e8f753ed2afe351486471b69a AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

# Hex and rebar3 at fixed versions; rebar3 is the build Mix itself would pick
# for this Elixir and OTP, checked against its published SHA-512.
RUN mix local.hex 2.5.1 --force && \
  mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28 \
    --sha512 992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24 \
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

# debian:bookworm-20261020-slim
FROM docker.io/library/debian@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS app

RUN apt-get update && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LANG=C.UTF-8
ENV PHX_SERVER=true
ENV PORT=8080

COPY --from=build /app/_build/prod/rel/siwa_server ./

CMD ["/app/bin/siwa_server", "start"]
