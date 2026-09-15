import Config

config :illume, Illume.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_padding_padding_pa",
  live_view: [signing_salt: "illumetestsalt"],
  pubsub_server: Illume.PubSub,
  server: false
