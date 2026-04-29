FROM hexpm/elixir:1.19.5-erlang-28.5-debian-bookworm-20260421 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY siwa-server/mix.exs siwa-server/mix.lock ./
COPY siwa-server/config config
COPY elixir-utils/siwa/siwa-elixir/apps/siwa ../elixir-utils/siwa/siwa-elixir/apps/siwa
COPY elixir-utils/siwa/siwa-elixir/apps/siwa_keyring ../elixir-utils/siwa/siwa-elixir/apps/siwa_keyring
COPY elixir-utils/siwa/siwa-elixir/config ../elixir-utils/siwa/siwa-elixir/config
COPY elixir-utils/siwa/siwa-elixir/mix.exs elixir-utils/siwa/siwa-elixir/mix.lock ../elixir-utils/siwa/siwa-elixir/
RUN mix deps.get --only prod
RUN mix deps.compile

COPY siwa-server/lib lib
COPY siwa-server/priv priv

RUN mix compile
RUN mix release

FROM debian:bookworm-slim AS app

RUN apt-get update && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LANG=C.UTF-8
ENV PHX_SERVER=true
ENV PORT=8080

COPY --from=build /app/_build/prod/rel/siwa_server ./

CMD ["/app/bin/siwa_server", "start"]
