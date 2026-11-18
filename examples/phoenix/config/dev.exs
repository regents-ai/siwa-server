import Config

# Loopback only: a practice site lives at http://localhost:<port> on your own computer.
config :siwa_demo, SiwaDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  debug_errors: true
